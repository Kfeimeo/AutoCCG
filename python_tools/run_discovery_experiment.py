#!/usr/bin/env python3
"""Run the Haskell inducer and aggregate interpretable discovery diagnostics."""

from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open(encoding="utf-8") as source:
        return [json.loads(line) for line in source if line.strip()]


def category_depth(category: str) -> int:
    """Parse-free structural depth for the serializer's fully parenthesized forms."""
    max_depth = depth = 1
    for char in category:
        if char == "(":
            depth += 1
            max_depth = max(max_depth, depth)
        elif char == ")":
            depth = max(1, depth - 1)
    return max_depth


def normalized_template(category: str) -> str:
    # Atoms are already drawn from a small readable inventory. Whitespace is
    # the only irrelevant variation in serialized templates.
    return "".join(category.split())


def context_windows(corpus: list[dict[str, Any]], width: int = 2) -> dict[str, list[str]]:
    contexts: dict[str, list[str]] = defaultdict(list)
    for sentence in corpus:
        tokens = sentence["tokens"]
        for index, token in enumerate(tokens):
            if len(contexts[token]) < 3:
                left = " ".join(tokens[max(0, index - width):index])
                right = " ".join(tokens[index + 1:index + 1 + width])
                contexts[token].append(f"{left} [{token}] {right}".strip())
    return contexts


def write_report(corpus_path: Path, run_dir: Path) -> None:
    corpus = read_jsonl(corpus_path)
    metrics = read_jsonl(run_dir / "training_metrics.jsonl")
    unresolved = read_jsonl(run_dir / "unresolved.jsonl")
    grammar = json.loads((run_dir / "grammar.json").read_text(encoding="utf-8"))
    lexicon: dict[str, list[str]] = grammar["lexicon"]
    provenance = {
        (entry["word"], entry["category"]): entry
        for entry in grammar.get("provenance", [])
    }
    frequencies = Counter(token for sentence in corpus for token in sentence["tokens"])
    sentence_sets: dict[str, set[str]] = defaultdict(set)
    for sentence in corpus:
        for token in set(sentence["tokens"]):
            sentence_sets[token].add(sentence["sentence_id"])
    contexts = context_windows(corpus)

    categories = [category for values in lexicon.values() for category in values]
    category_words: dict[str, list[str]] = defaultdict(list)
    for word, values in lexicon.items():
        for category in values:
            category_words[category].append(word)
    atoms = {
        atom
        for category in categories
        for atom in category.replace("(", " ").replace(")", " ").replace("/", " ").replace("\\", " ").split()
    }
    depth_distribution = Counter(category_depth(category) for category in set(categories))
    rule_counts = {
        "application": sum(int(row.get("application_uses", 0)) for row in metrics),
        "composition": sum(int(row.get("composition_uses", 0)) for row in metrics),
        "type_raising": sum(int(row.get("type_raising_uses", 0)) for row in metrics),
    }
    rule_total = sum(rule_counts.values())
    repair_by_length: dict[int, list[int]] = defaultdict(list)
    for row in metrics:
        repair_by_length[int(row.get("sentence_length", 0))].append(int(row.get("repairs", 0)))

    summary = {
        "version": 1,
        "sentence_count": len(corpus),
        "unresolved_sentence_count": len(unresolved),
        "atomic_category_count": len(atoms),
        "atomic_categories": sorted(atoms),
        "compound_category_template_count": len({
            normalized_template(category) for category in categories if "/" in category or "\\" in category
        }),
        "average_categories_per_word": (
            sum(map(len, lexicon.values())) / len(lexicon) if lexicon else 0.0
        ),
        "category_depth_distribution": dict(sorted(depth_distribution.items())),
        "rule_uses": rule_counts,
        "rule_use_ratios": {
            name: count / rule_total if rule_total else 0.0 for name, count in rule_counts.items()
        },
        "repairs_by_sentence_length": {
            str(length): {
                "sentences": len(values),
                "repairs": sum(values),
                "mean_repairs": sum(values) / len(values),
            }
            for length, values in sorted(repair_by_length.items())
        },
        "words_with_most_second_categories": [
            {"word": word, "category_count": len(values), "categories": values}
            for word, values in sorted(
                lexicon.items(), key=lambda item: (-max(0, len(item[1]) - 1), -frequencies[item[0]], item[0])
            )
            if len(values) > 1
        ][:50],
        "singleton_special_categories": [
            {"category": category, "word": words[0]}
            for category, words in sorted(category_words.items())
            if len(words) == 1 and ("/" in category or "\\" in category)
        ],
        "unresolved_examples": [
            {"sentence_id": row["sentence_id"], "tokens": row["tokens"], "length": len(row["tokens"])}
            for row in unresolved[:50]
        ],
    }
    (run_dir / "discovery_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    with (run_dir / "lexicon_observations.csv").open("w", encoding="utf-8", newline="") as target:
        writer = csv.writer(target)
        writer.writerow([
            "word", "category", "word_frequency", "covered_sentence_count",
            "typical_contexts", "best_derivation_example",
            "repair_provenance", "composition_dependency",
            "type_raising_dependency",
        ])
        for word in sorted(lexicon, key=lambda item: (-frequencies[item], item)):
            for category in lexicon[word]:
                category_provenance = provenance.get((word, category), {})
                writer.writerow([
                    word, category, frequencies[word], len(sentence_sets[word]),
                    " | ".join(contexts[word]),
                    "not_serialized_by_core",
                    json.dumps(category_provenance, ensure_ascii=False, sort_keys=True) if category_provenance else "legacy_untracked",
                    "not_tracked_by_core",
                    "not_tracked_by_core",
                ])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--jobs", "-j", type=int,
        default=max(1, min(8, os.cpu_count() or 1)),
        help="Haskell parallel workers (default: min(8, logical CPU count))",
    )
    parser.add_argument("--skip-train", action="store_true")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be at least 1")
    args.output.mkdir(parents=True, exist_ok=True)
    if not args.skip_train:
        subprocess.run([
            "cabal", "run", "ccg-induction", "--", "train",
            "--corpus", str(args.corpus), "--config", str(args.config),
            "--output", str(args.output), "--jobs", str(args.jobs),
        ], check=True)
    write_report(args.corpus, args.output)
    print(f"wrote discovery diagnostics to {args.output}")


if __name__ == "__main__":
    main()
