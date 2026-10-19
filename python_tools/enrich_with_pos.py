#!/usr/bin/env python3
"""Explicitly enrich tokenized JSONL with lemmas, POS tags, and morphology.

Backends:

- ``nltk`` (default): NLTK's averaged-perceptron tagger writes fine-grained
  Penn Treebank tags (``NNP``, ``VBZ``, ``JJR`` ...), which the configured
  ``pos_mapping`` cascade maps to CCG prior categories; lemmas come from the
  WordNet lemmatizer and ``morph`` is left empty.
- ``spacy`` / ``stanza``: Universal POS tags plus UD morphology.

The token-to-category mapping itself is not done here; it belongs to the
Haskell candidate builder (``ccg-induction build-candidates``).
"""

from __future__ import annotations

import argparse
import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

Tagger = Callable[[list[str]], tuple[list[str], list[str], list[dict[str, str]]]]


PTB_TO_WORDNET = {"J": "a", "N": "n", "R": "r", "V": "v"}


def nltk_tagger() -> Tagger:
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

    def lemma(token: str, tag: str) -> str:
        if tag in ("NNP", "NNPS"):
            return token
        wordnet_pos = PTB_TO_WORDNET.get(tag[:1])
        lowered = token.lower()
        return lowered if wordnet_pos is None else lemmatizer.lemmatize(lowered, wordnet_pos)

    def tag(tokens: list[str]) -> tuple[list[str], list[str], list[dict[str, str]]]:
        # The tagger receives the existing tokens, so alignment is preserved.
        tagged = tagger.tag(tokens)
        return (
            [lemma(token, pos) for token, pos in tagged],
            [pos for _, pos in tagged],
            [{} for _ in tagged],
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

    def tag(tokens: list[str]) -> tuple[list[str], list[str], list[dict[str, str]]]:
        doc = nlp(Doc(nlp.vocab, words=tokens))
        return (
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

    def tag(tokens: list[str]) -> tuple[list[str], list[str], list[dict[str, str]]]:
        document = pipeline([tokens])
        words = [word for sentence in document.sentences for word in sentence.words]
        morph = [dict(item.split("=", 1) for item in (word.feats or "").split("|") if "=" in item) for word in words]
        return [word.lemma or word.text for word in words], [word.upos or "" for word in words], morph

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
            lemmas, pos, morph = tagger(tokens)
            if not (len(tokens) == len(lemmas) == len(pos) == len(morph)):
                raise ValueError(f"{input_path}:{line_number}: tagger changed token alignment")
            record.update({"lemmas": lemmas, "pos": pos, "morph": morph})
            target.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
            count += 1
    return count


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--backend", choices=("nltk", "spacy", "stanza"), default="nltk")
    parser.add_argument(
        "--model",
        help="spaCy model (default en_core_web_sm) or Stanza language code (default en); unused by nltk",
    )
    args = parser.parse_args()
    if args.backend == "nltk":
        tagger = nltk_tagger()
    elif args.backend == "spacy":
        tagger = spacy_tagger(args.model or "en_core_web_sm")
    else:
        tagger = stanza_tagger(args.model or "en")
    count = enrich(args.input, args.output, tagger)
    print(f"wrote {count} enriched sentences to {args.output}")


if __name__ == "__main__":
    main()
