> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/MTRouter_TRAINING_REPOSITORY_HANDOFF.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# MTRouter 决策头训练独立仓库任务书

状态：暂缓（项目所有者于 2026-10-18 决定暂不训练；保留接口与任务书）
编制日期：2026-10-18（Asia/Shanghai）
来源项目：`harmony_agent`
建议独立仓库名：`harmony-agent-mtrouter-training`

## 1. 任务目标

> 暂缓说明：当前不创建独立训练仓库，不安装依赖，不下载模型，不读取训练或 Provider 凭据，不运行训练、论文复现或付费 benchmark。本任务书仅作为后续恢复时的冻结输入；恢复必须由项目所有者重新明确启动。

建立一个独立的研究与训练仓库，在不修改 `harmony_agent` 在线 Runtime 的前提下，完成 MTRouter 官方实现的可复验环境、历史 embedding 预计算、决策头训练、离线评估、checkpoint 导出和 golden decision fixture 生成。

独立仓库最终向 `harmony_agent` 交付候选训练产物和证据。`harmony_agent` 主仓库继续负责 ArkTS 适配、ArtifactManifest 转换、签名、Registry、device parity、shadow、canary、active 和 rollback。

本任务不是重新设计 Router，也不是开发产品 UI、页面、Entry HAP 或第二套 Agent Runtime。

## 2. 已完成前置工作

`harmony_agent` 的 T48/M12-A 已完成上游来源冻结和复现准入：

- 官方仓库：`https://github.com/ZhangYiqun018/MTRouter`
- 固定 commit：`ee9e4573a128c3e54aa8c83800318bfb783c4dfe`
- 固定 tree：`6911bcf33bfdd30d6f414c09b5f5d14c5deeb913`
- 论文：arXiv `2604.23530v1`
- 上游许可证：MIT
- history encoder：`Qwen/Qwen3-Embedding-0.6B`
- embedding 维度：1024
- history 最大长度：8192 tokens
- 默认训练：100 epochs、batch 64、AdamW、learning rate `1e-3`、weight decay `0.01`、early stopping patience 3
- 默认模型池：GPT-5、DeepSeek-V3.2、MiniMax-M2、Kimi-K2、Gemini-2.5-Flash-Lite、GPT-OSS-120B

T48 只证明来源锁与离线准入检查可重复。它没有安装研究依赖、下载模型、读取凭据、调用 Provider、运行 benchmark、生成 checkpoint 或形成路由质量结论。

移交时应从 `harmony_agent` 只读取得并复制以下文件，记录复制后 SHA-256：

- `offline/paper_repro/mtrouter/upstream-lock.json`
- `offline/paper_repro/mtrouter/reproduction-spec.json`
- `offline/paper_repro/mtrouter/check-mtrouter-repro.mjs`
- `offline/paper_repro/mtrouter/test-mtrouter-preflight.mjs`
- `artifacts/t48-mtrouter-preflight/20261018-142400-final/source-sha256.tsv`
- `artifacts/t48-mtrouter-preflight/20261018-142400-final/preflight-v1.json`

独立仓库不得反向修改这些源文件，也不得用 Junction、symlink 或未记录的本地路径作为可复现输入。

## 3. 仓库职责边界

### 3.1 独立仓库负责

1. 固定并核验 MTRouter 上游源码、论文、模型和数据身份。
2. 建立仓库内隔离的 Python/CUDA 训练环境和 dependency lock。
3. 运行上游 smoke test，并如实记录兼容性修补。
4. 预计算冻结的 history encoder embeddings。
5. 训练官方 ModelEncoder 和单头 Q-Network。
6. 对 checkpoint 做 held-out、三随机种子和漂移检查。
7. 导出 checkpoint、模型池顺序、feature schema、归一化参数和 golden decision fixtures。
8. 输出 digest、环境清单、命令日志、性能、成本和失败证据。
9. 提供一个离线、无凭据的 reference inference CLI，供主仓库做 parity。

### 3.2 独立仓库不负责

- 不实现或复制 `AgentRuntimeFacade`、RuntimeCoordinator、Registry、Budget 或 Policy Gateway。
- 不提交、暂停、恢复、取消、授权或推进 Agent 任务。
- 不在 hard eligibility 之前增加候选模型；输入只能是主 Runtime 已过滤的候选集。
- 不决定 single/multi、角色数量或工具授权。
- 不把 Provider 密钥、Serper 密钥、原始会话正文或用户隐私写入 Git、日志、fixture 或 checkpoint metadata。
- 不为 `harmony_agent` 签名 artifact，不管理生产私钥，不发布 canary/active。
- 不声明 HarmonyOS 端性能、ArkTS parity 或生产质量已经通过。

## 4. 不可改变的架构约束

1. `AgentRuntimeFacade` 仍是 `harmony_agent` 唯一任务控制入口。
2. MTRouter 只替换 M04 Model Router 的评分策略。
3. region、隐私、能力、模型可用性和成本上限等 hard eligibility 必须先于 MTRouter。
4. MTRouter 只能对传入的合格候选模型排序，不能恢复被过滤的候选。
5. 每次失败、超时、格式异常、未知模型、NaN/Infinity 或 artifact 不兼容都必须 fail closed，并由主 Runtime 回退 deterministic baseline。
6. 上线顺序保持：`offline replay -> device parity -> shadow -> canary -> active`。
7. paper reproduction 与 harmony_agent adaptation 必须分开报告，不能用 adaptation 结果冒充论文复现。

### 4.1 应用包体硬边界

`Qwen/Qwen3-Embedding-0.6B` 只作为训练端和受控 embedding service 的冻结 history encoder，禁止把其权重、tokenizer 大文件或 Python/PyTorch runtime 打入 `harmony_agent` 的 HAR、HAP 或产品宿主包。

应用侧候选产物只允许包含 ModelEncoder、Q-Network、必要的归一化参数、模型池身份和二进制加载 metadata。按当前六模型池计算，可训练部分约 349,537 个参数：FP32 原始权重约 1.34 MiB，FP16 约 0.67 MiB，INT8 理论下限约 0.34 MiB。上游新版 checkpoint 也明确排除冻结的 HF encoder 权重。

初始发布预算：

- decision payload（权重和必要 metadata）不超过 5 MiB；
- 集成后的 release HAP 增量不超过 8 MiB；
- golden fixtures、训练报告、embedding cache、optimizer state 和上游 checkpoint 不进入生产 HAP；
- 独立仓库必须输出打包前后字节数、HAR/HAP 增量和 SHA-256；
- 任一产物包含 0.6B encoder 权重时直接拒绝交付。

运行时的 1024 维 history embedding 默认由受控 embedding service 生成，再交给应用内小型决策头评分。服务必须绑定相同 encoder revision、tokenizer、pooling、最大 token 数和 feature schema；服务不可用、超时或返回维度/摘要异常时，由主 Runtime 回退 deterministic baseline。若以后研究端侧小编码器，必须建立新的 feature schema、重新训练并单独验收，不能继续声称与当前 MTRouter checkpoint 兼容。

### 4.2 已保留的 Runtime 扩展接口

`harmony_agent` 当前已经公开 `LearnedRouterPort.route(request: RouterRequest): RouterDecision`，`DeterministicModelRouter` 构造器也接受可选的 learned port。它已经保证先执行 Registry/hard eligibility，再把合格候选交给 learned policy；未启用、未注入、低置信度、越界 decision 或异常时继续使用 deterministic baseline。

独立训练仓库不得另建任务控制接口或复制 Runtime。它只需要按本任务书导出 checkpoint、feature schema 和 golden fixtures；后续主仓库以 `MTRouterLearnedPolicyAdapter` 一类内部适配器实现既有 `LearnedRouterPort`。

当前 `RouterRequest.featuresJson` 尚未冻结为 MTRouter 的真实 history embedding envelope，现阶段不得为了占位而传入虚构向量或把远程网络调用塞入同步 `route()`。训练仓库应先输出候选的版本化 feature schema。主仓库在 parity 阶段再决定以下实现之一：

1. 在进入同步 Router 前由受控异步 feature/embedding port 准备 1024 维向量；
2. 经评审增加版本化异步 learned-policy port，并明确 timeout、cancel 和 baseline fallback。

无论选择哪一种，现有 `LearnedRouterPort` 的策略边界、`RouterRequest`/`RouterDecision` 公共 DTO 和 deterministic fallback 语义都必须保留。未完成 schema、timeout/cancel、parity 与包体门之前，`learnedEnabled` 保持 `false`。

## 5. 建议仓库结构

```text
harmony-agent-mtrouter-training/
  README.md
  LICENSES/
    MTRouter-MIT.txt
  pyproject.toml
  uv.lock
  configs/
    upstream-reproduction.yaml
    harmony-agent-adaptation.yaml
  locks/
    upstream-lock.json
    reproduction-spec.json
    model-lock.json
    dataset-lock.json
  upstream/
    MTRouter/                  # 固定到指定 commit；不得静默跟随 main
  src/
    data/
    embeddings/
    training/
    evaluation/
    export/
    inference/
  tests/
  fixtures/
    golden-decisions/
  reports/
  artifacts/                  # 默认 Git ignore；发布清单只记录受控产物
  scripts/
    verify-source.*
    probe-throughput.*
    precompute-embeddings.*
    train-head.*
    evaluate.*
    export-handoff.*
```

目录名称可以按实际 Python 包规范调整，但职责和证据边界必须保留。

## 6. 环境要求与权限门

当前已知目标机器基线仅供估算，开始工作时必须重新检测：

- Windows
- NVIDIA RTX 5060 Ti，约 16 GB VRAM
- Java 21
- 当前系统只检测到 Python 3.14.5
- `uv 0.11.32` 可用
- D 盘此前约有 242 GiB 可用空间

研究依赖可能尚未支持 Python 3.14。优先在独立仓库内使用 Python 3.11 或 3.12 的隔离环境，不修改全局 Python、PATH、CUDA 或系统配置。

以下操作必须分别取得项目所有者授权后才能执行：

- 安装 Python、CUDA 或仓库依赖；
- 下载 Qwen 模型权重或 benchmark 数据；
- 读取或配置 Provider/Serper 凭据；
- 发起付费 Provider 请求；
- 上传数据、checkpoint 或日志；
- 创建远端 GitHub 仓库或推送；
- 删除大型缓存、旧环境或训练产物。

任何凭据只能通过外部 secret store 或进程环境注入。命令、报告和终端输出不得包含明文密钥。

## 7. 分阶段实施

### R01：独立仓库与来源锁

目标：形成不依赖 `harmony_agent` 工作树的独立、可审计仓库。

工作项：

- 初始化 Git 仓库和默认分支。
- 导入 T48 锁文件与准入 spec，保存来源路径和 SHA-256。
- 获取官方源码并 checkout 固定 commit；核验 commit、tree 和关键文件摘要。
- 保存 MIT license 和第三方许可证清单。
- 增加检查脚本，拒绝 commit、tree、论文目标、模型池和价格快照静默漂移。

验收：在无 Provider 凭据条件下，来源检查可重复通过；任一锁定字段变化都会失败。

### R02：隔离环境与上游 smoke

目标：证明依赖可安装、官方训练入口可以在本机启动。

工作项：

- 固定 Python、PyTorch、Transformers、CUDA runtime 和全部研究依赖版本。
- 把 cache、venv、临时文件和输出目录限制在独立仓库内。
- 运行 upstream unit/smoke tests。
- 使用合成小数据运行一次 CPU/GPU forward、embedding precompute 和单 epoch head training。
- 记录所有必要兼容补丁；补丁必须最小化并单独提交。

验收：全新 checkout 按文档可重建环境；smoke 运行不读取凭据、不访问 Provider，且产出确定的 shape/dtype 检查结果。

### R03：1,000 样本吞吐探针

目标：在完整训练前取得真实 ETA 和显存边界。

数据必须为公开、合成或已批准的脱敏样本，并覆盖至少 1K、2K、4K、8K token 桶。报告：

- 每个长度桶的 samples/s 和 tokens/s；
- batch 1、2、4、8 的峰值 VRAM；
- OOM 点和稳定 batch；
- embedding 缓存字节数；
- 决策头每 epoch 时间；
- 环境、commit、随机种子和完整命令。

预计范围仅供排期：

| 数据规模 | embedding 预计算 | 决策头训练 |
|---|---:|---:|
| 5千～1万，平均 1K～2K tokens | 10～60 分钟 | 1～5 分钟 |
| 3万～10万，平均 2K～4K tokens | 2～8 小时 | 5～30 分钟 |
| 大量接近 8K tokens | 8～24 小时以上 | 通常少于 1 小时 |

这些不是验收结果。R03 的实测吞吐才是后续 ETA 的依据。

### R04：数据合同与防泄漏检查

目标：冻结训练、验证和测试数据身份。

要求：

- 每个数据集保存来源、许可证、生成方式、样本数、token 分布和 SHA-256。
- 按任务或 episode 分组切分，禁止同一轨迹的相邻 turn 跨 train/validation/test 泄漏。
- 保存模型池顺序、模型 metadata、价格和 Provider snapshot。
- 原始用户会话、凭据、完整 Provider 响应和敏感记忆默认禁止进入数据集。
- 脱敏必须在导入独立仓库之前完成；训练仓库不承担原始敏感数据保管。
- 数据不足时允许形成 smoke checkpoint，但必须明确标为 `research-only`，不得作为上线候选。

### R05：官方复现

目标：按 T48 spec 分离执行 ScienceWorld 与 HLE 的三次运行。

执行付费 Provider/Serper 批次之前，先向项目所有者提交精确的模型、请求上限、token 上限、费用上限、数据发送范围和清理计划，取得单独授权。

验收规则沿用 `reproduction-spec.json`：

- 三次运行；
- 四项目标全部报告；
- 性能均值绝对容差为论文报告的一个标准差；
- 相同模型池、split 和价格快照；
- 成本相对容差 5%；
- 模型、数据、价格或 Provider 行为漂移时结论为 `nonComparable`；
- 缺证据时 fail closed。

### R06：harmony_agent 决策头训练

官方设计冻结 `Qwen3-Embedding-0.6B`，只训练 ModelEncoder 和 Q-Network。按六模型池计算，可训练参数约 349,537；不得把“只训练决策头”描述为对官方结构的降配。

最低要求：

- 固定三组随机种子；
- 预计算 embedding，并绑定 encoder revision、tokenizer、pooling、max tokens、dtype 和摘要；
- 保留 validation early stopping 和最佳 checkpoint；
- 报告每次 run 的 loss、held-out routing metric、质量、成本、延迟和稳定性；
- 与相同输入、候选集和价格快照下的 deterministic baseline 比较；
- 失败 run 也保留摘要，不得只报告最优 seed；
- 不用训练集或 validation 集作为最终质量结论。

若没有足够的 harmony_agent 训练轨迹，本阶段停止在数据准备或 smoke checkpoint，不得虚构路由收益。

### R07：导出与独立复验

至少导出：

1. 上游原生 checkpoint，例如 `q_function_best.pt`；
2. checkpoint 文件 SHA-256；
3. 不依赖 pickle 执行的安全权重导出或明确的受控转换工具；
4. 模型池的精确有序列表和 model metadata；
5. feature schema version；
6. encoder/tokenizer/pooling/max-token lock；
7. 归一化统计、tensor 名称、shape、dtype 和 layout；
8. reference inference CLI；
9. golden decision fixtures；
10. 训练、评估和环境报告。

reference inference CLI 必须支持完全离线的 `--input`/`--output` 文件模式，不读取 Provider 凭据，不发网络请求，并在未知 schema、未知模型、模型顺序漂移、非有限分数和 digest 不匹配时返回非零退出码。

## 8. Golden decision fixture 合同

fixture 使用版本化 JSONL。具体字段可在实现前与主仓库对齐，但至少要表达：

```json
{
  "schemaVersion": "1",
  "fixtureId": "stable-id",
  "featureSchemaVersion": "mtrouter-feature-v1",
  "artifactDigest": "sha256:<64 hex>",
  "history": [{"role": "user", "content": "sanitized fixture text"}],
  "eligibleModelIds": ["model-a", "model-b"],
  "modelSnapshotDigest": "sha256:<64 hex>",
  "expectedScores": [0.0, 0.0],
  "expectedRanking": ["model-a", "model-b"],
  "absoluteTolerance": 0.0001
}
```

要求：

- `eligibleModelIds` 顺序固定并纳入摘要；
- 输出覆盖单候选、多候选、并列分数、长历史、截断、未知模型和损坏输入；
- 明确定义 tie-break；
- 只含合成或已批准脱敏文本；
- fixture 记录 Python reference 的设备、dtype 和版本；
- 任何 NaN、Infinity、维度错误或模型池漂移都必须拒绝，而不是产生选择。

## 9. 向 harmony_agent 的交付包

独立仓库提交一个只读 handoff 目录或 release archive，包含：

```text
handoff/
  HANDOFF.json
  SHA256SUMS
  LICENSES/
  locks/
  checkpoint/
  export/
  fixtures/
  reports/
  commands/
```

`HANDOFF.json` 至少包含：

- 独立仓库完整 source commit；
- 上游 MTRouter commit/tree；
- source license；
- 有序 training data lineage；
- encoder、模型和 Provider snapshot；
- feature schema version；
- payload/checkpoint digest；
- paper reproduction、Python parity 和 adaptation 结果的独立对象；
- 已知限制和禁止声明；
- 所有文件的相对路径和 SHA-256。

handoff 包保持未签名候选状态。`harmony_agent` 侧审核后再映射到正式 `ArtifactManifest`，使用主仓库 T45 工具和外部受信 Ed25519 密钥完成签名。独立训练仓库不得接触生产私钥。

## 10. 测试与验收清单

- [ ] 来源 commit/tree/license/hash 与 T48 完全一致。
- [ ] clean checkout 可以重建隔离环境。
- [ ] dependency lock、Python、CUDA、driver 和 GPU 身份完整。
- [ ] 无凭据 smoke tests 通过。
- [ ] 1,000 样本吞吐和显存探针完成。
- [ ] 数据 lineage、split 和泄漏检查完成。
- [ ] 三 seed 训练完整保留，失败运行未被删除。
- [ ] held-out 结果与 deterministic baseline 在同一输入上比较。
- [ ] checkpoint、export、model order 和全部报告有 SHA-256。
- [ ] 0.6B encoder、tokenizer 大文件、embedding cache 和训练 runtime 未进入 HAR/HAP。
- [ ] decision payload 不超过 5 MiB，release HAP 增量不超过 8 MiB，并有实际构建证据。
- [ ] handoff 明确映射到现有 `LearnedRouterPort`，没有新增任务控制入口。
- [ ] feature schema 未冻结前，Runtime 没有虚构 embedding，也没有在同步 `route()` 内发起网络调用。
- [ ] reference inference CLI 可在断网环境运行。
- [ ] golden fixtures 覆盖正常、边界和 fail-closed 情况。
- [ ] 从全新 checkout 重放至少一组 fixture，结果在固定容差内。
- [ ] 仓库扫描确认无凭据、原始隐私数据和绝对本机路径。
- [ ] 未声称 ArkTS/device/shadow/canary/active 已通过。

## 11. 完成定义

独立仓库完成的最低定义是：来源和环境可重建，训练数据身份明确，至少一个非 smoke 候选 checkpoint 有三 seed 的 held-out 证据，reference inference 与 golden fixture 可离线复验，handoff 包及全部文件摘要齐全。

这只关闭“训练仓库候选产物”范围，不关闭 `harmony_agent` 的 M12/S8。主仓库仍需依次完成：

1. handoff 审核与正式 ArtifactManifest；
2. 安全导入/loader；
3. Python reference 与目标 bridge 的 decision parity；
4. 端侧或受控 embedding service 的延迟、资源、timeout/cancel 验收；
5. offline replay；
6. shadow；
7. canary；
8. harmony_agent Bench Cost@Quality Go/No-Go；
9. active 与 digest rollback 演练。

若任何阶段不能证明稳定收益，保持 deterministic baseline，不把候选 artifact 晋升为 active。

## 12. 其他 Agent 的第一轮工作指令

接手后先只读完成以下动作并汇报，不要直接安装或训练：

1. 核实独立仓库的实际工作区和 Git 状态。
2. 读取本任务书及导入的 T48 lock/spec。
3. 核实上游 commit/tree/license 和目标机器 Python/GPU/Java/磁盘状态。
4. 给出仓库初始化结果、dependency compatibility 风险、预计下载量、磁盘量和 R02/R03 执行计划。
5. 对安装依赖、下载模型和任何远程/付费调用分别列出精确目标与影响，等待项目所有者授权。

不要把 shell 命令的 `workdir` 当作会话工作区已经切换；必须明确报告工具实际打开的仓库路径。
