#!/usr/bin/env python3
"""Build a deterministic word-level CandidateLexicon from POS, WordNet, and seeds."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

SOURCE_ORDER = {
    "FromSeedLexicon": 0,
    "FromPosTemplate": 1,
    "FromWordNetPos": 2,
    "FromUnknownFallback": 3,
}

COMMA_TOKENS = {",", "，"}
FINAL_PUNCTUATION_TOKENS = {".", "!", "?", "。", "！", "？"}


def inferred_pos(word: str) -> str:
    """Return a small, deterministic shape-based POS fallback.

    This is deliberately limited to closed-form punctuation and numeric shapes;
    it is not a replacement for token-level POS tagging.
    """
    if word in COMMA_TOKENS:
        return "PUNCT_COMMA"
    if word in FINAL_PUNCTUATION_TOKENS:
        return "PUNCT_FINAL"
    numeric_body = word[1:] if word.startswith(("+", "-")) else word
    numeric_body = numeric_body[:-1] if numeric_body.endswith("%") else numeric_body
    if numeric_body[:1].isdigit() and numeric_body[-1:].isdigit() and all(
        character.isdigit() or character in ".," for character in numeric_body
    ):
        return "NUM"
    return ""


def load_yaml(path: Path) -> dict[str, Any]:
    try:
        import yaml
    except ImportError as error:
        raise SystemExit("PyYAML is required to read candidate configuration") from error
    with path.open(encoding="utf-8") as source:
        value = yaml.safe_load(source) or {}
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected a YAML object")
    return value


def add_candidate(entries: dict[str, dict[str, Any]], word: str, lemma: str, pos: str, candidate: dict[str, Any]) -> None:
    entry = entries.setdefault(word, {"word": word, "lemma": lemma, "pos": pos, "candidates": {}})
    category = str(candidate["category"])
    normalized = {
        "category": category,
        "prior_cost": int(candidate.get("prior_cost", 0)),
        "source": str(candidate["source"]),
        "locked": bool(candidate.get("locked", False)),
    }
    old = entry["candidates"].get(category)
    ordering = lambda item: (item["prior_cost"], SOURCE_ORDER[item["source"]], item["category"])
    if old is None or ordering(normalized) < ordering(old):
        normalized["locked"] = normalized["locked"] or bool(old and old["locked"])
        entry["candidates"][category] = normalized
    elif normalized["locked"]:
        old["locked"] = True


def build_candidates(corpus: Path, wordnet_path: Path | None, config: dict[str, Any]) -> dict[str, Any]:
    inventory = json.loads(wordnet_path.read_text(encoding="utf-8")) if wordnet_path else {}
    templates: dict[str, list[dict[str, Any]]] = config.get("pos_to_categories", {})
    seeds: dict[str, list[dict[str, Any]]] = config.get("seed_lexicon", {})
    entries: dict[str, dict[str, Any]] = {}
    with corpus.open(encoding="utf-8") as source:
        for line_number, line in enumerate(source, 1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
                tokens = [str(value) for value in record["tokens"]]
            except (json.JSONDecodeError, KeyError, TypeError) as error:
                raise ValueError(f"{corpus}:{line_number}: invalid corpus record: {error}") from error
            lemmas = [str(value) for value in record.get("lemmas", tokens)]
            pos_values = [str(value) for value in record.get("pos", [])]
            if len(lemmas) != len(tokens) or (pos_values and len(pos_values) != len(tokens)):
                raise ValueError(f"{corpus}:{line_number}: tokens/lemmas/POS alignment mismatch")
            for index, (word, lemma) in enumerate(zip(tokens, lemmas, strict=True)):
                explicit_pos = pos_values[index] if pos_values else ""
                if explicit_pos:
                    # UPOS PUNCT is intentionally refined by the token itself:
                    # final punctuation must not inherit comma-only candidates.
                    template_pos = inferred_pos(word) if explicit_pos == "PUNCT" else explicit_pos
                    pos_sources = [(template_pos or explicit_pos, "FromPosTemplate")]
                elif shape_pos := inferred_pos(word):
                    pos_sources = [(shape_pos, "FromUnknownFallback")]
                else:
                    pos_sources = [
                        (value, "FromWordNetPos") for value in inventory.get(lemma.lower(), [])
                    ]
                for pos, source_name in pos_sources:
                    for template in templates.get(pos, []):
                        add_candidate(entries, word, lemma, explicit_pos or pos, {**template, "source": source_name})
                for seed in seeds.get(word.lower(), []):
                    add_candidate(entries, word, lemma, explicit_pos, {
                        **seed, "source": "FromSeedLexicon", "locked": bool(seed.get("lock", False)),
                    })
    maximum = int(config.get("candidate_constraints", {}).get("max_candidates_per_word", 8))
    output_entries = []
    for word in sorted(entries):
        entry = entries[word]
        candidates = sorted(entry.pop("candidates").values(), key=lambda item: (
            item["prior_cost"], SOURCE_ORDER[item["source"]], item["category"]
        ))[:maximum]
        if candidates:
            output_entries.append({**entry, "candidates": candidates})
    return {"version": 1, "entries": output_entries}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--wordnet", type=Path)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    document = build_candidates(args.corpus, args.wordnet, load_yaml(args.config))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(document['entries'])} candidate entries to {args.output}")


if __name__ == "__main__":
    main()
