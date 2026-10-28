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
                source, output,
                lambda tokens: pos_enrichment.TaggedSentence(["run"], ["VERB"], [{"Tense": "Pres"}]),
            )
            record = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(count, 1)
            self.assertEqual(record["pos"], ["VERB"])
            self.assertEqual(record["morph"], [{"Tense": "Pres"}])
            self.assertNotIn("pos_candidates", record)

    def test_pos_enrichment_writes_ranked_candidates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "input.jsonl"
            output = root / "output.jsonl"
            source.write_text(json.dumps({"sentence_id": "s", "tokens": ["book"]}) + "\n", encoding="utf-8")
            candidates = [[pos_enrichment.PosCandidate("NN", "nltk"), pos_enrichment.PosCandidate("VB", "wordnet")]]
            pos_enrichment.enrich(
                source, output,
                lambda tokens: pos_enrichment.TaggedSentence(["book"], ["NN"], [{}], candidates),
            )
            record = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(record["pos_candidates"],
                             [[{"tag": "NN", "source": "nltk"}, {"tag": "VB", "source": "wordnet"}]])

    def test_ranked_candidates_split_function_and_content_words(self) -> None:
        wordnet = require_wordnet_or_skip(self)
        probabilities = {"NN": 0.6, "VB": 0.3, "JJ": 0.09, "IN": 0.01, "DT": 0.0}
        rank = pos_enrichment.ranked_candidates
        # Content word: NLTK's best tag, then every WordNet tag by NLTK score.
        self.assertEqual(
            rank("book", "NN", probabilities, False, 3, 0.01, wordnet),
            [pos_enrichment.PosCandidate("NN", "nltk"), pos_enrichment.PosCandidate("VB", "wordnet"),
             pos_enrichment.PosCandidate("VBP", "wordnet")],
        )
        # Function word: NLTK top-k above the probability floor.
        self.assertEqual([c.tag for c in rank("Either", "DT", {"DT": 0.7, "CC": 0.25, "RB": 0.004}, False, 3, 0.01, wordnet)],
                         ["DT", "CC"])
        # Tag-dictionary words are unambiguous to NLTK.
        self.assertEqual([c.tag for c in rank("the", "DT", probabilities, True, 3, 0.01, wordnet)], ["DT"])
        # Content word missing from WordNet falls back to NLTK top-k.
        self.assertEqual([c.tag for c in rank("blorked", "VBD", {"VBD": 0.5, "VBN": 0.4, "JJ": 0.1}, False, 2, 0.01, wordnet)],
                         ["VBD", "VBN"])

    def test_wordnet_ptb_tags_read_inflection(self) -> None:
        wordnet = require_wordnet_or_skip(self)
        tags = pos_enrichment.wordnet_ptb_tags
        self.assertEqual(tags("sleeps", wordnet), {"NNS", "VBZ"})
        self.assertEqual(tags("ran", wordnet), {"VBD", "VBN"})
        self.assertIn("JJR", tags("bigger", wordnet))
        self.assertIn("JJS", tags("biggest", wordnet))
        self.assertIn("VBG", tags("running", wordnet))
        self.assertEqual(tags("the", wordnet), set())


    def test_nltk_backend_writes_aligned_penn_treebank_tags(self) -> None:
        try:
            tag = pos_enrichment.nltk_tagger()
        except SystemExit as error:
            self.skipTest(str(error))
        lemmas, pos, morph, candidates = tag(["Mary", "gave", "the", "dogs", "bones", "."])
        self.assertEqual(len(pos), 6)
        self.assertEqual([token[0].tag for token in candidates], pos)
        self.assertIn("VBZ", [c.tag for c in candidates[3]])
        self.assertEqual(pos[0], "NNP")
        self.assertEqual(pos[1], "VBD")
        self.assertEqual(pos[-1], ".")
        self.assertEqual(lemmas[:4], ["Mary", "give", "the", "dog"])
        self.assertEqual(morph, [{}] * 6)

def require_wordnet_or_skip(test: unittest.TestCase):
    try:
        from nltk.corpus import wordnet
        wordnet.ensure_loaded()
    except (ImportError, LookupError) as error:
        test.skipTest(str(error))
    return wordnet


if __name__ == "__main__":
    unittest.main()
