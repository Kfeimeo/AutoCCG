from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]


def run_cli(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["cabal", "run", "-v0", "ccg-induction", "--", *arguments],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
        timeout=120,
    )


def build_candidates(
    records: list[dict[str, Any]], config: dict[str, Any], inventory: dict[str, list[str]] | None = None,
) -> dict[str, list[dict[str, Any]]]:
    """Run ``build-candidates`` and return candidates keyed by word.

    The configuration is written as JSON, which is valid YAML.
    """
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        corpus = root / "corpus.jsonl"
        config_path = root / "config.yaml"
        output = root / "candidates.json"
        corpus.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
        config_path.write_text(json.dumps({"candidate_constraints": {"enabled": True}, **config}), encoding="utf-8")
        arguments = ["build-candidates", "--corpus", str(corpus), "--config", str(config_path), "--output", str(output)]
        if inventory is not None:
            inventory_path = root / "wordnet.json"
            inventory_path.write_text(json.dumps(inventory), encoding="utf-8")
            arguments += ["--wordnet", str(inventory_path)]
        run_cli(*arguments)
        document = json.loads(output.read_text(encoding="utf-8"))
    assert document["version"] == 1
    return {entry["word"]: entry["candidates"] for entry in document["entries"]}


def categories(candidates: list[dict[str, Any]]) -> list[str]:
    return [item["category"] for item in candidates]


class CandidateCliIntegrationTest(unittest.TestCase):
    def test_inspect_candidates_prints_prior_and_source(self) -> None:
        completed = run_cli(
            "inspect-candidates", "--candidate-lexicon", "examples/toy-candidates.json", "--word", "likes",
        )
        self.assertIn("(S\\NP)/NP", completed.stdout)
        self.assertIn("prior=0 source=FromPosTemplate", completed.stdout)

    def test_build_candidates_prefers_token_pos_and_merges_seed(self) -> None:
        entries = build_candidates(
            [{"sentence_id": "s", "tokens": ["book"], "lemmas": ["book"], "pos": ["VERB"]}],
            {
                "pos_to_categories": {
                    "NOUN": [{"category": "N", "prior_cost": 0}],
                    "VERB": [{"category": "S\\NP", "prior_cost": 1}],
                },
                "seed_lexicon": {"book": [{"category": "NP", "prior_cost": 0, "lock": True}]},
            },
            {"book": ["NOUN"]},
        )
        self.assertEqual(categories(entries["book"]), ["NP", "S\\NP"])
        self.assertTrue(entries["book"][0]["locked"])

    def test_build_candidates_uses_wordnet_only_when_token_pos_is_missing(self) -> None:
        entries = build_candidates(
            [{"sentence_id": "s", "tokens": ["book"], "lemmas": ["book"]}],
            {
                "pos_to_categories": {
                    "NOUN": [{"category": "N", "prior_cost": 0}],
                    "VERB": [{"category": "S\\NP", "prior_cost": 1}],
                },
            },
            {"book": ["NOUN", "VERB"]},
        )
        self.assertEqual(categories(entries["book"]), ["N", "S\\NP"])
        self.assertTrue(all(item["source"] == "FromWordNetPos" for item in entries["book"]))

    def test_build_candidates_infers_punctuation_and_numeric_shapes_without_pos(self) -> None:
        entries = build_candidates(
            [{"sentence_id": "s", "tokens": ["42", "?"]}],
            {
                "pos_to_categories": {
                    "NUM": [{"category": "N/N", "prior_cost": 0}, {"category": "NP", "prior_cost": 1}],
                    "PUNCT_FINAL": [{"category": "S\\S", "prior_cost": 0}],
                },
            },
        )
        self.assertEqual(categories(entries["42"]), ["N/N", "NP"])
        self.assertEqual(categories(entries["?"]), ["S\\S"])
        self.assertTrue(all(
            item["source"] == "FromUnknownFallback" for candidates in entries.values() for item in candidates
        ))

    def test_upos_punctuation_is_refined_by_symbol(self) -> None:
        entries = build_candidates(
            [{"sentence_id": "s", "tokens": [",", "!"], "pos": ["PUNCT", "PUNCT"]}],
            {
                "pos_to_categories": {
                    "PUNCT_COMMA": [{"category": "(S\\S)/S", "prior_cost": 0}],
                    "PUNCT_FINAL": [{"category": "S\\S", "prior_cost": 0}],
                },
            },
        )
        self.assertEqual(categories(entries[","])[0], "(S\\S)/S")
        self.assertEqual(categories(entries["!"])[0], "S\\S")

    def test_pos_mapping_cascade_uses_first_matching_penn_treebank_rule(self) -> None:
        entries = build_candidates(
            [{
                "sentence_id": "s",
                "tokens": ["John", "is", "running", "."],
                "pos": ["NNP", "VBZ", "VBG", "."],
            }],
            {
                "pos_mapping": {
                    "templates": {
                        "proper_noun": [{"category": "NP", "prior_cost": 0}],
                        "verb": [{"category": "S\\NP", "prior_cost": 0}],
                        "participle_modifier": [{"category": "N/N", "prior_cost": 2}],
                    },
                    "rules": [
                        {"tags": ["NNP", "NNPS"], "templates": ["proper_noun"]},
                        {"prefix": "VB", "templates": ["verb"]},
                        {"tag": "VBG", "templates": ["verb", "participle_modifier"]},
                    ],
                },
            },
        )
        self.assertEqual(categories(entries["John"]), ["NP"])
        # prefix VB precedes the VBG rule, so the first match wins.
        self.assertEqual(categories(entries["running"]), ["S\\NP"])
        self.assertNotIn(".", entries)


ASP_GRAMMAR = {
    "version": 1,
    "root": "S",
    # "f John read" needs John+read as S/NP: ASP at the Application level, or
    # Type-raising plus Composition without it.
    "lexicon": {"f": ["S/(S/NP)"], "John": ["NP"], "read": ["(S\\NP)/NP"]},
}


def parse_level(grammar_dir: Path, *extra: str) -> tuple[str, str]:
    completed = run_cli("parse", "--grammar", str(grammar_dir / "grammar.json"), *extra, "--sentence", "f John read")
    return json.loads(completed.stdout)["level"], completed.stderr


class RuleConfigCliIntegrationTest(unittest.TestCase):
    def test_parse_uses_explicit_config_rules(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "grammar.json").write_text(json.dumps(ASP_GRAMMAR), encoding="utf-8")
            config = root / "asp.yaml"
            config.write_text(json.dumps({"rules": {"allow_argument_swap": True}}), encoding="utf-8")
            level, stderr = parse_level(root)
            self.assertEqual(level, "WithTypeRaising")
            self.assertIn("built-in default", stderr)
            level, stderr = parse_level(root, "--config", str(config))
            self.assertEqual(level, "ApplicationOnly")
            self.assertIn("asp.yaml", stderr)

    def test_parse_prefers_training_config_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "grammar.json").write_text(json.dumps(ASP_GRAMMAR), encoding="utf-8")
            (root / "config.snapshot.yaml").write_text(
                json.dumps({"rules": {"allow_argument_swap": True}}), encoding="utf-8")
            level, stderr = parse_level(root)
            self.assertEqual(level, "ApplicationOnly")
            self.assertIn("config.snapshot.yaml", stderr)

    def test_inspect_candidates_uses_config_bounds(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            candidates = Path(directory) / "candidates.json"
            candidates.write_text(json.dumps({"version": 1, "entries": [{
                "word": "and",
                "candidates": [{"category": "((S\\NP)\\(S\\NP))/(S\\NP)", "prior_cost": 0,
                                "source": "FromPosTemplate", "locked": False}],
            }]}), encoding="utf-8")
            arguments = ["inspect-candidates", "--candidate-lexicon", str(candidates), "--word", "and"]
            with self.assertRaises(subprocess.CalledProcessError):
                run_cli(*arguments)  # five slashes exceed the built-in max_slashes of 4
            completed = run_cli(*arguments[:3], "--config", "configs/default.yaml", *arguments[3:])
            self.assertIn("((S\\NP)\\(S\\NP))/(S\\NP)", completed.stdout)


if __name__ == "__main__":
    unittest.main()
