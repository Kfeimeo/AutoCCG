# Changelog

## Unreleased

- `evaluate` and `parse` accept `--config`; without it they use the training
  `config.snapshot.yaml` next to the grammar, falling back to built-in
  defaults, and report the choice on stderr. `inspect-candidates` accepts
  `--config` for atoms and category bounds. Previously all three always used
  the built-in defaults, so grammars trained with Composition, ASP, or wider
  bounds were evaluated under different rules.
- Every configuration lists `max_composition_degree`, the coordination and
  absorption switches, and `allow_argument_swap` explicitly.
- Add ASP, the argument-swap rule `(X\A)/B <=> (X/B)\A`, gated by
  `rules.allow_argument_swap` (off by default, on in `configs/default.yaml`
  and `configs/untruncated.yaml`). It applies at every parser level to any
  constituent at most once, is depth-bounded, and is counted in the new
  `ParseCost.argumentSwapUses`. The usefulness filter and right-context chart
  include it.
- Replace the default `pos_mapping` with lightblue's English lexicon
  (`fromNLTKtoCCG`): lightblue categories at prior 0, conventional
  CCGbank-style supplements at prior 1 or more, and conventional rules only for
  tags lightblue does not map. Seeds for `a`, `in`, and punctuation follow it.
- Add lightblue's non-combinatory rules for the new `CONJ`, `PERIOD`, and
  `PUNCT` atoms: coordination `X CONJ X => X`, `S PERIOD => S`, and
  `X PUNCT => X` for non-nominal X, gated by `rules.allow_coordination`,
  `rules.allow_period_absorption`, and `rules.allow_punctuation_absorption`.
  The parser now takes `GrammarRules` (Type-raising templates plus the reserved
  categories, see `Grammar.Types.grammarRules`) instead of a template list.
- `pos_mapping` rules accept an optional `words` restriction for lightblue's
  `(word, POS)` patterns; `resolvePosTemplates` now takes the word.
- Make the Composition usefulness filter sound. A Composition result is kept if
  it combines with its left stack neighbour, with any category derivable from
  the remaining input, or is the complete root. The right-context chart now
  uses every reduction of the current level instead of Application only.
  Previously, results consumed by a left neighbour or produced at the end of a
  sentence were discarded, so for example object relatives
  (`(N\N)/(S/NP)` with a type-raised subject) never parsed.
- Allow constituents derived by Application or Composition, such as `the man`,
  to be type-raised; fused Type-raising results remain non-raisable.
  `StackItem.itemTypeRaisingPosition` is replaced by `itemRaisable`.
- Thread the category store through all parser reductions.
  `compositionResults` now returns the threaded store. Previously, Composition
  results outside the pre-interned category universe received identifiers
  absent from the store, so they could not combine further and distinct results
  could share an identifier.
- Add `Parser.Incremental.pairReductions`, shared by the parser and the
  right-context chart.
- Bound generalized Composition by `rules.max_composition_degree` (default
  `2`), so enabling it yields exactly second-order Composition (B2>, B2<, and
  the crossed B2x>, B2x< when crossed Composition is enabled). Previously the
  degree was limited only by category bounds. `configs/default.yaml` and
  `configs/untruncated.yaml` set the degree to 2 explicitly.
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
