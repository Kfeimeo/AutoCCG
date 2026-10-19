# Changelog

## Unreleased

- Replace the flat POS-to-category table with a lightblue-style `pos_mapping`:
  named category templates selected by an ordered first-match rule cascade
  over POS tags (`tag`, `tags`, or `prefix`), validated at configuration load.
  `pos_to_categories` remains accepted as shorthand for trailing exact-tag
  rules.
- Default configurations map the full Penn Treebank tagset produced by NLTK in
  addition to Universal POS, and add unlocked auxiliary seeds for forms of
  `be`, `have`, and `do`.
- Add an NLTK averaged-perceptron backend (now the default) to
  `python_tools/enrich_with_pos.py`, writing Penn Treebank tags and WordNet
  lemmas.
- Add the `build-candidates` CLI command and move the WordNet POS fallback
  into Haskell (`candidate_constraints.wordnet_inventory_path` or
  `--wordnet`). Remove `python_tools/build_candidate_lexicon.py`, which
  duplicated the Haskell candidate logic; the candidate JSON format is
  unchanged (version 1).
- Legacy initialization (candidate constraints disabled) now uses the
  configured POS mapping instead of hardcoded Penn Treebank guesses.

## 0.1.0.0

- Initial bounded CCG induction implementation.
- Fuse Type-raising with an immediately applicable Composition reduction so
  raised categories never persist in parser beams.
- Gate Composition with an Application-only right-context reachability chart.
- Add a separate, bounded CandidateLexicon loaded from deterministic JSON.
- Add configurable POS templates, seed entries, conservative activation,
  candidate-prior repair, and a small unknown fallback.
- Add WordNet inventory, POS enrichment, and candidate-building Python tools.
- Record candidate metrics and learned-category source/provenance; grammar
  serialization is now version 2 with version 1 read compatibility.
- Add `--candidate-lexicon` training support and `inspect-candidates`.
- Add bounded CCGbank-inspired candidates for commas, sentence-final question
  and exclamation marks, and numbers, including PTB/UPOS aliases and a narrow
  no-POS token-shape fallback.
- Implement configuration-gated crossed and degree-two-or-greater generalized
  Composition, including crossed generalized variants, with category-bound
  checks and strictly left-to-right adjacent stack reduction.
