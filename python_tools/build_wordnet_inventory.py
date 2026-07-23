#!/usr/bin/env python3
"""Build a deterministic lemma-to-Universal-POS inventory from NLTK WordNet."""

from __future__ import annotations

import argparse
import json
from collections.abc import Iterable
from pathlib import Path
from typing import Any

WORDNET_TO_UPOS = {"n": "NOUN", "v": "VERB", "a": "ADJ", "s": "ADJ", "r": "ADV"}


def corpus_lemmas(path: Path) -> set[str]:
    lemmas: set[str] = set()
    with path.open(encoding="utf-8") as source:
        for line_number, line in enumerate(source, 1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
                tokens = record["tokens"]
            except (json.JSONDecodeError, KeyError, TypeError) as error:
                raise ValueError(f"{path}:{line_number}: invalid corpus record: {error}") from error
            values = record.get("lemmas", tokens)
            if len(values) != len(tokens):
                raise ValueError(f"{path}:{line_number}: lemmas and tokens must have equal length")
            lemmas.update(str(value).lower() for value in values if str(value).strip())
    return lemmas


def universal_pos(synsets: Iterable[Any]) -> list[str]:
    return sorted({WORDNET_TO_UPOS[pos] for synset in synsets if (pos := synset.pos()) in WORDNET_TO_UPOS})


def build_inventory(path: Path, wordnet: Any) -> dict[str, list[str]]:
    return {lemma: universal_pos(wordnet.synsets(lemma)) for lemma in sorted(corpus_lemmas(path))}


def require_wordnet() -> Any:
    try:
        from nltk.corpus import wordnet
    except ImportError as error:
        raise SystemExit("NLTK is not installed; install nltk and the WordNet corpus explicitly") from error
    try:
        wordnet.ensure_loaded()
    except LookupError as error:
        raise SystemExit(
            "NLTK WordNet data is not installed. Install it explicitly; this tool never downloads data automatically."
        ) from error
    return wordnet


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    inventory = build_inventory(args.corpus, require_wordnet())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(inventory, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(inventory)} lemma entries to {args.output}")


if __name__ == "__main__":
    main()
