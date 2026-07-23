# Changelog

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
