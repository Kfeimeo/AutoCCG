# ccg-induction

`ccg-induction` 是一个面向研究的系统，用于从已分词语料中归纳紧凑、
可解释的组合范畴语法（Combinatory Categorial Grammar，CCG）词汇范畴。

核心解析器、范畴表示、语法搜索、词汇修复和序列化由 Haskell 实现。
Python 仅用于语料准备、格式转换、实验聚合和绘图。

本仓库有意不封装现有 CCG 解析器。语法归纳和有界解析逻辑都在本仓库中实现。

## 目标

- 在词类型（word type）上学习紧凑词典，而不是在词元实例（token instance）上学习。
- 要求被接受的句子至少存在一个以 `S` 为根范畴的推导。
- 在扩展语法之前优先使用简单推导：
  1. Application
  2. 受限的同向 Composition
  3. 受限的 Type-raising
  4. 词汇修复
  5. 语法压缩
- 保持搜索有限、确定且可解释。
- 用稳定的文件格式序列化语法、词典、指标和推导摘要。

## 项目状态

仓库当前包含核心归纳流水线的 Haskell 基线实现：

- 基于整数的原子和范畴；
- 范畴驻留（interning）以及 pretty-print/parse 支持；
- Application 和一阶同向 Composition；
- 有界 Type-raising 模板；
- beam 风格的增量解析；
- 结构化解析失败信息；
- 语法候选和词典序成本；
- 词汇修复和压缩流程；
- 独立的 POS/WordNet/seed CandidateLexicon，支持有界、按先验排序的修复；
- JSONL 语料加载；
- 语法序列化；
- 用于训练、评估、解析、已学习词典检查和候选检查的 CLI 命令；
- 单元测试、性质测试和基准测试脚手架。

项目仍处于早期阶段。请将当前实现视为一个用于实验的有界基线，
而不是已经完成的 CCGbank 规模学习器。

## 仓库结构

```text
.
+-- app/                    # 可执行程序入口
+-- src/
|   +-- CCG/                # 原子、范畴、组合子、推导
|   +-- Corpus/             # JSONL 和纯文本语料 IO
|   +-- Evaluation/         # 覆盖率、歧义度、导出、gold 对比
|   +-- Grammar/            # 语法类型、成本、beam、归纳循环
|   +-- Lexicon/            # 初始化、修复、压缩
|   +-- Parser/             # 配置、状态、beam 解析器、失败、计数
|   +-- Serialization/      # 语法、词典、候选词典、推导格式
|   +-- CLI.hs              # 命令行接口
+-- test/                   # 单元测试和性质测试
+-- bench/                  # Criterion 基准测试
+-- AGENTS.md               # 工程和研究约束
+-- ccg-induction.cabal
```

目标完整结构还包括 `configs/`、`examples/`、`python_tools/`、`scripts/`
和 `runs/`，详见 `AGENTS.md`。

## 环境要求

- GHC 9.12 或兼容的稳定编译器
- Cabal
- Python 3.12+，用于辅助工具

当前 Cabal 文件使用 `GHC2024`。

## 构建

```bash
cabal build all
```

运行测试：

```bash
cabal test all
```

运行基准测试：

```bash
cabal bench
```

## CLI

可执行程序名为 `ccg-induction`。

从 JSONL 训练语法：

```bash
cabal run ccg-induction -- train \
  --corpus examples/toy.jsonl \
  --config configs/toy.yaml \
  --candidate-lexicon examples/toy-candidates.json \
  --output runs/toy \
  --jobs 4
```

评估冻结语法：

```bash
cabal run ccg-induction -- evaluate \
  --corpus examples/toy-test.jsonl \
  --grammar runs/toy/grammar.json \
  --output runs/toy/eval \
  --jobs 4
```

`--jobs` 默认为 `1`。训练会并行化独立的 grammar-beam 和词汇修复候选解析；
句子仍按顺序处理，因为每个句子都会更新已学习词典。评估会并行化句子。
不同 job 数下，候选排序和序列化结果仍保持确定性。
`train` 命令会显示单行进度条，包含已处理、已覆盖、未解析和每秒句子数。
重定向输出或无人值守批处理时可传入 `--no-progress`。

解析一个已分词句子：

```bash
cabal run ccg-induction -- parse \
  --grammar runs/toy/grammar.json \
  --sentence "John likes Mary"
```

检查某个词类型被分配的范畴：

```bash
cabal run ccg-induction -- inspect-lexicon \
  --grammar runs/toy/grammar.json \
  --word "likes"
```

检查先验候选，但不在解析器中激活：

```bash
cabal run ccg-induction -- inspect-candidates \
  --candidate-lexicon examples/toy-candidates.json \
  --word likes
```

基于语料 POS、配置中的 `pos_mapping`、可选的 WordNet 清单和 seed 构建候选词典 JSON：

```bash
cabal run ccg-induction -- build-candidates \
  --corpus data/processed/train-pos.jsonl \
  --config configs/default.yaml \
  --wordnet data/processed/wordnet_inventory.json \
  --output data/processed/candidate_lexicon.json
```

## 输入格式

训练和评估语料使用 JSONL：每行一个句子对象。
基线加载器只要求 `sentence_id` 和 `tokens`。

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

词汇范畴会被分配给规范化后的词类型。解析器不得创建句子私有原子，
也不得创建词元局部范畴来强行获得覆盖率。

## 配置

运行限制放在 YAML 配置中。配置文件中不存在的字段会回退到 Haskell 默认值。

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

training:
  seed: 42
  compression_interval: 100
  unresolved_policy: queue
```

默认原子表包含 `S`、`NP`、`N` 和 `PP`。候选约束、POS 模板、seed 条目、
初始化策略和有界修复策略记录在 [`configs/default.yaml`](configs/default.yaml)。
加载期间，会拒绝引入未配置原子或超出深度、斜杠数、元数上限的候选范畴。

## 输出

训练写出：

```text
grammar.json
lexicon.json
training_metrics.jsonl
candidate_metrics.json
learned_category_sources.jsonl
unresolved.jsonl
config.snapshot.yaml
candidate_lexicon.snapshot.json   # 使用候选 JSON 文件时
derivations/
```

评估写出：

```text
evaluation.json
sentence_results.jsonl
category_inventory.csv
ambiguity.csv
```

序列化语法带版本号。当前语法格式版本为 `2`，保存 word-to-category 词典，
以及候选来源、先验成本、接受句子和修复原因。版本 1 语法仍可读取。

## 架构

### 范畴

原子和范畴在内部使用整数 ID。所有范畴节点都通过 `CategoryStore` 驻留，
因此结构相等的范畴共享同一个 `CategoryId`。

```haskell
data CategoryNode
  = Atomic !AtomId
  | Functional !Slash !CategoryId !CategoryId
```

`Functional ForwardSlash result argument` 表示 `result / argument`。
`Functional BackwardSlash result argument` 表示 `result \ argument`。

### 解析器

解析是从左到右、基于 beam 的过程，不是单条不可回退的贪心 fold。
解析器按顺序尝试以下规则层级：

1. 仅 Application
2. Application 加一阶同向 Composition
3. 配置的 Type-raising 加 Composition

只有在解析器层级的回退全部失败后，才触发词汇修复。Type-raising 是一个局部融合操作：
只有当相邻范畴能立即与提升后的范畴通过同向 Composition 组合时才生成。
提升后的范畴永远不会插入或保留在 beam 中。

仅当相邻范畴对没有可用的 Application 规约，且其结果能被剩余输入消费时，
才生成 Composition。解析器会预计算一个确定性的 `rightReachableCategories` chart，
其中包含每个右上下文前缀仅通过 Application 可推导出的范畴，
并将其作为轻量级有用性过滤器。

### 语法搜索

语法候选携带词典序成本：

- 未解析句子数
- 词汇修复数
- 额外范畴数
- Type-raising 次数
- Composition 次数
- 范畴复杂度
- 歧义度
- 词典大小
- 特殊范畴惩罚
- 推导步数

候选会被规范化、去重、确定性排序，并截断到配置的 grammar beam 宽度。

### 修复和压缩

修复候选按“在仍参与当前句子至少一个完整推导的前提下，尽可能少地扩大全局假设空间”
进行评分。压缩会尝试删除冗余词汇范畴，同时保持所需覆盖率；
破坏性变更支持回滚。

### 候选约束

`CandidateLexicon` 和活动的已学习 `Lexicon` 被有意分离：

```text
POS / WordNet lemma POS / seed files
  -> bounded CandidateLexicon with prior costs
  -> conservative initial activation
  -> parser reads LearnedLexicon only
  -> all parser levels fail
  -> validate top-k candidate repairs
  -> small fixed unknown fallback if configured
```

locked seed 可以在初始化时激活。未锁定的 seed 条目会一直作为先验保留，直到修复发生。
单个非 seed 候选可按初始化配置激活。多候选词保持非活动状态，
除非显式启用 `activate_best_candidate_per_word`。每个被修复的范畴都会插入临时语法，
并且必须能把完整句子解析到 `S`；POS 和 WordNet 永远不能绕过解析器验证。

### POS 到范畴的映射

POS 证据通过 `pos_mapping` 映射为先验范畴，其组织方式参考
[lightblue](https://github.com/DaisukeBekki/lightblue) 的词典构建：

| lightblue | 本仓库 |
|---|---|
| `Templates.hs` 范畴构造函数 | `pos_mapping.templates`：带先验代价的具名范畴列表 |
| `jumanPos2Cat` 对 JUMAN 品词/细分类/活用型的 guard 级联 | `pos_mapping.rules`：针对 POS 标签的有序规则，首个匹配者生效 |
| `MyLexicon.hs` 手写功能词词典 | `seed_lexicon`：与 POS 候选合并，按先验代价排序 |
| JUMAN++ 形态分析 | NLTK `pos_tag` 输出的 Penn Treebank 标签（或 spaCy/Stanza 的 UPOS） |

```yaml
pos_mapping:
  templates:
    proper_noun: [{category: "NP", prior_cost: 0}]
    common_noun:
      - {category: "N", prior_cost: 0}
      - {category: "NP", prior_cost: 1}
    verb:
      - {category: "S\\NP", prior_cost: 0}
      - {category: "(S\\NP)/NP", prior_cost: 0}
    participle_modifier: [{category: "N/N", prior_cost: 2}]
  rules:
    - {tags: ["NNP", "NNPS"], templates: [proper_noun]}   # 必须位于 prefix NN 之前
    - {prefix: "NN", templates: [common_noun]}
    - {tags: ["VB", "VBD", "VBP", "VBZ"], templates: [verb]}
    - {tag: "VBG", templates: [verb, participle_modifier],
       categories: [{category: "NP", prior_cost: 3}]}
```

每条规则恰好使用 `tag`、`tags` 或 `prefix` 之一进行匹配，依次展开其具名
`templates`，再追加内联 `categories`。引用未定义模板或匹配条件不唯一的规则会在
加载配置时被拒绝。YAML 中请给标签和范畴加引号：裸写的 `N` 会被解析为布尔值。
细粒度的 Penn Treebank 标签相当于 JUMAN 的活用细分类：动词形态、比较级、
所有格和标点类别会选择不同的模板组合。默认配置同时覆盖 NLTK 输出的 Penn Treebank
标签集，以及 spaCy 和 Stanza 输出的 Universal POS 标签。扁平的
`pos_to_categories: {TAG: [...]}` 表仍被接受，作为在 `pos_mapping.rules`
之后尝试的精确标签规则的简写。

对每个 token，驱动级联的标签是语料 POS（UPOS `PUNCT` 会按 token 形状细化）。
没有 POS 时使用封闭形式的 token 形状。否则，若启用了 `use_wordnet_inventory`，
并通过 `candidate_constraints.wordnet_inventory_path` 或 `--wordnet` 提供了清单，
则使用该 lemma 的所有 WordNet POS。与 lightblue 不同，这里的范畴不带形态特征
（`S[dcl]`、`NP[nom]`）：原子清单没有特征，因此动词形态只影响提出哪些有界模板。
禁用候选约束时，旧版初始化会为匹配规则分配先验代价最低的范畴。

禁用约束时，旧的有界全集修复路径仍可用于回归和性能比较。
启用约束时，unknown fallback 只使用小型固定模板清单，
绝不枚举完整范畴全集。

可使用 `examples/constraint-benchmark.jsonl` 和两个
`configs/constraint-benchmark*.yaml` 配置复现仓库中的合成对比。
一次 Windows/GHC 9.14.1 验证运行得到：

| 度量 | 受约束 | 旧版非约束 |
|---|---:|---:|
| 已验证修复候选 | 0 | 18 |
| 分配的堆字节数（`+RTS -s`） | 2,785,832 | 17,054,904 |
| 包含进程启动的 wall time | 504 ms | 602 ms |
| RTS 使用的总内存 | 6 MiB | 6 MiB |

这个很小的 fixture 展示了 83.7% 的分配量下降，并消除了完整修复验证，
但它太小，不能支撑有意义的峰值常驻内存结论；运行时 6 MiB 下限主导了两次运行。
研究性能结论应使用有代表性的语料，并通过外部 peak-RSS 采样。

## Python 工具边界

Python 工具应准备数据并聚合实验。它不得重复实现 Haskell 解析器、
grammar beam、词汇修复搜索或归纳算法。

NLTK、WordNet、spaCy 和 Stanza 都是显式可选依赖。仓库不会在预处理期间自动下载 NLP 包、
语料或模型文件，因此请在运行脚本前安装需要使用的组件：

```bash
python -m pip install nltk spacy stanza pyyaml
python -m spacy download en_core_web_sm
python -c "import nltk; nltk.download('averaged_perceptron_tagger_eng'); nltk.download('wordnet'); nltk.download('omw-1.4')"
python -c "import stanza; stanza.download('en')"
```

进行 POS/lemma 增强时，从已经预分词、且记录中已有 `tokens` 的 JSONL 语料开始。
默认后端是 NLTK 的 averaged-perceptron 标注器，它为 `pos_mapping` 级联写出
Penn Treebank 标签，并写出 WordNet lemma：

```bash
python python_tools/enrich_with_pos.py \
  --input data/processed/train.jsonl \
  --output data/processed/train-pos.jsonl \
  --backend nltk
```

也可以选择 spaCy：

```bash
python python_tools/enrich_with_pos.py \
  --input data/processed/train.jsonl \
  --output data/processed/train-pos.jsonl \
  --backend spacy \
  --model en_core_web_sm
```

或选择 Stanza：

```bash
python python_tools/enrich_with_pos.py \
  --input data/processed/train.jsonl \
  --output data/processed/train-pos.jsonl \
  --backend stanza \
  --model en
```

增强步骤会保留既有分词，并写出 `lemmas`、`pos`（NLTK 为 Penn Treebank 标签，
spaCy/Stanza 为 Universal POS）以及 `morph`（NLTK 下为空）。如果标注器改变了 token 对齐，脚本会失败，而不是静默改写句子。

构建可选的 WordNet lemma/POS 清单。这里 NLTK 和 WordNet 数据仍是显式依赖；
脚本会验证它们已安装，并且绝不会自动下载：

```bash
python python_tools/build_wordnet_inventory.py \
  --corpus data/processed/train-pos.jsonl \
  --output data/processed/wordnet_inventory.json
```

基于语料 POS、WordNet fallback、`pos_mapping` 级联和 seed 构建确定性的 JSON 候选层。
映射在 Haskell 中执行，因此候选文件与训练时即时构建走同一条代码路径：

```bash
cabal run ccg-induction -- build-candidates \
  --corpus data/processed/train-pos.jsonl \
  --wordnet data/processed/wordnet_inventory.json \
  --config configs/default.yaml \
  --output data/processed/candidate_lexicon.json
```

当 token 具有显式语料 POS 时，该 POS 驱动候选模板。WordNet 用作缺少显式 POS 的
token 的 lemma/POS fallback。YAML 配置中的 seed 会以确定性方式合并，
并且可以被锁定以便初始激活。

可以通过 YAML 配置中的 `candidate_constraints.candidate_lexicon_path`
使用生成的候选词典，也可以显式传入路径：

```bash
cabal run ccg-induction -- train \
  --corpus data/processed/train-pos.jsonl \
  --config configs/default.yaml \
  --candidate-lexicon data/processed/candidate_lexicon.json \
  --output runs/experiment-1
```

Python 永远不分配已接受的 CCG 范畴，也不实现修复或解析。
这些决策保留在 Haskell 中。

其他预期辅助命令包括：

```bash
python python_tools/preprocess_conllu.py \
  --input data/input.conllu \
  --output data/output.jsonl
```

### WikiText-2 和 TinyStories 发现实验

下载、分词、句子过滤，并将有界样本转换为项目 JSONL 格式：

```bash
python python_tools/download_corpora.py wikitext2 \
  --split train --max-sentences 1000 --max-tokens 20 \
  --output data/processed/wikitext2-train.jsonl

python python_tools/download_corpora.py tinystories \
  --split validation --max-sentences 1000 --max-tokens 20 \
  --output data/processed/tinystories-validation.jsonl
```

TinyStories train 是多 GB 下载；烟雾实验建议先从 validation 开始。
已有下载会被复用。运行归纳并聚合非 gold 的发现诊断：

```bash
python python_tools/run_discovery_experiment.py \
  --corpus data/processed/wikitext2-train.jsonl \
  --config configs/corpus-smoke.yaml \
  --output runs/wikitext2-smoke \
  --jobs 8
```

发现脚本没有第三方 Python 包依赖：只使用 Python 标准库、`cabal` 和本 Haskell 项目。
默认最多使用八个逻辑 CPU worker。大部分运行时间在 Haskell 归纳子进程中，
尤其是有界修复解析；报告聚合在语料和词典大小上线性增长。
使用 `--skip-train` 可基于已有完成运行重新生成报告，而不再次训练。

PowerShell 等价命令：

```powershell
python .\python_tools\run_discovery_experiment.py `
  --corpus .\data\processed\wikitext2-train.jsonl `
  --config .\configs\corpus-smoke.yaml `
  --output .\runs\wikitext2-smoke `
  --jobs 8
```

除正常训练产物外，该脚本还会写出 `discovery_summary.json`
和 `lexicon_observations.csv`。summary 包含原子/模板清单、每词范畴数、
范畴深度、规则使用比例、按句长统计的修复、拥有第二范畴的词、
singleton compound categories 和未解析示例。CSV 给出每个 word/category
配对的频率、句子覆盖率和典型上下文。
核心训练现在会把候选来源、先验、接受句子和修复原因写入
`learned_category_sources.jsonl`。Composition 或 Type-raising 的推导依赖
仍未按词汇范畴归因。

默认原子表已经锚定 `S`、`NP`、`N` 和 `PP`。没有 POS 的原始数据集可以显式增强，
也可以让候选构建回退到生成的 WordNet lemma/POS 清单。禁用候选约束时，
确定性的 legacy initializer 仍可使用。

## 开发说明

- 尽量保持领域逻辑纯净。
- 将 effects 保持在 IO、CLI 和序列化边界。
- 语义变更必须新增或更新测试。
- 对搜索、修复、序列化和指标保持确定性排序。
- 不要静默超过配置边界。
- 不要使用原始文本作为规范内存范畴表示。

声明实现完成前，请运行：

```bash
cabal build all
cabal test all
cabal run ccg-induction -- parse \
  --grammar examples/toy-grammar.json \
  --sentence "John likes Mary"
```

如有 Python 变更，也请运行：

```bash
python -m compileall python_tools
```

## 许可证

BSD-3-Clause。见 `LICENSE`。
