# MinerU 上传至 ZIP 接收修复实施报告

日期：2026-10-15。实现状态：**COMPLETED（仅 U001–U005）**。真实上传、云端 done、设备 ZIP 落盘及可见进度验收：**未执行、未宣称通过**。

## 授权与执行边界

- 采用 `transfer-zip-fix-tasks.md`，沿用已批准 M2-A 契约及本轮例外，不重复阶段 1–3，不扩展到解包、内部 schema、索引、原生预览、embedding、M3 或同步。
- `HOME=/Users/zane`，`CONFIG_ROOT=/Users/zane/.local/share/deveco/`；已读取实现工作流、spec、plan、任务清单、AGENTS 与相关源码。根 build-profile 模板有效，没有 scaffold、安装或升级依赖。
- 起点 HEAD `a799981`、分支 `dev/rag`。保留工作区已有 Token 保存修复及其他用户改动；无 commit、push、部署、设备操作、真实 MinerU 请求、凭据读取或用户目录扫描。
- 已加载 deveco-cli、hmos-arkui-develop-skill；本阶段明确不运行 checker/build/run/UI。U006–U008 保持未勾选，由下一阶段负责。

## 按阶段结果

| 阶段/任务 | 状态 | 结果 |
|---|---|---|
| Setup / U001 | 完成 | 文档/SDK 核对，先建立 7 项 RED 服务回归；已有收包登记失败回归保留 |
| Foundational / U002 | 完成 | 真实生产 RCP 适配器长度、短读、摘要/EOF、空 PUT 响应、超时、异步写盘与去敏错误修复；不凭推测改 GCM 格式 |
| User Story / U003 | 完成 | 原 batch Query-first、一次同对象补传检查点、累计查询、超时记录、连续轮询与结果事务；v1 增量兼容 |
| User Story / U004 | 完成 | 真实字节与阶段、查询时间、结果路径摘要、失败总览；V1 观察刷新与前台导航连续性 |
| Polish / U005 | 完成 | 212/212 host、保护摘要、独立报告及总 spec 增量；没有跨入验证阶段 |
| Verification | 跳过 | 超出本 subagent 范围，不执行、不标记 |

## 源码确认的缺陷与修复

1. **本地预检即消耗上传尝试**：原服务在 adapter 验原件、解租约、打开文件之前置 `uploadAttempted=true`。现在由 adapter 完成本地预检后调用异步 `onUploadStarting`，先持久化上传意图，再调用 SDK PUT。`uploadRequestStarted` 单独表示已到 SDK 调用边界，不等于对端收到或确认成功。
2. **旧任务 waiting-file 无法补传**：原条件只允许 `!uploadAttempted`。现在恢复先 Query 原 batch；明确 waiting-file、同原件 hash/version/Grant/credential revision、原加密租约仍有效时，才允许同对象完整 PUT。旧 `uploadAttempted` 不清零；`recoveryUploadUsed` 在补传前落盘，未知/中断/重开不再补传。没有新申请、data_id 或 batch 的恢复分支。
3. **超时错误被吞**：原 timer 置 invalid 后，service catch 因 invalid 跳过记录。现在区分 TIMEOUT、PAUSE、INVALIDATED；超时依然保存去敏阶段/数值 code/错误与原身份，迟到数据/结果不能发布。
4. **SDK 读取的长度/EOF 边界**：原 reader 每回最多返回 64 KiB，即使 SDK 请求更大；现按 SDK 请求长度分段填满，处理短读，明确 Content-Length，结束时核对供给实长、文件实长、SHA256 和额外 EOF。是否为旧设备上的实际失败原因仍需真实 RCP 验证，不能由 host 推定。
5. **空 PUT 响应被额外 body-event 依赖阻塞**：PUT 使用 fetch 成功结束、HTTP 200、完整源读取与摘要核对；不再强求空响应触发 body-end。控制 JSON/结果 GET 仍要求结束确认。未把 HTTP 200 或供给完字节当解析 done。
6. **下载异步完成与真实字节**：fetch 完成前等待接收回调 Promise；sink 单写并等待磁盘队列，以真正完成的 fileIo.write 字节计进度，写前硬限 30 MiB。仍执行外层 ZIP 起始/完整结束记录、fsync、SHA256 读回、rename 后才登记结果；登记失败不公开 Received，保留 owned 清理账本。
7. **前台导航清理破坏活动认证**：`clearInput` 现在只发布密码清理世代，不调用 Credential 的认证失效；Index 关闭解析二级视图不再暂停。显式暂停、关闭解析、后台/销毁、凭据变更路径仍取消请求、清认证并保留检查点；不引入后台执行能力。
8. **进度不可见/容易不刷新**：动作开始立即发布 busy；阶段/Query/字节有快照通知，任务 rows 在原件确认区之前。任务使用 UI 专属 V1 `@Observed` presentation 与 `@ObjectLink` 子组件，稳定 task ID 不会让普通嵌套对象停在初始值。密码反馈与网络消息分开，不互相遮盖。

## 持久化与兼容

仍用原 `shuvi_parse_stage_v1.db` 和 `knowledge_parse_v1`，不换库/目录。七张 v1 表及其显式列完整保留，只增 `task_transfer` 表和布局 v2 标识，包含一次补传耗用、SDK 调用边界、上传/下载字节、已知 HTTP 总长、最后查询时间、最后动作和去敏失败阶段/code。

迁移以单事务建附加表、从旧 task 建扩展记录、更新布局标识；提交后版本终结可重入。旧 `upload_attempted` 和 batch/Grant/租约不修改，旧记录的实际 PUT 发出状态明确未知，不能反推从未联网。迁移失败回滚，未知布局/缺关联拒绝打开，不删库修复。累计 queries 不再限制为单窗口 90；单次恢复窗口另计最多 90 次、15 分钟。原历史被旧版本重置过的次数不能还原或声称为零历史。

SQLite host 覆盖旧行字节保持、v2 重开、耗用标志/累计次数持久化、迁移失败回滚、未知布局拒绝；**不是 ArkData 设备迁移通过证据**。M1 模型/Ports/Service/数据库/文件布局未改。

## 官方依据

- 用户提供的 MinerU《文档解析接口文档》“本地文件批量上传解析”“批量获取任务结果”：原字节 PUT、24 小时上传窗口、无须 Content-Type、自动提交、原 batch 查询、done 的 full_zip_url、running 可选页数。仅读取公开正文，不执行示例或下载样本。
- 重新 `devecocli docs read`：`API参考/网络/Remote_Communication_Kit_远场通信服务/ArkTS_API/rcp_数据请求/remote-communication-rcp`，并读本机 API26 `@hms.collaboration.rcp.d.ts` 的 ReadFile、UploadFromFile、IncomingDataCallback、HttpEventsHandler、Request.method/headers 等声明。
- 重新读取 `开发指南/安全/Crypto_Architecture_Kit_加解密算法框架服务/加解密/使用AES对称密钥加解密_ArkTS/crypto-aes-sym-encrypt-decrypt`：密文末尾 16 字节 tag。现有租约 9 字段 AAD、磁盘头与 tag 拆分自洽；fresh binding.issuedAt 不覆盖磁盘 AAD。没有证据证明 GCM 格式错误，未改其 wire。host 用 Node AES-GCM 模拟文档约定，不能当 Crypto Kit 实测。

## 回归与证据

所有执行均通过 `/bin/bash scripts/capture-test-log.sh`、`CAPTURE_HOST_ONLY=1` 落盘，没有设备访问。脚本当前无执行位，初次直接调用权限拒绝后改用 Bash；没有改脚本权限或内容。

| 证据目录（均在 `.cache/test-logs/`） | 结果 |
|---|---|
| `2026-10-15-transfer-zip-red-a799981` | 定向新增服务 7/7 RED；含新请求前检查点契约缺失 |
| `2026-10-15-transfer-zip-adapter-a799981` | 8/9，通过前发现 host GET double 错误地要求 headers 存在；修 double 的可选读取，未弱化生产校验 |
| `2026-10-15-transfer-zip-adapter-green-a799981` | 9/9 GREEN |
| `2026-10-15-transfer-zip-service-a799981` | 服务定向 GREEN |
| `2026-10-15-transfer-zip-service-store-a799981` | 52/55；3 项迁移用例的 fixture INSERT 占位多一列，修 fixture 数量，不改生产表 |
| `2026-10-15-transfer-zip-store-green-a799981` | 3/3 GREEN |
| `2026-10-15-transfer-zip-full-first-a799981` | 200/200 GREEN |
| `2026-10-15-transfer-zip-full-expanded-a799981` | 210/210 GREEN |
| **`2026-10-15-transfer-zip-final-a799981`** | **212/212 GREEN，fail=0、cancelled=0** |

最终 212 = 原有 180 + 新服务 11 + 生产传输/文件/租约 host 边界 17 + 生产 Repository/SQLite host 边界 3 + V1/导航源码契约 1。原 180 保留；原保存视图审计的反馈表达式更新为两个独立 Text，继续约束反馈可见/先捕获输入后清理。生产装配仍是真实 Asset/RCP，测试 doubles 只在 host loader，不打包。

最终日志含已跟踪/未跟踪源码 SHA256、runner/loader SHA、SDK 转译器版本、golden 和六 fixture SHA；capture meta：HEAD `a799981`，Node `v22.23.2`，SDK TypeScript `4.9.5`，dirty 22，测试时工作区指纹 `deb5aea33434a2db1c48ef1d9d5fdde2311369e5be36ef3fdbb07a10d6edf85f`。随后只有报告/任务/总 spec 文档变化，不将最终文档状态冒称相同测试指纹。保护审计还验证 M1 核心、脚本和依赖模板摘要未变。`git diff --check` 无输出。

复现最终 host：

```bash
CAPTURE_HOST_ONLY=1 DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" RUN_CMD='node --test entry/src/test/run-host-tests.cjs' /bin/bash scripts/capture-test-log.sh transfer-zip-final
```

## 文件清单

修改生产：`knowledge/application/DocumentParseService.ets`、`knowledge/domain/DocumentParseModels.ets`、`knowledge/infra/{MineruTransportAdapter,MineruCredentialStore,DocumentFileAdapter,DocumentParseRepository,DocumentParseAssembly}.ets`、`knowledge/ui/DocumentParseView.ets`、`pages/Index.ets`。

修改测试：`entry/src/test/DocumentParseServiceCases.ets`、`run-host-tests.cjs`、`mineru-host-loader.cjs`。新增：`mineru-transfer-host-cases.cjs`、`mineru-repository-host-cases.cjs`。原未提交 `MineruCredentialStoreCases.ets` 继续保留，未覆盖其内容。

修改文档：本报告、`transfer-zip-fix-tasks.md`、总 `specs/02-个人知识库问答.md` 增量。未触碰用户未审核 paste 脚本、已有 Token 报告、M1/用户 PDF/设备库、签名模板或私有配置。

## 下一阶段交接与停止条件

1. U006 先 checker/build，再正常 macOS 缓存签名部署同一已授权设备，保留凭据和所有资料；host 转译不能证明 ArkTS/ArkUI 可构建或设备可用。
2. U007 只处理现 task `m2-e60ec2ccc6b4ed47d6d49d326003ca16`，原件身份沿本任务清单，不输出完整 batch 或秘密。进入“解析准备 / 任务”点该任务“继续查询同一任务”并确认既有授权。代码第一步查询原 batch；done 收包，pending/converting/running 继续查询；waiting-file 才核原租约和 hash/Grant 后允许一次完整补传。
3. 旧租约可能已失效、缺密钥或无法认证，这些在本阶段没有设备实测。任何失效/unknown/身份不符/超预算都 STOP，保留原身份和错误，不能申请新 batch。若失败，应报告具体阶段与 code，不能为取得“成功”清耗用标志、放宽主机、绕过 App 或读 Token。
4. U008 观察任务区的本次 SDK 供给/PUT 确认、云阶段/页数、累计查询与最后响应、ZIP 实写；前台切一级再返回应继续，后台/显式暂停应停。成功总览须来自 result 行，核对物理文件、实长/SHA256/接收时间及原件任务关联，重开一致，不能拿本报告的 host 构造边界 bytes 当样包。
5. 达到“解析服务成功，ZIP 已保存，内容待结构校验”后交用户本人验证并停止；未验证通过前不解包、不继续 M2-B。UI、真实网络、Crypto/Asset/RCP/ArkData 设备行为及实际 ZIP 闭环均仍待验证。

无实施阻塞任务；不把未进入验证阶段列为已实现功能的运行通过。必要联动和附加表/host 文件均在批准的最小扩展范围，无新增权限/依赖/外部服务，无降低隐私、预算、原生定位或结果结构门槛。
