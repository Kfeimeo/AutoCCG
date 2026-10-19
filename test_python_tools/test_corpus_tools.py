from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


download_corpora = load("download_corpora", "python_tools/download_corpora.py")
experiment = load("run_discovery_experiment", "python_tools/run_discovery_experiment.py")
wordnet_inventory = load("build_wordnet_inventory", "python_tools/build_wordnet_inventory.py")
pos_enrichment = load("enrich_with_pos", "python_tools/enrich_with_pos.py")


class CorpusToolsTest(unittest.TestCase):
    def test_tokenizer_preserves_punctuation_and_contractions(self) -> None:
        self.assertEqual(
            download_corpora.tokenize("John doesn't run."),
            ["John", "doesn't", "run", "."],
        )

    def test_sentence_split(self) -> None:
        self.assertEqual(
            list(download_corpora.split_sentences("One. Two?")),
            ["One.", "Two?"],
        )

    def test_category_depth_is_deterministic(self) -> None:
        self.assertEqual(experiment.category_depth("(S\\NP)/NP"), 2)
        self.assertEqual(experiment.normalized_template(" (S\\NP) / NP "), "(S\\NP)/NP")

    def test_wordnet_pos_mapping_deduplicates_satellite_adjectives(self) -> None:
        class Synset:
            def __init__(self, value: str) -> None:
                self.value = value

            def pos(self) -> str:
                return self.value

        self.assertEqual(
            wordnet_inventory.universal_pos([Synset("n"), Synset("v"), Synset("a"), Synset("s")]),
            ["ADJ", "NOUN", "VERB"],
        )

    def test_pos_enrichment_preserves_alignment(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "input.jsonl"
            output = root / "output.jsonl"
            source.write_text(json.dumps({"sentence_id": "s", "tokens": ["Runs"]}) + "\n", encoding="utf-8")
            count = pos_enrichment.enrich(
                source, output, lambda tokens: (["run"], ["VERB"], [{"Tense": "Pres"}]),
            )
            record = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(count, 1)
            self.assertEqual(record["pos"], ["VERB"])
            self.assertEqual(record["morph"], [{"Tense": "Pres"}])


    def test_nltk_backend_writes_aligned_penn_treebank_tags(self) -> None:
        try:
            tag = pos_enrichment.nltk_tagger()
        except SystemExit as error:
            self.skipTest(str(error))
        lemmas, pos, morph = tag(["Mary", "gave", "the", "dogs", "bones", "."])
        self.assertEqual(len(pos), 6)
        self.assertEqual(pos[0], "NNP")
        self.assertEqual(pos[1], "VBD")
        self.assertEqual(pos[-1], ".")
        self.assertEqual(lemmas[:4], ["Mary", "give", "the", "dog"])
        self.assertEqual(morph, [{}] * 6)

if __name__ == "__main__":
    unittest.main()
