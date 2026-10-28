# AGENTS.md

## Project

**Name:** `ccg-induction`

**Goal:** Build a research-grade, interpretable CCG lexical category induction system with a Haskell core and Python tooling.

The system must learn a compact CCG lexicon from tokenized corpora under a finite hypothesis space, while requiring each accepted sentence to admit at least one derivation with root category `S`.

The implementation must prefer:

1. pure Application;
2. limited Composition;
3. limited Type-raising;
4. minimal lexical repair;
5. minimal grammar expansion.

The project is not a wrapper around an existing CCG parser. Core grammar induction and parsing logic must be implemented in this repository.

---

## Language and ownership boundaries

### Haskell owns

- category representation;
- category interning;
- combinators;
- parser states;
- left-to-right beam parsing;
- grammar-level beam search;
- failure-frontier analysis;
- repair candidate generation;
- lexicon induction;
- grammar compression;
- serialization of grammars and derivations;
- training and evaluation CLI;
- core metrics;
- unit tests, property tests, and benchmarks.

### Python owns

- corpus preprocessing;
- corpus format conversion;
- POS, lemma, and morphology enrichment;
- corpus filtering and splitting;
- experiment aggregation;
- plotting;
- notebooks;
- optional external NLP model integration.

Python must not implement the core parser, grammar beam, lexical repair search, or induction algorithm.

The default interface between Haskell and Python is JSONL/CSV/files/CLI. Do not introduce FFI unless the repository explicitly adopts it later.

---

## Supported toolchain

Use:

- GHC 9.12.x or a compatible stable compiler;
- Cabal;
- Haskell2021 or GHC2024;
- Python 3.12+ for auxiliary scripts.

Do not change the compiler family, build system, or language split without updating this file and the README.

---

## Repository layout

Keep the repository close to this structure:

```text
ccg-induction/
├── AGENTS.md
├── README.md
├── LICENSE
├── CHANGELOG.md
├── cabal.project
├── ccg-induction.cabal
├── app/
│   └── Main.hs
├── src/
│   ├── CCG/
│   │   ├── Atom.hs
│   │   ├── Category.hs
│   │   ├── CategoryStore.hs
│   │   ├── Combinator.hs
│   │   ├── TypeRaising.hs
│   │   └── Derivation.hs
│   ├── Corpus/
│   │   ├── Types.hs
│   │   ├── Jsonl.hs
│   │   └── PlainText.hs
│   ├── Evaluation/
│   │   ├── Coverage.hs
│   │   ├── Ambiguity.hs
│   │   ├── Gold.hs
│   │   └── Export.hs
│   ├── Grammar/
│   │   ├── Types.hs
│   │   ├── Cost.hs
│   │   ├── Beam.hs
│   │   └── Induction.hs
│   ├── Lexicon/
│   │   ├── Types.hs
│   │   ├── Initialization.hs
│   │   ├── Candidate.hs
│   │   ├── Repair.hs
│   │   └── Compression.hs
│   ├── Parser/
│   │   ├── Config.hs
│   │   ├── State.hs
│   │   ├── Beam.hs
│   │   ├── Incremental.hs
│   │   ├── FailureFrontier.hs
│   │   └── ParseCount.hs
│   ├── Serialization/
│   │   ├── Grammar.hs
│   │   ├── Lexicon.hs
│   │   └── Derivation.hs
│   └── CLI.hs
├── test/
│   ├── CategorySpec.hs
│   ├── CombinatorSpec.hs
│   ├── ParserSpec.hs
│   ├── RepairSpec.hs
│   ├── CompressionSpec.hs
│   └── PropertySpec.hs
├── bench/
│   ├── ParserBench.hs
│   └── RepairBench.hs
├── configs/
│   ├── toy.yaml
│   └── default.yaml
├── examples/
│   ├── toy.jsonl
│   └── toy-test.jsonl
├── python_tools/
│   ├── preprocess_ptb.py
│   ├── preprocess_ccgbank.py
│   ├── preprocess_conllu.py
│   ├── filter_corpus.py
│   ├── split_corpus.py
│   ├── corpus_stats.py
│   ├── evaluate_results.py
│   ├── plot_metrics.py
│   └── notebooks/
├── scripts/
│   ├── format.sh
│   ├── lint.sh
│   ├── test.sh
│   └── bench.sh
└── runs/
    └── .gitkeep
```

Do not place unrelated modules at repository root.

---

## Core domain invariants

### Root category

`S` is predefined and must exist in the atom table before training begins.

### Finite hypothesis space

The configuration must bound:

- atomic category count;
- category depth;
- slash count;
- argument arity;
- allowed category templates;
- Type-raising templates;
- Composition kinds;
- parser beam width;
- grammar beam width;
- maximum repair width.

No operation may silently escape these bounds.

### Default single category per word

A word type should initially receive at most one category.

An additional category may be added only when:

1. no complete Application-only derivation to `S` exists;
2. no complete derivation with allowed Composition exists;
3. no complete derivation with allowed Type-raising exists;
4. a lexical repair is required.

### Token types, not token instances

Lexical categories belong to word types or normalized lexical entries, not individual token occurrences.

Do not create token-local categories to force coverage.

### No sentence-private atoms

Do not generate private atomic categories for individual sentences.

### Determinism

Given the same corpus, configuration, random seed, and runtime mode, the system must produce the same candidate ordering, selected grammar, and serialized output.

Any parallel execution must preserve deterministic ordering.

---

## Core category representation

Use integer IDs internally.

```haskell
newtype AtomId = AtomId Int
  deriving newtype (Eq, Ord, Show, Hashable, ToJSON, FromJSON)

newtype CategoryId = CategoryId Int
  deriving newtype (Eq, Ord, Show, Hashable, ToJSON, FromJSON)

data Slash
  = ForwardSlash
  | BackwardSlash
  deriving stock (Eq, Ord, Show, Generic)

data CategoryNode
  = Atomic !AtomId
  | Functional !Slash !CategoryId !CategoryId
  deriving stock (Eq, Ord, Show, Generic)
```

Interpretation:

```text
Functional ForwardSlash result argument  = result / argument
Functional BackwardSlash result argument = result \ argument
```

All categories must be interned through `CategoryStore`.

Structurally equal categories must share one `CategoryId`.

Do not use raw `Text` or `String` as the canonical in-memory category representation.

---

## Parsing policy

Parsing is left-to-right and incremental, but not a single irreversible left fold.

Use a beam-stack or shift-reduce parser that can retain multiple candidate states.

Exception: `parser.algorithm: eisner` selects an exhaustive CKY chart parser
with Eisner (1996) normal-form constraints over Application and Composition
only (`Parser.Eisner`). It exists to enumerate every semantic reading without
spurious ambiguity; it must stay deterministic, bounded by the category bounds
and `parse_count_cap`, and must report the same failure frontier shape as the
shift-reduce parser. The rule levels below apply to the shift-reduce parser.

### Rule levels

#### Level 0: Application only

Allow only:

```text
X/Y  Y    => X
Y    X\Y  => X
```

A failure at this level means no complete Application-only derivation to `S` exists. It does not mean one greedy path became locally stuck.

#### Level 1: Composition fallback

Only after Level 0 fails, allow first-order harmonic Composition:

```text
X/Y  Y/Z  => X/Z
Y\Z  X\Y  => X\Z
```

Do not add crossed Composition or generalized Composition unless a later design document explicitly permits it.

#### Level 2: Type-raising fallback

Only after Levels 0 and 1 fail, allow configured Type-raising templates, for example:

```text
NP => S/(S\NP)
NP => S\(S/NP)
```

Constraints:

- each token occurrence may be raised at most once;
- repeated raising is forbidden;
- raised categories must be consumed by Composition within a configured number of steps;
- expired raised states must be pruned;
- Type-raising is a derivational operation, not automatically a permanent lexical entry.

#### Level 3: Lexical repair

Only after all parser rule levels fail, generate lexical repairs.

Repair priority:

1. add one category to one word;
2. replace one likely-wrong category;
3. jointly modify two words;
4. enable one still-allowed atom;
5. mark unresolved.

Do not jump directly to multiword repair when a valid one-word repair exists.

---

## Parser state

Prefer a strict state representation:

```haskell
data ParseState = ParseState
  { inputPosition  :: !Int
  , categoryStack :: !(SmallArray CategoryId)
  , pendingRaised :: !(IntMap RaisedConstraint)
  , derivationRef :: !DerivationRef
  , parseCost     :: !ParseCost
  }
```

Parser state equality and deduplication must be based on semantic state:

```text
input position
normalized category stack
pending raised constraints
active parser level
```

When two states are semantically identical, retain the lower-cost state and aggregate bounded parse counts if required.

Do not copy complete derivation trees into every state. Use an arena, DAG, or parent references.

---

## Cost model

Use lexicographic ordering.

```haskell
data Cost = Cost
  { unresolvedSentenceCount :: !Int
  , lexicalRepairCount      :: !Int
  , extraCategoryCount      :: !Int
  , typeRaisingCount        :: !Int
  , compositionCount        :: !Int
  , categoryComplexity      :: !Int
  , ambiguityPenalty        :: !Int
  , lexiconSize             :: !Int
  , specialCategoryPenalty  :: !Int
  , derivationStepCount     :: !Int
  }
  deriving stock (Eq, Ord, Show, Generic)
```

Do not collapse this into a single weighted floating-point score unless explicitly requested for an experiment.

Tie-breaking must be stable and deterministic.

---

## Lexical repair scoring

When several repairs make the current sentence parse to `S`, prefer the repair that expands the global hypothesis space least.

Preferred exact quantity:

```text
DeltaParseSpace(w, C)
  = sum over prior corpus sentences containing w:
      parseCountAfter - parseCountBefore
```

A permitted approximation is:

```text
ApproxDelta(w, C)
  = occurrenceCount(w)
    * compatibilityCount(C, lexicon)
    * categoryGenerality(C)
```

Repair scoring must remain modular.

A repair is invalid if it does not participate in at least one complete derivation of the current sentence to `S`.

A repair should be rejected if it breaks previously accepted sentences, unless the current operation is an explicit global grammar revision with rollback support.

---

## Failure-frontier requirements

A failed parse should return structured diagnostic information, not only `False`.

```haskell
data ParseFailure = ParseFailure
  { farthestPosition     :: !Int
  , survivingStates     :: !(Vector ParseStateSummary)
  , blockingPairs       :: !(Vector BlockingPair)
  , expectedCategories  :: !(HashSet CategoryId)
  , rightContextSummary :: !RightContextSummary
  }
```

Use the failure frontier to derive candidate categories by rule inversion.

Do not enumerate the entire category universe unless the bounded inverse search fails.

---

## Grammar-level beam

The induction algorithm must maintain multiple grammar candidates when configured.

```haskell
data GrammarCandidate = GrammarCandidate
  { grammar                :: !Grammar
  , grammarCost            :: !Cost
  , processedSentenceCount :: !Int
  , grammarHistoryRef      :: !GrammarHistoryRef
  }

newtype GrammarBeam =
  GrammarBeam (Vector GrammarCandidate)
```

For each sentence:

1. parse with each grammar candidate;
2. preserve successful grammars;
3. expand failed grammars with minimal repairs;
4. deduplicate equivalent grammars;
5. sort by lexicographic cost;
6. retain at most `grammarBeamWidth`.

Equivalent grammars must serialize identically after normalization.

---

## Global compression

After a configurable number of sentences or after each epoch, run grammar compression.

Compression may:

- remove unused lexical categories;
- remove categories absent from all preferred derivations;
- merge equivalent entries;
- replace over-specialized categories;
- reduce Composition use;
- reduce Type-raising use;
- reduce parse ambiguity;
- revise early lexical decisions.

Compression must not reduce required training coverage unless the configuration explicitly allows temporary unresolved sentences.

Every destructive compression step must support rollback.

## Candidate lexicon constraints

The candidate prior layer and active learned lexicon are distinct:

```text
CandidateLexicon: word -> bounded prior-ranked candidate categories
LearnedLexicon:   word -> parser-visible accepted categories
```

The parser must read only `LearnedLexicon`. `CandidateLexicon` may be used by
initialization and lexical repair only. Locked seed entries and conservatively
configured single candidates may be activated initially; other candidates may
enter the learned lexicon only after all parser rule levels fail and a complete
temporary-grammar parse to `S` validates the repair.

POS is token-level evidence when present. WordNet supplies lemma-level possible
POS values only when token POS is absent; it is never treated as a token tagger
or gold CCG supervision. If POS, WordNet, and seeds provide no usable candidate,
an enabled fallback must use a small configured template set and must not
enumerate the complete category universe.

Candidate category strings must be parsed and interned at the Haskell boundary.
Candidates that introduce unconfigured atoms or exceed category depth, slash,
arity, or per-word count bounds must be rejected with an explicit diagnostic.
Candidate ordering is lexicographic and deterministic, beginning with added
category count and prior cost. Every accepted category must retain its source,
prior, acceptance sentence when applicable, and repair reason.

---

## Configuration

All operational limits belong in YAML configuration.

```yaml
atoms:
  predefined: [S, NP, N, PP]
  max_count: 8

categories:
  max_depth: 5
  max_slashes: 4
  max_arity: 3

parser:
  beam_width: 128
  max_stack_depth: 12
  max_states_per_position: 2048
  max_reductions_per_shift: 8
  parse_count_cap: 10000
  max_steps_before_raised_category_consumed: 2

grammar:
  beam_width: 16
  max_repairs_per_failure: 32
  max_joint_repair_width: 2

rules:
  allow_forward_application: true
  allow_backward_application: true
  allow_forward_composition: true
  allow_backward_composition: true
  allow_crossed_composition: false
  allow_generalized_composition: false

training:
  seed: 42
  compression_interval: 100
  unresolved_policy: queue
```

Do not hardcode experiment parameters in source modules.

---

## Input and output formats

### Input JSONL

```json
{
  "sentence_id": "wsj_0001",
  "tokens": ["John", "likes", "Mary"],
  "lemmas": ["John", "like", "Mary"],
  "pos": ["NNP", "VBZ", "NNP"],
  "morph": [{}, {}, {}],
  "metadata": {
    "source": "CCGbank",
    "split": "train"
  }
}
```

Only `sentence_id` and `tokens` are mandatory unless configuration says otherwise.

### Output

Training output directory:

```text
grammar.json
lexicon.json
training_metrics.jsonl
unresolved.jsonl
config.snapshot.yaml
derivations/
```

Evaluation output:

```text
evaluation.json
sentence_results.jsonl
category_inventory.csv
ambiguity.csv
```

All serialized output must be versioned.

---

## CLI contract

These commands must remain supported:

```bash
cabal run ccg-induction -- train \
  --corpus examples/toy.jsonl \
  --config configs/toy.yaml \
  --candidate-lexicon examples/toy-candidates.json \
  --output runs/toy
```

```bash
cabal run ccg-induction -- evaluate \
  --corpus examples/toy-test.jsonl \
  --grammar runs/toy/grammar.json \
  --output runs/toy/eval
```

```bash
cabal run ccg-induction -- parse \
  --grammar runs/toy/grammar.json \
  --sentence "John likes Mary"
```

```bash
cabal run ccg-induction -- inspect-lexicon \
  --grammar runs/toy/grammar.json \
  --word "likes"
```

```bash
cabal run ccg-induction -- inspect-candidates \
  --candidate-lexicon examples/toy-candidates.json \
  --word "likes"
```

Python preprocessing example:

```bash
python python_tools/preprocess_conllu.py \
  --input data/input.conllu \
  --output data/output.jsonl
```

Do not break CLI behavior without updating tests and README.

---

## Coding standards

### Haskell

- Use explicit module export lists.
- Prefer total functions.
- Avoid `head`, `tail`, `fromJust`, and unchecked indexing.
- Use strict fields for search-state data.
- Prefer `Text` over `String`.
- Use `IntMap`, `IntSet`, `Vector`, `SmallArray`, or hash maps where appropriate.
- Keep effects at the boundary.
- Keep combinator logic pure.
- Keep serialization separate from core semantics.
- Avoid overengineering with GADTs or type-level machinery in the first implementation.
- Add comments for invariants and non-obvious pruning logic.
- Do not hide asymptotically expensive operations behind innocent names.
- Use stable sorting when tie order matters.

### Python

- Python 3.12+.
- Type hints required.
- Use `pathlib`.
- Prefer pure transformation functions.
- Keep corpus readers streaming where possible.
- Do not duplicate Haskell domain logic.
- Add CLI entry points with `argparse` or `typer`.
- Use deterministic random seeds.
- Do not commit notebooks with large outputs.

---

## Performance standards

Use strict containers and strict evaluation where appropriate.

Required optimizations:

- category interning;
- integer IDs for words, atoms, and categories;
- combinator-result memoization;
- parser-state deduplication;
- prefix parse caching;
- lexicon version in cache keys;
- bounded parse counting;
- derivation arena/DAG;
- strict evaluation before retaining beam states.

Do not add parallelism before deterministic single-threaded correctness is established.

---

## Testing requirements

Every feature change must include tests.

### Unit tests

At minimum, test:

```text
(S/NP) + NP => S
NP + (S\NP) => S
(X/Y) + (Y/Z) => X/Z
```

Also test invalid combinations.

### Parser-level tests

Create cases requiring:

1. Application only;
2. Composition fallback;
3. Type-raising plus Composition;
4. lexical repair.

Verify that a higher rule level is not used when a lower level already yields a complete `S` derivation.

### Type-raising tests

Verify:

- only configured templates are allowed;
- a token is raised at most once;
- repeated raising is rejected;
- expired raised categories are pruned;
- Type-raising is not used in an Application-only solution.

### Repair tests

When several repairs work, verify preference for:

- fewer new categories;
- smaller parse-space expansion;
- simpler categories;
- fewer affected old sentences;
- greater reuse of existing templates.

### Grammar beam tests

Verify:

- alternative grammar hypotheses are retained;
- equal grammars deduplicate;
- beam order is deterministic;
- stable tie-breaking;
- compression preserves coverage.

### Property tests

Use QuickCheck for:

- category pretty-print/parse roundtrip;
- interning idempotence;
- combinator structural correctness;
- parser-state deduplication;
- lexicon extension monotonicity;
- grammar compression coverage preservation.

### Benchmarks

Maintain benchmarks for:

- category interning;
- Application-only parsing;
- Composition parsing;
- repair candidate generation;
- grammar beam expansion;
- compression.

---

## Required commands before completion

Run:

```bash
cabal build all
cabal test all
cabal run ccg-induction -- parse \
  --grammar examples/toy-grammar.json \
  --sentence "John likes Mary"
```

When benchmark code changes:

```bash
cabal bench
```

For Python changes:

```bash
python -m compileall python_tools
```

If lint or formatting scripts exist, run them before finalizing.

Do not claim completion if the project does not compile or tests fail.

---

## Implementation order

Follow this order unless a dependency requires otherwise:

1. repository and Cabal skeleton;
2. atom and category types;
3. category parser/pretty-printer;
4. category interning;
5. Application combinators;
6. parser state and beam;
7. Application-only parser;
8. Composition fallback;
9. Type-raising fallback;
10. derivation arena;
11. failure frontier;
12. inverse candidate generation;
13. lexical repair;
14. grammar-level beam;
15. global compression;
16. JSONL corpus interface;
17. CLI;
18. Python preprocessing tools;
19. evaluation metrics;
20. benchmarks and documentation.

Keep the repository buildable after each milestone.

---

## Completion criteria

A milestone is complete only when:

- code compiles;
- tests pass;
- public types and invariants are documented;
- new configuration fields are documented;
- CLI behavior is covered by at least one integration test;
- serialization changes are versioned;
- performance-sensitive code has no obvious accidental quadratic behavior;
- deterministic output is preserved.

---

## Prohibited shortcuts

Do not:

- represent core categories as unchecked strings;
- create sentence-private atoms;
- create token-local lexical categories;
- silently exceed configured category bounds;
- enable unlimited Type-raising;
- enable unlimited generalized Composition;
- use a single irreversible greedy parse path;
- interpret local failure as proof of global Application failure;
- mutate one global grammar without beam alternatives or revision support;
- copy complete derivation trees into parser states;
- report only training coverage;
- call an existing CCG parser and present its output as induced grammar;
- train on hidden CCGbank gold categories;
- move core induction logic into Python;
- introduce non-deterministic parallel ranking;
- overuse advanced Haskell type machinery before the baseline system works.

---

## Agent behavior

When working in this repository:

1. inspect existing modules and tests before editing;
2. preserve public interfaces unless the task requires a change;
3. make the smallest coherent change;
4. add or update tests with every semantic change;
5. keep domain logic pure;
6. explain any deviation from this architecture in the final summary;
7. do not leave dead code, placeholders, fake implementations, or unbounded TODOs;
8. do not weaken invariants merely to make one test pass;
9. prefer explicit failure values over exceptions in core logic;
10. keep the project runnable at the end of the task.

When uncertain, prioritize correctness, bounded search, determinism, and interpretability over premature optimization.
