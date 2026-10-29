# MinerU 上传 403 根因修复报告（Content-Type）

日期：2026-10-15。分支 `dev/rag`（起点 HEAD `8cac0c9`，含本工作区修复）。范围：仅 MinerU 上传/下载链路的 403 根因分析与修复。不新增权限/依赖/批次，不改 M1、不改预算，不重置已耗用补传标志，不做新的真实云上传动作。

## 1. 结论

上轮实测唯一同对象 PUT 收到的 **HTTP 403，高置信度根因是 RCP 对 `UploadFromFile` 自动补发 `Content-Type: application/octet-stream`**：MinerU 返回的 OSS 预签名上传地址在签名时不含 Content-Type（官方要求「上传文件时，无须设置 Content-Type 请求头」），RCP 默认补发的该头使签名串不一致，被对象存储以 403 拒绝。原实现只显式提供 `content-length`，没有抑制这一默认行为。

**已修复**：PUT 请求头显式传单空格 `'content-type': ' '`（RCP 官方文档：不提供或空字符串会补默认类型，「若不希望使用默认内容类型，可以传入单个空格」）。

## 2. 排除本地网络端口与代理（本轮重点关注项）

| 检查 | 结果 |
|---|---|
| 模拟器网络形态 | QEMU user-mode NAT：guest `eth0=10.0.2.15`、网关 `10.0.2.2`；无任何代理参数（`persist.net.proxy` 等查询均不存在）；`netstat` 无代理监听端口（仅系统服务端口、unix socket） |
| guest 出网连通性 | `ping mineru.net`、`ping mineru.oss-cn-shanghai.aliyuncs.com` 均 0% 丢包（ICMP 秒级 RTT 为 slirp 模拟伪影，不代表真实时延） |
| 同链路真实请求 | 同应用同 RCP 栈的 Query `GET https://mineru.net/api/v4/extract-results/batch/{batch}` 返回 HTTP 200、业务 code 0 → DNS、出口、TLS、RCP 栈均正常；若为本地端口/代理问题，GET 同样会失败 |
| 失败类别 | 403 是 HTTP 应用层响应（服务端授权拒绝），不是连接/DNS/TLS 失败；网络栈故障在应用中显示为「网络或TLS失败」类别，本现场是「鉴权或任务访问失败 · HTTP · 403」 |
| 上传地址时效 | 设备只读证据排除「URL 过期」：租约文件明文字段 `issuedAt=1792050235619`（2026-10-15 15:43:55 CST）、`remoteExpiry=expiresAt=1792136635000`（2026-10-16 15:43:55 CST，即 24h 窗口内的 `Expires` 参数），PUT 发生于 `last_query=1792070581219`（2026-10-15 21:23:01 CST），距签发约 5 小时 40 分，远在有效期内 |
| 拒绝时机 | SDK 仅供给 65,536/4,381,223 字节（一次 64 KiB 读块）即收到 403 → 服务端在读完请求体前完成头部/签名层校验并拒绝，与签名不匹配特征一致 |

结论：本地网络端口/代理不构成该 403 的成因，无需改本机网络配置或端口映射。

## 3. 官方依据

- RCP FAQ `FAQ/网络/远场通信_Remote_Communication/rcp如何实现文件上传/faqs-remote-communication-15`：`uploadFromFile` 的「请求头：参数系统默认设置，**content-type 默认 application/octet-stream**」。
- RCP API 参考 `API参考/网络/Remote_Communication_Kit_远场通信服务/ArkTS_API/rcp_数据请求/remote-communication-rcp`（RequestHeaders）：`content-type`「当此项不存在或为空字符串时，系统将根据 RequestContent 配置默认的内容类型。**若不希望使用默认内容类型，可以传入单个空格**。」
- 用户提供的 MinerU《文档解析接口文档》（公开缓存 `tool_13fbbe75a001FKf6l5lDghICAk`）：「申请的文件上传链接有效期为 24 小时」「**上传文件时，无须设置 Content-Type 请求头**」「文件上传完成后，无须调用提交解析任务接口。系统会自动扫描已上传完成文件自动提交解析任务」。

## 4. 修复内容

- `entry/src/main/ets/knowledge/infra/MineruTransportAdapter.ets`：新增文件级常量 `MINERU_UPLOAD_NO_CONTENT_TYPE = ' '`；PUT 请求头由 `{ 'content-length': ... }` 改为 `{ 'content-length': ..., 'content-type': ' ' }`，抑制 RCP 默认 Content-Type。其余不变：长度核对、超时/取消、重试政策、去敏错误分类、租约加解密与下载侧校验均未改动。
- `entry/src/test/mineru-transfer-host-cases.cjs`：PUT 头断言由 `content-type === undefined` 更新为 `=== ' '`，锁定「必须显式传单空格」契约。

## 5. 回归与证据

| 证据 | 结果 |
|---|---|
| host 全量（含传输/租约/SQLite 边界） | **212/212**，fail=0、cancelled=0；`.cache/test-logs/2026-10-15-transfer-zip-content-type-fix-8cac0c9/` |
| 静态检查 | 修改的 `.ets` 文件 `arkts_check` 无诊断 |
| 构建 | `devecocli build` 成功；缓存签名构建（脚本内）CLI 退出码 0 |
| 部署 | `dev-run-mac.sh --device 127.0.0.1:5555 --emulator "Mate 90 Pro" --product default --no-emulator`：登录预检通过、复用签名缓存、构建成功、安装启动 RC 0；`.cache/test-logs/2026-10-15-transfer-zip-content-type-fix-deploy-8cac0c9/`；签名模板字节保持 |

复现：

```bash
CAPTURE_HOST_ONLY=1 DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk RUN_CMD='node --test entry/src/test/run-host-tests.cjs' /bin/bash scripts/capture-test-log.sh transfer-zip-content-type-fix

env -u DEVECO_CLI_AUTH_SOURCE -u DEVECO_CODE_AUTH_DIR \
  DEVECO_HOME=/Applications/DevEco-Studio.app/Contents \
  DEVECOCLI_BIN=/Users/zane/.local/share/fnm/node-versions/v22.23.2/installation/bin/devecocli \
  CAPTURE_HOST_ONLY=1 \
  RUN_CMD='/bin/bash scripts/dev-run-mac.sh --device 127.0.0.1:5555 --emulator "Mate 90 Pro" --product default --no-emulator' \
  /bin/bash scripts/capture-test-log.sh transfer-zip-content-type-fix-deploy
```

本轮只读设备取证（无数据库写入、无 Token/签名地址密文读取）：

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
DB=/data/app/el2/100/database/com.example.shuvi/entry/rdb/shuvi_parse_stage_v1.db
$HDC -t 127.0.0.1:5555 shell "sqlite3 -readonly -noheader -separator '|' '$DB' \"SELECT id,window_start,queries,uploaded,upload_attempted,stage,remote FROM task; SELECT task_id,recovery_used,request_started,upload_bytes,last_query,last_action,failure_stage,failure_code FROM task_transfer;\""
$HDC -t 127.0.0.1:5555 shell "head -n 9 /data/app/el2/100/base/com.example.shuvi/haps/entry/files/knowledge_parse_v1/lease-m2-e60ec2ccc6b4ed47d6d49d326003ca16-upload"
```

上轮失败现场日志仍为 `.cache/test-logs/2026-10-15-transfer-zip-verify-real-query-first-a799981/host.log`（Query→waiting-file→PUT 403）。

## 6. 未验证项与真实验证条件

- **本修复尚未经真实 MinerU 上传复测**：原 task `m2-e60ec2ccc6b4ed47d6d49d326003ca16` 的「同对象补传」已按上轮批准边界耗用（设备侧 `recovery_used=1`），本轮不重置该标志、不申请新 batch、不无授权发起云上传，因此不宣称闭环打通。
- 要取得 `done` 与真实 ZIP，需用户在新的执行边界内选择其一：(a) 明确批准对本机现任务/原件重新走一次真实上传（涉及新 allocation 与免费额度）；(b) 用另一份非敏感测试文件走完整「提交 → PUT → done → ZIP 落盘」。完成前保持 M2-B 停止。
- 下载侧（结果 GET）本轮未改动；`full_zip_url`（`https://cdn-mineru.openxlab.org.cn/pdf/*.zip`）与代码 ROLE=RESULT 校验一致，等真实 done 后按原校验链验证。

## 7. 追加：占用死锁修复（受控「停止本机跟踪」）

日期：2026-10-16 凌晨，延续本任务。背景：用户按第 6 节流程准备新测试件（`02_第02章_模型评估与选择.pdf`，预检通过、30 页、8,656,018 字节、授权 revision 一致）时发现「提交本件测试」置灰；只读排查（设备 SQLite + 界面树）确认唯一阻塞为 `remote_slot` 未终态：旧批次 `m2-e60ec2ccc6b4ed47d6d49d326003ca16` 停在 `waiting-file`（文件从未送达、PUT 403 后本机补传机会已耗用、旧任务与加密租约已由用户删除），而「仅观察 done/failed 终态才释放」的既定规则没有出口，导致新件被无限期阻挡。用户明确批准对既有规则做受控调整后实现：

- **规则调整（保留"获确认查询"前提）**：先经「核对原云任务」由用户确认同账号并真实查询；只有当远端返回**仍为 waiting-file**、且该占用已不可能再补传（无本机任务 tombstone，或任务未确认 `uploaded` 且不处于上传中）时，界面才提供**二次确认**的「停止本机跟踪」；`pending/converting/running/done/failed` 一律不提供停止跟踪。停止后本机不再阻止提交新测试件，文案明确「不等于云端删除或取消，远端记录可能仍保留」；`retireArmed` 仅在同一轮核对后短暂有效，暂停/重开即失效。
- **持久化**：解析库 v2→v3 增量迁移（`remote_slot` 增 `retired INTEGER`），迁移失败整体回滚，未知布局仍拒绝打开；列存在性另有探测，拒绝旧布局冒用。
- **门禁**：`documentSubmitReason` 仅在 `occupancy.taskId 存在 && !terminalObserved && !retired` 时阻止新件。
- **UI**：核对后满足条件时显示「停止本机跟踪」/「继续等待」两键与说明；停止后占用区显示灰色说明。
- **回归**：host **217/217**（新增策略 1、服务 2、SQLite 迁移 2），覆盖 v1→v3 与 v2→v3、迁移失败回滚、停止跟踪持久化、未核对/未确认不生效、运行中状态不可停止。证据 `.cache/test-logs/2026-10-15-transfer-zip-occupancy-retire-8cac0c9/`。
- **构建部署**：缓存签名构建 + 安装启动 RC 0（`.cache/test-logs/2026-10-15-transfer-zip-occupancy-retire-deploy-8cac0c9/`）；设备只读核验真实迁移已执行：`user_version=3`、layout `parse-stage-slot-retire-additive-v3`、`remote_slot.retired=0`，旧 `waiting-file` 记录保留。
- **下一步（交用户手动）**：进入 解析准备 / 任务 → 核对原云任务 → 确认继续（应显示"远端仍为 waiting-file（文件从未送达）；可停止本机跟踪或继续等待"）→ 停止本机跟踪 → 重新选择测试件并提交；该次 PUT 是第 4 节 Content-Type 修复的首次真实验证，达到真实 done/ZIP 前不宣称闭环打通。

## 8. 真实闭环结果与 ZIP 结构首轮取证（2026-10-16）

用户完成手动复测：新件提交（新 original `m2-731441b8eec54bdecc16effb0192c2c2`、新 batch/task `m2-7eaa150e269374313fd776f12a2ae9fa`）→ 上传（**Content-Type 修复后 PUT 未再出现 403**）→ 查询 3 次到 `done` → ZIP 接收并落盘。本机只读复算与结构分析：

| 项目 | 结果 |
|---|---|
| 结果行 | `result-m2-7eaa150e269374313fd776f12a2ae9fa`，**8,461,084 字节**，SHA256 `548162c5bb0f6a93d0fe76d4a5a17399f87b0a882c84d4510e7c2ead5fc12a05`，received 2026-10-16 00:29:54 CST，status `UNVALIDATED`，complete/外层签名标记均为真 |
| 任务/占用 | task 阶段「结果已接收，待结构校验」、remote `done`、queries 3、uploaded=1；占用 terminal 已观察 |
| 三处 SHA256 一致 | 设备文件、`hdc file recv` 副本、SQLite 结果行完全一致；ZIP 70 项 CRC 全量通过（`crc_test=ok`） |
| ZIP 成员（70 项） | `<uuid>_content_list.json`（346 条）、`<uuid>_content_list_v2.json`（30 页）、`<uuid>_model.json`（30 页）、`<uuid>_origin.pdf`（8,654,230 B）、`full.md`（68,415 B）、`layout.json`（pdf_info 30 页）、`images/` 64 张 jpg 共 825,743 B（全部被 JSON 引用，0 孤立） |
| `content_list.json` 类型分布 | text 197 / equation 46（LaTeX 文本）/ header 28 / page_number 28 / ref_text 20 / aside_text 9 / table 7（HTML `table_body`+caption）/ chart 7 / image 4；各类均带 `page_idx`+`bbox` |
| 交叉核对 | `full.md` 11 处图片链接全部命中 `images/`；content_list 18 处 `img_path` 全部存在；layout 元数据 `_backend=hybrid`、`_effort=medium`、`_version_name=3.4.4` |
| 证据 | `.cache/test-logs/2026-10-16-m2-result-verify-detail-8cac0c9/host.log`；ZIP 副本与逐项清单 `.cache/m2-result-analysis/`（gitignore，未入库） |

**接入知识库的观察（供下一步设计，不代表已实现）**：

- 文本主源建议 `content_list.json`：`text` + `page_idx`/`bbox` 即项目要求的原页定位锚点；`equation` 为 LaTeX 段落；`table` 需表格渲染/切分策略；`header`/`page_number`/`ref_text` 属版面附属，入库前需明确过滤规则；`aside_text` 为旁注。
- `full.md` 便于快速基线，但无 bbox；`content_list_v2.json`（页分组）与 `model.json`、`layout.json` 为更细粒度备用。
- 页映射：content `page_idx 0..28`（29 页有内容）而 PDF 共 30 页；`page_number` 为书印刷页码（如 page_idx 1 显示"24"），面客引用需换算。
- `_origin.pdf` 是 MinerU 重序列化版本（8,654,230 B ≠ 本机原件 8,656,018 B），不可当字节级原作使用。
- 本轮为**结构校验**：不含表格/公式/OCR 质量判定；样例图未做视觉核对，结果应用内仍为 `UNVALIDATED`。入库链路的解包/结构适配需另立任务与验收，不因本轮成功跳过用户验收或质量抽检。
