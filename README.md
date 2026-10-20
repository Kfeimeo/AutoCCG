# ccg-induction

`ccg-induction` is a research-oriented system for inducing compact,
interpretable Combinatory Categorial Grammar (CCG) lexical categories from
tokenized corpora.

The core parser, category representation, grammar search, lexical repair, and
serialization live in Haskell. Python is reserved for corpus preparation,
format conversion, experiment aggregation, and plotting.

This repository is intentionally not a wrapper around an existing CCG parser.
The grammar induction and bounded parsing logic are implemented here.

## Goals

- Learn a compact lexicon over word types, not token instances.
- Require accepted sentences to admit at least one derivation rooted at `S`.
- Prefer simple derivations before expanding the grammar:
  1. Application
  2. limited harmonic Composition
  3. limited Type-raising
  4. lexical repair
  5. grammar compression
- Keep search finite, deterministic, and interpretable.
- Serialize grammars, lexicons, metrics, and derivation summaries in stable
  file formats.

## Project Status

The repository currently contains the Haskell baseline for the core induction
pipeline:

- integer-backed atoms and categories;
- category interning and pretty-print/parse support;
- Application and first-order harmonic Composition;
- bounded Type-raising templates;
- beam-style incremental parsing;
- structured parse failures;
- grammar candidates and lexicographic costs;
- lexical repair and compression passes;
- a separate POS/WordNet/seed CandidateLexicon with bounded prior-ranked repair;
- JSONL corpus loading;
- grammar serialization;
- CLI commands for training, evaluation, parsing, learned-lexicon inspection,
  and candidate inspection;
- unit/property test and benchmark scaffolding.

The project is still young. Treat the implementation as a bounded baseline for
experimentation rather than a finished CCGbank-scale learner.

## Repository Layout

```text
.
+-- app/                    # executable entry point
+-- src/
|   +-- CCG/                # atoms, categories, combinators, derivations
|   +-- Corpus/             # JSONL and plain-text corpus IO
|   +-- Evaluation/         # coverage, ambiguity, exports, gold comparison
|   +-- Grammar/            # grammar types, costs, beam, induction loop
|   +-- Lexicon/            # initialization, repair, compression
|   +-- Parser/             # config, states, beam parser, failures, counts
|   +-- Serialization/      # grammar, lexicon, candidate lexicon, derivation formats
|   +-- CLI.hs              # command-line interface
+-- test/                   # unit and property tests
+-- bench/                  # Criterion benchmarks
+-- AGENTS.md               # engineering and research constraints
+-- ccg-induction.cabal
```

The target full layout also includes `configs/`, `examples/`, `python_tools/`,
`scripts/`, and `runs/` as described in `AGENTS.md`.

## Requirements

- GHC 9.12 or a compatible stable compiler
- Cabal
- Python 3.12+ for auxiliary tooling

The current Cabal file uses `GHC2024`.

## Build

Commands are shown for bash (Linux/macOS). Single-line commands run
unchanged in Windows PowerShell. Each multi-line command is followed by a
PowerShell equivalent, which continues lines with a backtick (`` ` ``)
instead of `\`.

```bash
cabal build all
```

Run tests:

```bash
cabal test all
```

Run benchmarks:

```bash
cabal bench
```

## CLI

The executable is named `ccg-induction`.

Train a grammar from JSONL:

```bash
cabal run ccg-induction -- train \
  --corpus examples/toy.jsonl \
  --config configs/toy.yaml \
  --candidate-lexicon examples/toy-candidates.json \
  --output runs/toy \
  --jobs 4
```

PowerShell equivalent:

```powershell
cabal run ccg-induction -- train `
  --corpus examples/toy.jsonl `
  --config configs/toy.yaml `
  --candidate-lexicon examples/toy-candidates.json `
  --output runs/toy `
  --jobs 4
```

Evaluate a frozen grammar:

```bash
cabal run ccg-induction -- evaluate \
  --corpus examples/toy-test.jsonl \
  --grammar runs/toy/grammar.json \
  --output runs/toy/eval \
  --jobs 4
```

PowerShell equivalent:

```powershell
cabal run ccg-induction -- evaluate `
  --corpus examples/toy-test.jsonl `
  --grammar runs/toy/grammar.json `
  --output runs/toy/eval `
  --jobs 4
```

`--jobs` defaults to `1`. Training parallelizes independent grammar-beam and
lexical-repair candidate parses; sentences remain sequential because each one
updates the learned lexicon. Evaluation parallelizes sentences. Candidate
ordering and serialized results remain deterministic across job counts.
The `train` command displays a single-line progress bar with processed,
covered, unresolved, and sentences-per-second counts. Pass `--no-progress`
when redirecting output or running unattended batch jobs. For every unresolved
sentence, progress output also reports categorized token and distinct word-type
counts/rates, the total number of lexical category assignments, the farthest
parser position, and uncategorized words.

Parse a tokenized sentence:

```bash
cabal run ccg-induction -- parse \
  --grammar runs/toy/grammar.json \
  --sentence "John likes Mary"
```

PowerShell equivalent:

```powershell
cabal run ccg-induction -- parse `
  --grammar runs/toy/grammar.json `
  --sentence "John likes Mary"
```

Inspect categories assigned to one word type:

```bash
cabal run ccg-induction -- inspect-lexicon \
  --grammar runs/toy/grammar.json \
  --word "likes"
```

PowerShell equivalent:

```powershell
cabal run ccg-induction -- inspect-lexicon `
  --grammar runs/toy/grammar.json `
  --word "likes"
```

Inspect prior candidates without activating them in the parser:

```bash
cabal run ccg-induction -- inspect-candidates \
  --candidate-lexicon examples/toy-candidates.json \
  --word likes
```

PowerShell equivalent:

```powershell
cabal run ccg-induction -- inspect-candidates `
  --candidate-lexicon examples/toy-candidates.json `
  --word likes
```

Build a candidate lexicon JSON from corpus POS, the configured `pos_mapping`,
an optional WordNet inventory, and seeds:

```bash
cabal run ccg-induction -- build-candidates \
  --corpus data/processed/train-pos.jsonl \
  --config configs/default.yaml \
  --wordnet data/processed/wordnet_inventory.json \
  --output data/processed/candidate_lexicon.json
```

PowerShell equivalent:

```powershell
cabal run ccg-induction -- build-candidates `
  --corpus data/processed/train-pos.jsonl `
  --config configs/default.yaml `
  --wordnet data/processed/wordnet_inventory.json `
  --output data/processed/candidate_lexicon.json
```

## Input Format

Training and evaluation corpora use JSONL: one sentence object per line.
Only `sentence_id` and `tokens` are required by the baseline loader.

```json
{
  "sentence_id": "toy_0001",
  "tokens": ["John", "likes", "Mary"],
  "lemmas": ["John", "like", "Mary"],
  "pos": ["NNP", "VBZ", "NNP"],
  "morph": [{}, {}, {}],
  "metadata": {
    "source": "toy",
    "split": "train"
  }
}
```

Lexical categories are assigned to normalized word types. The parser must not
create sentence-private atoms or token-local categories to force coverage.

## Configuration

Operational limits belong in YAML configuration. The bounded atom inventory is
declared with `atoms.predefined` and `atoms.max_count`; `S` must always be
listed. Fields not present in a config
file fall back to the Haskell defaults.

```yaml
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
  max_composition_degree: 2
  allow_coordination: true
  allow_period_absorption: true
  allow_punctuation_absorption: true

training:
  seed: 42
  compression_interval: 100
  unresolved_policy: queue
```

The built-in atom table contains `S`, `NP`, `N`, and `PP`; configurations may
predeclare additional bounded atoms such as `AP`. Candidate constraints,
POS templates, seed entries, initialization policy, and bounded repair policy
are documented in [`configs/default.yaml`](configs/default.yaml). Candidate
categories introducing unconfigured atoms or exceeding depth, slash, or arity
bounds are rejected during loading.

Crossed and generalized Composition are independently gated by
`rules.allow_crossed_composition` and
`rules.allow_generalized_composition`. Generalized rules operate on a uniform
slash spine of degree two up to `rules.max_composition_degree` (default `2`,
must be at least `1`); generalized crossed rules require both flags. With the
default degree, generalized Composition is exactly second-order Composition:

```text
B2>   X/Y  (Y/Z)/W  => (X/Z)/W
B2<   (Y\Z)\W  X\Y  => (X\Z)\W
B2x>  X/Y  (Y\Z)\W  => (X\Z)\W        (also needs allow_crossed_composition)
B2x<  (Y/Z)/W  X\Y  => (X/Z)/W        (also needs allow_crossed_composition)
```

Setting the degree to `1` disables generalized Composition; higher values admit
B^n up to that degree, still subject to the category bounds. Every generated result is checked against the configured category
depth, slash-count, and arity bounds. Parsing remains strictly left-to-right:
the parser shifts tokens in corpus order and only reduces the two adjacent
constituents at the top of the stack.

For diagnostic exhaustive-capacity runs, `configs/untruncated.yaml` raises all
parser, grammar-beam, candidate-generation, and repair-validation capacities
above any practically materializable in-memory search. It deliberately keeps
the finite category, rule, and template bounds. This configuration can require
extreme time and memory and should normally be tested on a small corpus first.

## Output

Training writes:

```text
grammar.json
lexicon.json
training_metrics.jsonl
candidate_metrics.json
learned_category_sources.jsonl
unresolved.jsonl
config.snapshot.yaml
candidate_lexicon.snapshot.json   # when a candidate JSON file is used
derivations/
```

Evaluation writes:

```text
evaluation.json
sentence_results.jsonl
category_inventory.csv
ambiguity.csv
```

`evaluate` prints one diagnostic line per sentence. Its
`sentence_results.jsonl` contains sentence coverage plus categorized-token and
categorized-word-type coverage, uncategorized words, the farthest position
reached on failure, and human-readable category stacks retained at the failure
frontier. The `parse` command prints the same diagnostic fields when a sentence
cannot reach root `S`.

Serialized grammars are versioned. The current grammar format is version `2`
and stores the word-to-category lexicon plus candidate source, prior cost,
acceptance sentence, and repair reason. Version 1 grammars remain readable.

## Architecture

### Categories

Atoms and categories use integer IDs internally. All category nodes are interned
through `CategoryStore`, so structurally equal categories share one
`CategoryId`.

```haskell
data CategoryNode
  = Atomic !AtomId
  | Functional !Slash !CategoryId !CategoryId
```

`Functional ForwardSlash result argument` means `result / argument`.
`Functional BackwardSlash result argument` means `result \ argument`.

### Parser

Parsing is left-to-right and beam-based, not a single irreversible greedy fold.
The parser attempts rule levels in order:

1. Application only
2. Application plus first-order harmonic Composition
3. configured Type-raising plus Composition

Lexical repair is triggered only after parser-level fallbacks fail. Type-raising
is a local fused operation: it is generated only when an adjacent category can
immediately combine with the raised category by an enabled Composition rule. A
raised category is never inserted into or retained by the beam. Lexical items
and constituents derived by Application or Composition (for example the NP
`the man`) may be raised; a fused Type-raising result may not, so no
constituent is raised twice.

Composition is generated only when the adjacent pair has no enabled Application
reduction. A Composition result is kept only if it can still take part in a
derivation: it combines with the constituent directly below it on the stack,
or with some category derivable from a prefix of the remaining input, or it is
already the complete root. The right-context test uses a deterministic
`rightReachableCategories` chart built with every reduction of the current
level (Application, enabled Composition, and fused Type-raising) and no beam
limits, so it over-approximates what the beam can build and never discards a
derivable state. The chart is cubic in sentence length and is computed once per
Composition or Type-raising level.

With beam and state capacities that never truncate (for example
`configs/untruncated.yaml`), the parser therefore finds a derivation to `S`
whenever one exists under the enabled rules and category bounds. It still
returns only the cheapest derivation at the lowest successful level, and
Application blocks Composition on the same adjacent pair.

### Grammar Search

Grammar candidates carry lexicographic costs:

- unresolved sentences
- lexical repairs
- extra categories
- Type-raising
- Composition
- category complexity
- ambiguity
- lexicon size
- special category penalties
- derivation steps

Candidates are normalized, deduplicated, sorted deterministically, and clipped
to the configured grammar beam width.

### Repair and Compression

Repair candidates are scored by how little they expand the global hypothesis
space while still participating in at least one complete derivation for the
current sentence. Compression tries to remove redundant lexical categories while
preserving required coverage, with rollback for destructive changes.

### Candidate constraints

`CandidateLexicon` and the active learned `Lexicon` are deliberately separate:

```text
POS / WordNet lemma POS / seed files
  -> bounded CandidateLexicon with prior costs
  -> conservative initial activation
  -> parser reads LearnedLexicon only
  -> all parser levels fail
  -> validate top-k candidate repairs
  -> small fixed unknown fallback if configured
```

Locked seeds may be activated initially. Unlocked seed entries always remain
priors until repair. Single non-seed candidates may be activated according to
the initialization configuration. Multi-candidate words remain inactive unless
`activate_best_candidate_per_word` is explicitly enabled. Every repaired
category is inserted into a temporary grammar and must parse the complete
sentence to `S`; POS and WordNet never bypass parser validation.

The default candidate configuration includes CCGbank-inspired, bounded
punctuation approximations. Sentence-final `.`, `!`, and `?` use `S\S`;
commas additionally offer `(S\S)/S`, `NP\NP`, and `N\N` for validated
clause linking and constituent-final attachment. CCGbank itself uses dedicated
punctuation leaves plus absorption and comma type-change rules; these lexical
categories are an Application-compatible approximation until those explicitly
bounded rules are implemented. Numbers use `N/N` first and `NP` as a fallback.
Penn Treebank `CD`, Universal POS `NUM`/`PUNCT`, and untagged numeric or common
punctuation token shapes are supported without treating the shape fallback as
a general POS tagger.

### POS-to-category mapping

The default `pos_mapping` reproduces the English lexicon of
[lightblue](https://github.com/DaisukeBekki/lightblue)
(`src/Parser/Language/English/Lexicon.hs`, `fromNLTKtoCCG`), which maps NLTK
Penn Treebank tags, and for some entries word forms, to one category each.
Features and semantics are dropped:

| lightblue pattern `(word, POS)` | category (prior 0) |
|---|---|
| `(_, NNP)`, `(_, PRP)` | `NP` |
| `("a"/"A", DT)` | `(S/(S\NP))/N` |
| `(_, DT)` | `NP/N` |
| `(_, NN)` | `N` |
| `(_, WP)` | `N/N` |
| `(_, NNS)`, `(_, VBN)`, `(_, VBD)` | `S\NP` |
| `(_, VBZ)` | `(S\NP)/NP` |
| `(_, IN)`, `(_, RB)` | `(S\NP)\(S\NP)` |
| `("and"/"or", CC)` | `CONJ` |
| `("Either", CC)` | `((S/S)/CONJ)/S` |
| `(_, ".")` | `PERIOD` |
| `(_, _)` for punctuation and symbol tags | `PUNCT` |

The lightblue category always has prior cost 0, so it is the one activated
initially. Where lightblue is unconventional or narrow (for example `NNS` as a
predicate, `IN` without an object, or `VBD` as intransitive only), the
conventional CCGbank-style categories are added as supplements with prior cost
1 or more; they enter the learned lexicon only through validated repair. Tags
lightblue does not map (`VB`, `VBP`, `VBG`, `JJ*`, `MD`, `TO`, `CD`, other `CC`
words, ...) use conventional rules instead of lightblue's catch-all `PUNCT`.
The seed lexicon follows lightblue for `a` and for punctuation.

`CONJ`, `PERIOD`, and `PUNCT` are atoms declared in `atoms.predefined` and are
combined by lightblue's non-combinatory rules, each gated in `rules`:

```text
allow_coordination             X  CONJ  X  => X   (the left X is not itself a coordination)
allow_period_absorption        S  PERIOD   => S
allow_punctuation_absorption   X  PUNCT    => X   (the final result of X is not N)
```

They belong to the Application level: they are available at every parser
level and block Composition on the same pair.

`pos_mapping` itself is generic: named `templates` selected by an ordered rule
cascade over POS tags, where the first match wins.

```yaml
pos_mapping:
  templates:
    lb_conjunction: [{category: "CONJ", prior_cost: 0}]
    lb_common_noun: [{category: "N", prior_cost: 0}]
    common_noun_supplement:
      - {category: "NP", prior_cost: 1}
      - {category: "N/N", prior_cost: 2}
  rules:
    - {tag: "CC", words: ["and", "or"], templates: [lb_conjunction]}
    - {tag: "NN", templates: [lb_common_noun, common_noun_supplement]}
    - {prefix: "JJ", categories: [{category: "N/N", prior_cost: 0}]}
```

Each rule matches with exactly one of `tag`, `tags`, or `prefix`, may be
restricted to exact, case-sensitive word forms with `words`, and yields its
named `templates` in order, followed by inline `categories`. Undefined
template names, ambiguous matchers, and empty `words` lists are rejected when
the configuration is loaded. Quote tags and categories in YAML: a bare `N` is
read as a boolean. The default configuration also maps the Universal POS tags
produced by spaCy and Stanza. The flat `pos_to_categories: {TAG: [...]}` table
is still accepted as shorthand for exact-tag rules tried after
`pos_mapping.rules`.

Per token, the tag driving the cascade is the corpus POS (UPOS `PUNCT` is
refined by token shape). Without POS, a closed-form token shape is used.
Otherwise, when `use_wordnet_inventory` is enabled and an inventory is given by
`candidate_constraints.wordnet_inventory_path` or `--wordnet`, every WordNet
POS of the lemma is used. When candidate constraints are disabled, legacy
initialization assigns the lowest-prior category of the matching rule.

When constraints are disabled, the legacy bounded-universe repair path remains
available for regression and performance comparisons. When enabled, unknown
fallback uses only a small fixed template inventory and never enumerates the
complete category universe.

The checked-in synthetic comparison can be reproduced with
`examples/constraint-benchmark.jsonl` and the two
`configs/constraint-benchmark*.yaml` configurations. A single Windows/GHC
9.14.1 validation run produced:

| Measurement | constrained | legacy unconstrained |
|---|---:|---:|
| repair candidates validated | 0 | 18 |
| heap bytes allocated (`+RTS -s`) | 2,785,832 | 17,054,904 |
| wall time including process startup | 504 ms | 602 ms |
| RTS total memory in use | 6 MiB | 6 MiB |

This tiny fixture demonstrates an 83.7% reduction in allocation and eliminates
full repair validation, but is too small for a meaningful peak-residency claim;
the runtime's 6 MiB floor dominates both runs. Use a representative corpus and
external peak-RSS sampling for research performance conclusions.

## Python Tooling Boundary

Python tooling should prepare data and aggregate experiments. It must not
duplicate the Haskell parser, grammar beam, lexical repair search, or induction
algorithm.

NLTK, WordNet, spaCy, and Stanza are explicit optional dependencies. The repository
does not auto-download NLP packages, corpora, or model files during preprocessing,
so install the pieces you want to use before running the scripts:

```bash
python -m pip install nltk spacy stanza pyyaml
python -m spacy download en_core_web_sm
python -c "import nltk; nltk.download('averaged_perceptron_tagger_eng'); nltk.download('wordnet'); nltk.download('omw-1.4')"
python -c "import stanza; stanza.download('en')"
```

For POS/lemma enrichment, start from a pretokenized JSONL corpus whose records
already contain `tokens`. The default backend is NLTK's averaged-perceptron
tagger, which writes Penn Treebank tags for the `pos_mapping` cascade and
WordNet lemmas:

```bash
python python_tools/enrich_with_pos.py \
  --input data/processed/train.jsonl \
  --output data/processed/train-pos.jsonl \
  --backend nltk
```

PowerShell equivalent:

```powershell
python python_tools/enrich_with_pos.py `
  --input data/processed/train.jsonl `
  --output data/processed/train-pos.jsonl `
  --backend nltk
```

Alternatively, use spaCy:

```bash
python python_tools/enrich_with_pos.py \
  --input data/processed/train.jsonl \
  --output data/processed/train-pos.jsonl \
  --backend spacy \
  --model en_core_web_sm
```

PowerShell equivalent:

```powershell
python python_tools/enrich_with_pos.py `
  --input data/processed/train.jsonl `
  --output data/processed/train-pos.jsonl `
  --backend spacy `
  --model en_core_web_sm
```

or Stanza:

```bash
python python_tools/enrich_with_pos.py \
  --input data/processed/train.jsonl \
  --output data/processed/train-pos.jsonl \
  --backend stanza \
  --model en
```

PowerShell equivalent:

```powershell
python python_tools/enrich_with_pos.py `
  --input data/processed/train.jsonl `
  --output data/processed/train-pos.jsonl `
  --backend stanza `
  --model en
```

The enrichment step preserves the existing tokenization and writes `lemmas`,
`pos` (Penn Treebank tags for NLTK, Universal POS for spaCy/Stanza), and
`morph` (empty for NLTK). If the tagger changes token alignment,
the script fails instead of silently rewriting the sentence.

Build an optional WordNet lemma/POS inventory. NLTK and WordNet data are still
explicit dependencies here; the script verifies they are installed and never
downloads them automatically:

```bash
python python_tools/build_wordnet_inventory.py \
  --corpus data/processed/train-pos.jsonl \
  --output data/processed/wordnet_inventory.json
```

PowerShell equivalent:

```powershell
python python_tools/build_wordnet_inventory.py `
  --corpus data/processed/train-pos.jsonl `
  --output data/processed/wordnet_inventory.json
```

Build the deterministic JSON candidate layer from corpus POS, WordNet fallback,
the `pos_mapping` cascade, and seeds. The mapping is applied in Haskell, so the
candidate file and on-the-fly training use the same code path:

```bash
cabal run ccg-induction -- build-candidates \
  --corpus data/processed/train-pos.jsonl \
  --wordnet data/processed/wordnet_inventory.json \
  --config configs/default.yaml \
  --output data/processed/candidate_lexicon.json
```

PowerShell equivalent:

```powershell
cabal run ccg-induction -- build-candidates `
  --corpus data/processed/train-pos.jsonl `
  --wordnet data/processed/wordnet_inventory.json `
  --config configs/default.yaml `
  --output data/processed/candidate_lexicon.json
```

When a token has explicit corpus POS, that POS drives the candidate templates.
WordNet is used as a lemma/POS fallback for tokens without explicit POS. Seeds
from the YAML config are merged deterministically and can be locked for initial
activation.

Train with the generated candidate lexicon either by using
`candidate_constraints.candidate_lexicon_path` from the YAML config, or by
passing the path explicitly:

```bash
cabal run ccg-induction -- train \
  --corpus data/processed/train-pos.jsonl \
  --config configs/default.yaml \
  --candidate-lexicon data/processed/candidate_lexicon.json \
  --output runs/experiment-1
```

PowerShell equivalent:

```powershell
cabal run ccg-induction -- train `
  --corpus data/processed/train-pos.jsonl `
  --config configs/default.yaml `
  --candidate-lexicon data/processed/candidate_lexicon.json `
  --output runs/experiment-1
```

Python never assigns accepted CCG categories and does not implement repair or
parsing. Those decisions remain in Haskell.

Other expected auxiliary commands include:

```bash
python python_tools/preprocess_conllu.py \
  --input data/input.conllu \
  --output data/output.jsonl
```

PowerShell equivalent:

```powershell
python python_tools/preprocess_conllu.py `
  --input data/input.conllu `
  --output data/output.jsonl
```

### WikiText-2 and TinyStories discovery experiment

Download, tokenize, sentence-filter, and convert a bounded sample to the
project JSONL format:

```bash
python python_tools/download_corpora.py wikitext2 \
  --split train --max-sentences 1000 --max-tokens 20 \
  --output data/processed/wikitext2-train.jsonl

python python_tools/download_corpora.py tinystories \
  --split validation --max-sentences 1000 --max-tokens 20 \
  --output data/processed/tinystories-validation.jsonl
```

PowerShell equivalent:

```powershell
python python_tools/download_corpora.py wikitext2 `
  --split train --max-sentences 1000 --max-tokens 20 `
  --output data/processed/wikitext2-train.jsonl

python python_tools/download_corpora.py tinystories `
  --split validation --max-sentences 1000 --max-tokens 20 `
  --output data/processed/tinystories-validation.jsonl
```

TinyStories train is a multi-gigabyte download; start with validation for a
smoke experiment. Existing downloads are reused. Run induction and aggregate
the non-gold discovery diagnostics:

```bash
python python_tools/run_discovery_experiment.py \
  --corpus data/processed/wikitext2-train.jsonl \
  --config configs/corpus-smoke.yaml \
  --output runs/wikitext2-smoke \
  --jobs 8
```

PowerShell equivalent:

```powershell
python python_tools/run_discovery_experiment.py `
  --corpus data/processed/wikitext2-train.jsonl `
  --config configs/corpus-smoke.yaml `
  --output runs/wikitext2-smoke `
  --jobs 8
```

The discovery script has no third-party Python package dependency: it uses only
the Python standard library, `cabal`, and this Haskell project. It defaults to
at most eight logical CPU workers. Most runtime is the Haskell induction
subprocess, especially bounded repair parsing; report aggregation is linear in
the corpus and lexicon size. Use `--skip-train` to regenerate reports from an
existing completed run without training again.

In addition to the normal training artifacts, this writes
`discovery_summary.json` and `lexicon_observations.csv`. The summary includes
the atom/template inventories, categories per word, category depths, rule-use
ratios, repairs by sentence length, second-category words, singleton compound
categories, and unresolved examples. The CSV gives frequency, sentence
coverage, and typical contexts for each word/category pair.
Core training now writes candidate source, prior, acceptance sentence, and
repair reason to `learned_category_sources.jsonl`. Derivational dependence on
Composition or Type-raising is still not attributed per lexical category.

The default atom table already anchors `S`, `NP`, `N`, and `PP`. Raw datasets
without POS can be enriched explicitly, or candidate construction can fall back
to a generated WordNet lemma/POS inventory. With candidate constraints disabled,
the deterministic legacy initializer remains available.

## Development Notes

- Keep domain logic pure where practical.
- Keep effects at IO, CLI, and serialization boundaries.
- Add or update tests with semantic changes.
- Preserve deterministic ordering for search, repair, serialization, and
  metrics.
- Do not silently exceed configured bounds.
- Do not use raw text as the canonical in-memory category representation.

Before claiming a completed implementation, run:

```bash
cabal build all
cabal test all
cabal run ccg-induction -- parse \
  --grammar examples/toy-grammar.json \
  --sentence "John likes Mary"
```

PowerShell equivalent:

```powershell
cabal build all
cabal test all
cabal run ccg-induction -- parse `
  --grammar examples/toy-grammar.json `
  --sentence "John likes Mary"
```

For Python changes, also run:

```bash
python -m compileall python_tools
```

## License

BSD-3-Clause. See `LICENSE`.
