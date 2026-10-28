#!/usr/bin/env python3
"""Explicitly enrich tokenized JSONL with lemmas, POS tags, and morphology.

Backends:

- ``nltk`` (default): NLTK's averaged-perceptron tagger writes fine-grained
  Penn Treebank tags (``NNP``, ``VBZ``, ``JJR`` ...), which the configured
  ``pos_mapping`` cascade maps to CCG prior categories; lemmas come from the
  WordNet lemmatizer and ``morph`` is left empty.  It also writes ranked
  ``pos_candidates`` per token (see below).
- ``spacy`` / ``stanza``: Universal POS tags plus UD morphology.

Ranked POS candidates (nltk backend).  ``pos`` keeps NLTK's single best tag.
``pos_candidates`` lists every tag the token may have, best first, each with
its source:

- function words, proper nouns, numbers, and punctuation (NLTK's best tag is
  not a noun, verb, adjective, or adverb tag): NLTK's top-k tags by perceptron
  score, keeping those with probability >= ``--min-probability``.  Words NLTK
  looks up in its tag dictionary are unambiguous to it and keep one tag.
- content words: NLTK's best tag, then every other Penn Treebank tag WordNet
  allows for the word form (all senses, with inflection read from WordNet's
  base forms), ordered by NLTK's score.  Words absent from WordNet fall back to
  NLTK's top-k tags.

The token-to-category mapping itself is not done here; it belongs to the
Haskell candidate builder (``ccg-induction build-candidates``), which gives the
i-th candidate tag a prior cost offset of ``i * pos_candidate_rank_cost``.
"""

from __future__ import annotations

import argparse
import json
import math
from collections.abc import Callable
from pathlib import Path
from typing import Any, NamedTuple

PTB_TO_WORDNET = {"J": "a", "N": "n", "R": "r", "V": "v"}

# Penn Treebank tags of open-class words, whose possible tags WordNet knows.
CONTENT_TAGS = frozenset({
    "NN", "NNS", "VB", "VBD", "VBG", "VBN", "VBP", "VBZ", "JJ", "JJR", "JJS", "RB", "RBR", "RBS", "FW",
})


class PosCandidate(NamedTuple):
    tag: str
    source: str  # "nltk" or "wordnet"

    def to_json(self) -> dict[str, str]:
        return {"tag": self.tag, "source": self.source}


class TaggedSentence(NamedTuple):
    lemmas: list[str]
    pos: list[str]
    morph: list[dict[str, str]]
    pos_candidates: list[list[PosCandidate]] | None = None


Tagger = Callable[[list[str]], TaggedSentence]


def wordnet_ptb_tags(word: str, wordnet: Any) -> set[str]:
    """Every Penn Treebank tag WordNet allows for a word form.

    ``_morphy`` returns all WordNet base forms, including irregular ones
    (``better`` -> ``good``), so the inflection is read from whether the form
    is itself a base form and from its suffix.
    """
    lower = word.lower()
    tags: set[str] = set()
    for wordnet_pos in ("n", "v", "a", "r"):
        bases = wordnet._morphy(lower, wordnet_pos)
        if not bases:
            continue
        is_base = lower in bases
        is_inflected = any(base != lower for base in bases)
        if wordnet_pos == "n":
            tags |= {"NN"} if is_base else set()
            tags |= {"NNS"} if is_inflected else set()
        elif wordnet_pos == "v":
            if is_base:
                tags |= {"VB", "VBP"}
            if is_inflected:
                if lower.endswith("ing"):
                    tags.add("VBG")
                elif lower.endswith("s"):
                    tags.add("VBZ")
                else:
                    tags |= {"VBD", "VBN"}
        else:
            plain, comparative, superlative = ("JJ", "JJR", "JJS") if wordnet_pos == "a" else ("RB", "RBR", "RBS")
            if is_base:
                tags.add(plain)
            if is_inflected:
                if lower.endswith("est"):
                    tags.add(superlative)
                elif lower.endswith("er"):
                    tags.add(comparative)
                else:
                    tags.add(plain)
    return tags


def softmax(scores: dict[str, float]) -> dict[str, float]:
    if not scores:
        return {}
    peak = max(scores.values())
    exps = {label: math.exp(score - peak) for label, score in scores.items()}
    total = sum(exps.values())
    return {label: value / total for label, value in exps.items()}


def ranked_candidates(
    word: str,
    best: str,
    probabilities: dict[str, float],
    in_tagdict: bool,
    top_k: int,
    min_probability: float,
    wordnet: Any | None,
) -> list[PosCandidate]:
    # Ties break on the label, exactly as NLTK chooses its best label.
    ranking = sorted(probabilities, key=lambda label: (probabilities[label], label), reverse=True)
    position = {label: index for index, label in enumerate(ranking)}

    def nltk_top_k() -> list[PosCandidate]:
        if in_tagdict:
            return [PosCandidate(best, "nltk")]
        others = [label for label in ranking if label != best and probabilities[label] >= min_probability]
        return [PosCandidate(tag, "nltk") for tag in [best, *others][:max(1, top_k)]]

    if best not in CONTENT_TAGS or wordnet is None:
        return nltk_top_k()
    allowed = wordnet_ptb_tags(word, wordnet)
    if not allowed:
        return nltk_top_k()
    others = sorted(allowed - {best}, key=lambda tag: (position.get(tag, len(ranking)), tag))
    return [PosCandidate(best, "nltk"), *(PosCandidate(tag, "wordnet") for tag in others)]


def nltk_tagger(top_k: int = 3, min_probability: float = 0.01, wordnet_expansion: bool = True) -> Tagger:
    try:
        from nltk.corpus import wordnet
        from nltk.stem import WordNetLemmatizer
        from nltk.tag import PerceptronTagger
    except ImportError as error:
        raise SystemExit("NLTK is not installed; install nltk explicitly") from error
    try:
        tagger = PerceptronTagger()
    except LookupError as error:
        raise SystemExit(
            "NLTK tagger data is not installed. Install it explicitly with "
            "nltk.download('averaged_perceptron_tagger_eng'); this tool never downloads data."
        ) from error
    try:
        wordnet.ensure_loaded()
    except LookupError as error:
        raise SystemExit(
            "NLTK WordNet data is not installed. Install it explicitly with "
            "nltk.download('wordnet'); this tool never downloads data."
        ) from error
    lemmatizer = WordNetLemmatizer()
    weights = tagger.model.weights

    def lemma(token: str, tag: str) -> str:
        if tag in ("NNP", "NNPS"):
            return token
        wordnet_pos = PTB_TO_WORDNET.get(tag[:1])
        lowered = token.lower()
        return lowered if wordnet_pos is None else lemmatizer.lemmatize(lowered, wordnet_pos)

    def scores_for(features: dict[str, int]) -> dict[str, float]:
        # Same dot product as AveragedPerceptron.predict, keeping every label.
        scores = {label: 0.0 for label in tagger.model.classes}
        for feature, value in features.items():
            if feature not in weights or value == 0:
                continue
            for label, weight in weights[feature].items():
                scores[label] += value * weight
        return scores

    def tag(tokens: list[str]) -> TaggedSentence:
        # Greedy left-to-right decoding identical to PerceptronTagger.tag, so
        # `pos` equals NLTK's output; the full score vector is kept per token.
        prev, prev2 = tagger.START
        context = tagger.START + [tagger.normalize(token) for token in tokens] + tagger.END
        best_tags: list[str] = []
        candidates: list[list[PosCandidate]] = []
        for index, token in enumerate(tokens):
            probabilities = softmax(scores_for(tagger._get_features(index, token, context, prev, prev2)))
            dictionary_tag = tagger.tagdict.get(token)
            best = dictionary_tag or max(probabilities, key=lambda label: (probabilities[label], label))
            candidates.append(ranked_candidates(
                token, best, probabilities, dictionary_tag is not None, top_k, min_probability,
                wordnet if wordnet_expansion else None,
            ))
            best_tags.append(best)
            prev2, prev = prev, best
        return TaggedSentence(
            [lemma(token, pos) for token, pos in zip(tokens, best_tags, strict=True)],
            best_tags,
            [{} for _ in tokens],
            candidates,
        )

    return tag


def spacy_tagger(model: str) -> Tagger:
    try:
        import spacy
        from spacy.tokens import Doc
    except ImportError as error:
        raise SystemExit("spaCy is not installed; install spaCy and the requested model explicitly") from error
    try:
        nlp = spacy.load(model)
    except OSError as error:
        raise SystemExit(f"spaCy model {model!r} is not installed") from error

    def tag(tokens: list[str]) -> TaggedSentence:
        doc = nlp(Doc(nlp.vocab, words=tokens))
        return TaggedSentence(
            [token.lemma_ or token.text for token in doc],
            [token.pos_ for token in doc],
            [dict(item.split("=", 1) for item in str(token.morph).split("|") if "=" in item) for token in doc],
        )

    return tag


def stanza_tagger(language: str) -> Tagger:
    try:
        import stanza
    except ImportError as error:
        raise SystemExit("Stanza is not installed; install stanza and its language model explicitly") from error
    try:
        pipeline = stanza.Pipeline(language, processors="tokenize,pos,lemma", tokenize_pretokenized=True, download_method=None)
    except Exception as error:
        raise SystemExit(f"unable to load the installed Stanza model for {language!r}: {error}") from error

    def tag(tokens: list[str]) -> TaggedSentence:
        document = pipeline([tokens])
        words = [word for sentence in document.sentences for word in sentence.words]
        morph = [dict(item.split("=", 1) for item in (word.feats or "").split("|") if "=" in item) for word in words]
        return TaggedSentence([word.lemma or word.text for word in words], [word.upos or "" for word in words], morph)

    return tag


def enrich(input_path: Path, output_path: Path, tagger: Tagger) -> int:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with input_path.open(encoding="utf-8") as source, output_path.open("w", encoding="utf-8", newline="\n") as target:
        for line_number, line in enumerate(source, 1):
            if not line.strip():
                continue
            try:
                record: dict[str, Any] = json.loads(line)
                tokens = [str(token) for token in record["tokens"]]
            except (json.JSONDecodeError, KeyError, TypeError) as error:
                raise ValueError(f"{input_path}:{line_number}: invalid corpus record: {error}") from error
            tagged = tagger(tokens)
            lengths = {len(tokens), len(tagged.lemmas), len(tagged.pos), len(tagged.morph)}
            if tagged.pos_candidates is not None:
                lengths.add(len(tagged.pos_candidates))
            if len(lengths) != 1:
                raise ValueError(f"{input_path}:{line_number}: tagger changed token alignment")
            record.update({"lemmas": tagged.lemmas, "pos": tagged.pos, "morph": tagged.morph})
            if tagged.pos_candidates is not None:
                record["pos_candidates"] = [
                    [candidate.to_json() for candidate in token_candidates]
                    for token_candidates in tagged.pos_candidates
                ]
            else:
                record.pop("pos_candidates", None)
            target.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
            count += 1
    return count


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--backend", choices=("nltk", "spacy", "stanza"), default="nltk")
    parser.add_argument(
        "--model",
        help="spaCy model (default en_core_web_sm) or Stanza language code (default en); unused by nltk",
    )
    parser.add_argument("--top-k", type=int, default=3,
                        help="nltk: tags kept for function words, proper nouns, and words absent from WordNet")
    parser.add_argument("--min-probability", type=float, default=0.01,
                        help="nltk: drop non-best top-k tags below this softmax probability")
    parser.add_argument("--no-wordnet-expansion", action="store_true",
                        help="nltk: use top-k tags for content words too, without WordNet")
    args = parser.parse_args()
    if args.top_k < 1:
        parser.error("--top-k must be at least 1")
    if args.backend == "nltk":
        tagger = nltk_tagger(args.top_k, args.min_probability, not args.no_wordnet_expansion)
    elif args.backend == "spacy":
        tagger = spacy_tagger(args.model or "en_core_web_sm")
    else:
        tagger = stanza_tagger(args.model or "en")
    count = enrich(args.input, args.output, tagger)
    print(f"wrote {count} enriched sentences to {args.output}")


if __name__ == "__main__":
    main()
