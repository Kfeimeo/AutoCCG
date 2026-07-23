from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class CandidateCliIntegrationTest(unittest.TestCase):
    def test_inspect_candidates_prints_prior_and_source(self) -> None:
        completed = subprocess.run(
            [
                "cabal", "run", "ccg-induction", "--", "inspect-candidates",
                "--candidate-lexicon", "examples/toy-candidates.json",
                "--word", "likes",
            ],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
            timeout=120,
        )
        self.assertIn("(S\\NP)/NP", completed.stdout)
        self.assertIn("prior=0 source=FromPosTemplate", completed.stdout)


if __name__ == "__main__":
    unittest.main()
