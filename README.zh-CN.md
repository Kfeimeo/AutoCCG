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

命令以 bash（Linux/macOS）形式给出。单行命令可在 Windows PowerShell 中原样运行；
每条多行命令后面都附有 PowerShell 等价命令，续行符用反引号（`` ` ``）代替 `\`。

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

PowerShell 等价命令：

```powershell
cabal run ccg-induction -- train `
  --corpus examples/toy.jsonl `
  --config configs/toy.yaml `
  --candidate-lexicon examples/toy-candidates.json `
  --output runs/toy `
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

PowerShell 等价命令：

```powershell
cabal run ccg-induction -- evaluate `
  --corpus examples/toy-test.jsonl `
  --grammar runs/toy/grammar.json `
  --output runs/toy/eval `
  --jobs 4
```

`--jobs` 默认为 `1`。训练会并行化独立的 grammar-beam 和词汇修复候选解析；
句子仍按顺序处理，因为每个句子都会更新已学习词典。评估会并行化句子。
不同 job 数下，候选排序和序列化结果仍保持确定性。
`train` 命令会显示单行进度条，包含已处理、已覆盖、未解析和每秒句子数。
重定向输出或无人值守批处理时可传入 `--no-progress`。

`evaluate` 和 `parse` 接受 `--config FILE`，用于指定解析规则和范畴上限
（`rules`、`categories`、`parser`）。不传时，它们使用 `train` 写在语法文件旁边的
`config.snapshot.yaml`，这样评估时用的就是训练时的规则，包括 ASP 和组合相关开关；
两者都没有时才回退到内置默认值。实际使用的配置会打印到 stderr。`inspect-candidates`
也接受 `--config`，用于原子和范畴上限。

解析一个已分词句子：

```bash
cabal run ccg-induction -- parse \
  --grammar runs/toy/grammar.json \
  --sentence "John likes Mary"
```

PowerShell 等价命令：

```powershell
cabal run ccg-induction -- parse `
  --grammar runs/toy/grammar.json `
  --sentence "John likes Mary"
```

检查某个词类型被分配的范畴：

```bash
cabal run ccg-induction -- inspect-lexicon \
  --grammar runs/toy/grammar.json \
  --word "likes"
```

PowerShell 等价命令：

```powershell
cabal run ccg-induction -- inspect-lexicon `
  --grammar runs/toy/grammar.json `
  --word "likes"
```

检查先验候选，但不在解析器中激活：

```bash
cabal run ccg-induction -- inspect-candidates \
  --candidate-lexicon examples/toy-candidates.json \
  --word likes
```

PowerShell 等价命令：

```powershell
cabal run ccg-induction -- inspect-candidates `
  --candidate-lexicon examples/toy-candidates.json `
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

PowerShell 等价命令：

```powershell
cabal run ccg-induction -- build-candidates `
  --corpus data/processed/train-pos.jsonl `
  --config configs/default.yaml `
  --wordnet data/processed/wordnet_inventory.json `
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
  max_composition_degree: 2
  allow_coordination: true
  allow_period_absorption: true
  allow_punctuation_absorption: true
  allow_argument_swap: false

training:
  seed: 42
  compression_interval: 100
  unresolved_policy: queue
```

交叉组合和广义组合分别由 `rules.allow_crossed_composition` 和
`rules.allow_generalized_composition` 控制。广义组合作用于方向一致的斜杠脊，
阶数从 2 到 `rules.max_composition_degree`（默认 `2`，至少为 `1`）；
广义交叉组合需要同时开启两个开关。在默认阶数下，广义组合恰好就是二阶组合：

```text
B2>   X/Y  (Y/Z)/W  => (X/Z)/W
B2<   (Y\Z)\W  X\Y  => (X\Z)\W
B2x>  X/Y  (Y\Z)\W  => (X\Z)\W        （还需要 allow_crossed_composition）
B2x<  (Y/Z)/W  X\Y  => (X/Z)/W        （还需要 allow_crossed_composition）
```

把阶数设为 `1` 会关闭广义组合；更高的值允许直到该阶数的 B^n，仍受范畴上限约束。

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

1. 仅 Application（以及并列和标点吸收）
2. Application 加 Composition
3. 再加 ASP（开启 `rules.allow_argument_swap` 时）
4. 再加配置的 Type-raising（与 Composition 融合）

只有在解析器层级的回退全部失败后，才触发词汇修复。Type-raising 是一个局部融合操作：
只有当相邻范畴能立即与提升后的范畴通过已启用的 Composition 规则组合时才生成。
提升后的范畴永远不会插入或保留在 beam 中。词汇项以及由 Application 或 Composition
推导出的成分（例如 NP `the man`）都可以提升；融合 Type-raising 的结果不能再提升，
因此任何成分都不会被提升两次。

仅当相邻范畴对没有可用的 Application 规约时，才生成 Composition。Composition 结果
只有在仍可能参与推导时才保留：它能与栈中紧邻其下的成分组合，或能与剩余输入某个前缀
可推导出的范畴组合，或它本身已是完整的根范畴。右侧判断使用确定性的
`rightReachableCategories` chart：它用当前层级的全部规约（Application、已启用的
Composition 和融合 Type-raising）构建，且不受 beam 限制，因此是 beam 可构造成分的
超集，不会丢弃可推导的状态。该 chart 的复杂度是句长的三次方，每个 Composition 或
Type-raising 层级计算一次。

因此，在 beam 和状态容量不截断的配置下（例如 `configs/untruncated.yaml`），
只要在已启用规则和范畴上限内存在到 `S` 的推导，解析器就能找到。它仍然只返回最低成功
层级中代价最小的推导，并且同一相邻对上能做 Application 时不会再尝试 Composition。

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

默认的 `pos_mapping` 复现了 [lightblue](https://github.com/DaisukeBekki/lightblue)
的英文词典（`src/Parser/Language/English/Lexicon.hs` 中的 `fromNLTKtoCCG`）。它把
NLTK 的 Penn Treebank 标签（部分条目还要求具体词形）各映射到一个范畴；
lightblue 的特征和语义未保留：

| lightblue 模式 `(词, POS)` | 范畴（先验 0） |
|---|---|
| `(_, NNP)`、`(_, PRP)` | `NP` |
| `("a"/"A", DT)` | `(S/(S\NP))/N` |
| `(_, DT)` | `NP/N` |
| `(_, NN)` | `N` |
| `(_, WP)` | `N/N` |
| `(_, NNS)`、`(_, VBN)`、`(_, VBD)` | `S\NP` |
| `(_, VBZ)` | `(S\NP)/NP` |
| `(_, IN)`、`(_, RB)` | `(S\NP)\(S\NP)` |
| `("and"/"or", CC)` | `CONJ` |
| `("Either", CC)` | `((S/S)/CONJ)/S` |
| `(_, ".")` | `PERIOD` |
| 标点和符号标签的 `(_, _)` | `PUNCT` |

lightblue 的范畴先验代价固定为 0，因此初始激活的就是它。对于 lightblue 中不常规或
覆盖过窄的条目（例如把 `NNS` 当作谓词、`IN` 不带宾语、`VBD` 只有不及物用法），
另外以先验代价 1 及以上补充常规的 CCGbank 风格范畴，它们只能经过验证的修复进入
已学习词典。lightblue 未映射的标签（`VB`、`VBP`、`VBG`、`JJ*`、`MD`、`TO`、`CD`、
其他 `CC` 词等）使用常规规则，而不是 lightblue 的兜底 `PUNCT`。seed 词典中的 `a`
和标点也与 lightblue 保持一致。

`CONJ`、`PERIOD` 和 `PUNCT` 是在 `atoms.predefined` 中声明的原子，由 lightblue 的
三条非组合规则处理，每条都可在 `rules` 中单独开关：

```text
allow_coordination             X  CONJ  X  => X   （左侧 X 本身不能是并列结果）
allow_period_absorption        S  PERIOD   => S
allow_punctuation_absorption   X  PUNCT    => X   （X 的最终结果不能是 N）
```

它们属于 Application 层级：在每个解析层级都可用，并且同一相邻对上一旦可用就不再
尝试 Composition。

`pos_mapping` 本身是通用机制：由针对 POS 标签的有序规则级联选择具名 `templates`，
首个匹配的规则生效。

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

每条规则恰好使用 `tag`、`tags` 或 `prefix` 之一进行匹配，可以用 `words`
限定为精确、区分大小写的词形，依次展开其具名 `templates`，再追加内联 `categories`。
引用未定义模板、匹配条件不唯一或 `words` 为空的规则会在加载配置时被拒绝。
YAML 中请给标签和范畴加引号：裸写的 `N` 会被解析为布尔值。默认配置同样映射了
spaCy 和 Stanza 输出的 Universal POS 标签。扁平的 `pos_to_categories: {TAG: [...]}`
表仍被接受，作为在 `pos_mapping.rules` 之后尝试的精确标签规则的简写。

对每个 token，若语料提供了排名的 `pos_candidates` 且开启了
`candidate_constraints.use_pos_candidates`，则用这些标签驱动级联：第 i 个标签（从 0 开始）
给其模板的先验代价加上 `i * pos_candidate_rank_cost`，来自 WordNet 的标签记录为来源
`FromWordNetPos`。否则使用单个语料 POS（UPOS `PUNCT` 会按 token 形状细化）。
没有 POS 时使用封闭形式的 token 形状。否则，若启用了 `use_wordnet_inventory`，
并通过 `candidate_constraints.wordnet_inventory_path` 或 `--wordnet` 提供了清单，
则使用该 lemma 的所有 WordNet POS。禁用候选约束时，旧版初始化会为匹配规则分配
先验代价最低的范畴。

### Eisner 范式解析器

`parser.algorithm: eisner` 用一个只含函数应用和组合的穷举 CKY 图表解析器替换移进-归约
解析器，并施加 Eisner (1996) 的范式约束：由前向组合（`>B`、`>Bn`）产生的成分，永远不作为
前向规则左侧的主函子；由后向组合产生的成分，永远不作为后向规则右侧的主函子。在只有应用
和组合的语法里，这可以消除伪歧义，因此根节点的每个推导都对应一种不同的语义解读。与移进-
归约解析器不同，这里函数应用不会挡住同一相邻对上的组合，也没有 beam，图表是精确的。

`parser.derivations` 决定保留哪些推导：

| 取值 | 保留的推导 |
|---|---|
| `first`（默认） | 一个代价最低的推导（组合次数最少，其次推导步数最少） |
| `all` | 所有范式推导，即所有语义解读，数量受 `parse_count_cap` 限制 |

`parse_count` 总是报告解读的数量（有上限）。`parse` 会在 `derivations` 字段输出保留的推导树
（汇总格式版本 2），例如 `derivations: all` 时：

```text
John saw Mary with telescopes   ->  parse_count 2
  [John [saw [Mary [with telescopes]]]]      名词短语挂靠
  [John [[saw Mary] [with telescopes]]]      动词短语挂靠
```

`configs/eisner.yaml` 是现成的配置：前向和后向的 B 与 B²，不含交叉组合，
`derivations: first`。类型提升、ASP、并列和吸收规则都不属于 Eisner 解析器；只要这些开关
有任何一个开着，`algorithm: eisner` 在加载配置时就会被拒绝。因此该配置把 lightblue 的
`CONJ`、`PERIOD`、`PUNCT` 换成了只靠函数应用即可组合的范畴（`.` 为 `S\S`，`and`/`or`
为 `(NP\NP)/NP` 等）。训练、修复和评估都可以直接使用：图表解析失败时，会给出与移进-归约
解析器相同格式的失败前沿。移进-归约解析器目前仍只记录词汇节点，所以它的 `parse` 输出没有
`derivations` 字段。

```bash
cabal run ccg-induction -- train \
  --corpus data/processed/train-pos.jsonl \
  --config configs/eisner.yaml \
  --candidate-lexicon data/processed/candidate_lexicon.json \
  --output runs/eisner
```

### 参数交换（ASP）

`rules.allow_argument_swap` 开启 ASP。这是一条一元规则：当一个范畴最外两层参数
分别位于左右两侧时，交换它们被消耗的顺序：

```text
ASP   (X\A)/B  <=>  (X/B)\A
```

`A` 仍在左边、`B` 仍在右边，因此语序和语义都不变。例如 `read := (S\NP)/NP`
可以变成 `(S/NP)\NP`，这样 `John read` 只用逆向函数应用就得到 `S/NP`，不再需要
类型提升和组合。ASP 是一个回退层级：只有当函数应用（FA、BA）和组合（B、Bⁿ，前向和
后向）都无法推导出整句时才会尝试，并且在类型提升之前。它作用于词汇项和推导出的
成分，每个成分最多交换一次，并且在成分刚产生时进行。交换后的范畴必须满足深度上限
（斜杠数和元数不会改变）。解析代价在组合次数之后统计 ASP 次数，所以代价更低的推导
会避免不必要的交换。组合有用性过滤和右侧可达图表都考虑了 ASP，因此开启后解析器的
完备性保证仍然成立。内置默认值和各实验配置中它是关闭的，在 `configs/default.yaml` 和
`configs/untruncated.yaml` 中开启；所有配置文件都显式列出了这个开关。

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

PowerShell 等价命令：

```powershell
python python_tools/enrich_with_pos.py `
  --input data/processed/train.jsonl `
  --output data/processed/train-pos.jsonl `
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

PowerShell 等价命令：

```powershell
python python_tools/enrich_with_pos.py `
  --input data/processed/train.jsonl `
  --output data/processed/train-pos.jsonl `
  --backend spacy `
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

PowerShell 等价命令：

```powershell
python python_tools/enrich_with_pos.py `
  --input data/processed/train.jsonl `
  --output data/processed/train-pos.jsonl `
  --backend stanza `
  --model en
```

增强步骤会保留既有分词，并写出 `lemmas`、`pos`（NLTK 为 Penn Treebank 标签，
spaCy/Stanza 为 Universal POS）以及 `morph`（NLTK 下为空）。如果标注器改变了 token 对齐，脚本会失败，而不是静默改写句子。

NLTK 后端还会为每个 token 写出排名的 `pos_candidates`（首选在前，每个标签带 `source`：
`nltk` 或 `wordnet`），`pos` 仍保留 NLTK 的单个首选标签：

- 功能词、专有名词、数词和标点（NLTK 首选标签不是名词、动词、形容词或副词标签）：
  取 NLTK 感知机打分前 k 个标签（`--top-k`，默认 3），非首选标签中概率低于
  `--min-probability`（默认 0.01）的会被丢弃。NLTK 标签词典中的词在 NLTK 看来没有歧义，
  只保留一个标签。
- 实词：先放 NLTK 的首选标签，再按 NLTK 打分依次放入 WordNet 对该词形（所有词义）允许的
  其他 Penn Treebank 标签；屈折形式由 WordNet 的原形推出（`sleeps` 得到 `NNS` 和 `VBZ`，
  `ran` 得到 `VBD` 和 `VBN`）。WordNet 中查不到的词回退到 NLTK 的前 k 个标签。
  `--no-wordnet-expansion` 会让所有词都使用前 k 个标签。

功能词不查 WordNet，因为 WordNet 对其中很多词只收录了罕见的同形实词（`a` 是埃，
`or` 是俄勒冈，`in` 是英寸），也没有专有名词和封闭词类标签。例如 `They book a flight`
会得到 `book/NN|VB|VBP`，于是 NLTK 标签词典永远不会给出的 `book` 的动词用法，
也能在词汇修复中被启用。

构建可选的 WordNet lemma/POS 清单。这里 NLTK 和 WordNet 数据仍是显式依赖；
脚本会验证它们已安装，并且绝不会自动下载：

```bash
python python_tools/build_wordnet_inventory.py \
  --corpus data/processed/train-pos.jsonl \
  --output data/processed/wordnet_inventory.json
```

PowerShell 等价命令：

```powershell
python python_tools/build_wordnet_inventory.py `
  --corpus data/processed/train-pos.jsonl `
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

PowerShell 等价命令：

```powershell
cabal run ccg-induction -- build-candidates `
  --corpus data/processed/train-pos.jsonl `
  --wordnet data/processed/wordnet_inventory.json `
  --config configs/default.yaml `
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

PowerShell 等价命令：

```powershell
cabal run ccg-induction -- train `
  --corpus data/processed/train-pos.jsonl `
  --config configs/default.yaml `
  --candidate-lexicon data/processed/candidate_lexicon.json `
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

PowerShell 等价命令：

```powershell
python python_tools/preprocess_conllu.py `
  --input data/input.conllu `
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

PowerShell 等价命令：

```powershell
python python_tools/download_corpora.py wikitext2 `
  --split train --max-sentences 1000 --max-tokens 20 `
  --output data/processed/wikitext2-train.jsonl

python python_tools/download_corpora.py tinystories `
  --split validation --max-sentences 1000 --max-tokens 20 `
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

PowerShell 等价命令：

```powershell
python python_tools/run_discovery_experiment.py `
  --corpus data/processed/wikitext2-train.jsonl `
  --config configs/corpus-smoke.yaml `
  --output runs/wikitext2-smoke `
  --jobs 8
```

发现脚本没有第三方 Python 包依赖：只使用 Python 标准库、`cabal` 和本 Haskell 项目。
默认最多使用八个逻辑 CPU worker。大部分运行时间在 Haskell 归纳子进程中，
尤其是有界修复解析；报告聚合在语料和词典大小上线性增长。
使用 `--skip-train` 可基于已有完成运行重新生成报告，而不再次训练。

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

PowerShell 等价命令：

```powershell
cabal build all
cabal test all
cabal run ccg-induction -- parse `
  --grammar examples/toy-grammar.json `
  --sentence "John likes Mary"
```

如有 Python 变更，也请运行：

```bash
python -m compileall python_tools
```

## 许可证

BSD-3-Clause。见 `LICENSE`。
