#!/usr/bin/env python3
"""Explicitly enrich tokenized JSONL with lemma, Universal POS, and morphology."""

from __future__ import annotations

import argparse
import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

Tagger = Callable[[list[str]], tuple[list[str], list[str], list[dict[str, str]]]]


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
    parser.add_argument("--backend", choices=("spacy", "stanza"), default="spacy")
    parser.add_argument("--model", default="en_core_web_sm", help="spaCy model or Stanza language code")
    args = parser.parse_args()
    tagger = spacy_tagger(args.model) if args.backend == "spacy" else stanza_tagger(args.model)
    count = enrich(args.input, args.output, tagger)
    print(f"wrote {count} enriched sentences to {args.output}")


if __name__ == "__main__":
    main()
