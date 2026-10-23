# Tasks: MinerU 真实上传至 ZIP 落盘闭环修复

**日期**：2026-10-15。
**批准范围**：用户要求先完成真实云上传→查询→真实ZIP接收并交本人验证，之后才继续M2其他内容。已明确同意沿用M2-A契约、跳过重复阶段1–3审核；同意前台页面切换持续处理，显式暂停/关闭解析/凭据变更/应用退后台仍暂停。当前无commit/push授权。
**目录**：沿用已批准 `spec/knowledge-document-pipeline/`，本次独立任务/实施/验证报告保留旧M1/M2和Token修复历史。

## 当前证据与官方合同

本机只读快照：task `m2-e60ec2ccc6b4ed47d6d49d326003ca16`，original `m2-87f6c3ea33f596b11ec313199476645b`，原件4,381,223字节/24页/SHA256 `29470c866abd6ce0a107ab316cbd99873dd0003b5c61eda2a69d4dce30a0000a`。已有batch；stage暂停、checkpoint等待文件、remote waiting-file、queries0、uploaded=false/uploadAttempted=true，result表空，原件存在、完整与临时结果不存在。只是最后记录，不证明当前服务端终态或历史从未查询。

2026-10-15重新读取用户提供的官方MinerU《文档解析接口文档》：本地精准解析为POST /api/v4/file-urls/batch→PUT原件到返回地址→服务自动提交→GET /api/v4/extract-results/batch/{batch_id}→done时full_zip_url下载ZIP。无需另建解析任务；上传无须Content-Type；单文件入口extract/task不接直接上传。本轮只精准API，不混轻量Markdown接口。所有不清楚的上传/下载语义先查官方文档/实际SDK，不凭记忆猜。

## 恢复及权限边界

- 生产Token只在应用内部安全适配器使用，agent不读取SECRET、认证头、签名地址明文、私有签名配置或密码截图。不替换/删除用户Key，不减弱TLS/角色接收方/预算。
- 优先查询原batch：done直接收包，pending/running/converting继续查；只有当前远端明确waiting-file、原上传地址仍有效、同原件哈希/版本/授权匹配时，用户已允许对**同一对象完整PUT补传一次**。不是新batch/新解析任务，不重置旧上传标志冒称未发。
- 地址失效、状态不明、身份不符或超预算就停止并准确报告，不自动申请新批次、不批量11PDF，不清库/卸载或重试被禁止的HDC文件写入。
- 真实闭环在现已授权Mate90Pro/127.0.0.1:5555执行；保留M1两份资料、六文本副本、已保存PDF与现有task/batch，升级新增字段需可恢复兼容而非切空库。
- 原预算20MiB/50页、30MiB结果包、120秒单请求、15分钟单等待窗口、单远端占用和免费额度限制保持。本轮结果仍UNVALIDATED，不解压、不索引、PDF高亮/向量化/Office扩展均暂停。

## Implementation

- [X] U001 核对官方上传/Query/结果合同和SDK文件上传/回调/GCM契约，先为上传前失败/真正传输未知/超时可见/同批次一次补传/前台清输入不取消请求/收包落盘建立回归，目标 /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/test/DocumentParseServiceCases.ets
- [X] U002 修复真实传输与加密租约实际阻塞，核验PUT完整长度/源哈希/响应结束及下载异步等待/真实字节上限，保留去敏错误阶段和数值code，目标 /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/MineruTransportAdapter.ets
- [X] U003 实现先查原批次、获准同对象仅一次补传/持久化防重复、连续查询与结果发布；取消/超时分别有明确状态/失败记录，恢复不清历史计数伪装新任务，旧v1记录兼容，目标 /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/DocumentParseService.ets
- [X] U004 补齐上传字节/云真实阶段与页数/最后查询时间和次数/下载实字节/ZIP落盘路径大小摘要/成功或失败总览；前台切页只清密码、不隐式暂停网络，后台/显式暂停仍生效，目标 /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/ui/DocumentParseView.ets
- [X] U005 全量host/真实SDK适配边界回归保留原180和fixture字节、记录确定源码缺陷与待设备验证；增量总spec并写独立实施报告，不build/run/真实联网，目标 /Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-document-pipeline/transfer-zip-fix-implementation.md

顺序U001–U005，仅spec-implementation执行。必要联动具名Models/Ports、Credential/Files/Repository/Index/生命周期；不要为了演示添加生产Mock、公开诊断后门或绕过App用外部curl读Key。真实新平台问题仅本轮转发范围有限修复。

## Verification

<!-- verification_scope: build+ui -->

**本轮验证结案（2026-10-15，FAIL，交付门槛未达成）**：以下[X]只表示一次验证委派和结果记录结束，不表示任务全部通过。U006构建2次后签名部署成功，修复后host212/212；U007通过应用Query原batch观察waiting-file后执行唯一获准同对象补传，PUT返回HTTP403，SDK供给65536/4381223字节但未确认上传，未观察done、未下载ZIP；U008错误/字节/累计查询/重开检查点可见，活跃切页和成功结果路径未验，INCOMPLETE。403确切原因未证实，不认定Token错误或租约过期。补传机会已耗用，停止云动作、不新建batch、不继续M2-B；最终权威报告为transfer-zip-fix-verification.md。

- [X] U006 静态检查后构建并经macOS脚本正常缓存签名部署，保留Token和所有资料/批次；最多10初构建，失败按实际SDK诊断有限修复，目标 /Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-document-pipeline/transfer-zip-fix-verification.md
- [X] U007 用应用真实安全凭据先Query现batch，按批准条件同对象PUT仅一次、轮询至真实done并下载ZIP；取真实HTTP/业务阶段、字节/哈希与物理落盘/result表关联证据，不把fake/旧包/HTTP200当解析完成，目标 /Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-document-pipeline/transfer-zip-fix-verification.md
- [X] U008 验证UI可见进度、前台切页持续与最终成功/失败，重开后结果记录和包保持；交付用户核对方法，至此停止M2后续，不解包建索引或向量化，目标 /Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-document-pipeline/transfer-zip-fix-verification.md

验证只委派spec-verify一次，内部顺序verify/fix最多每故事3次；故事内修复后最终全故事各一次无修复复验，无故事修复跳最终。真实UI工具不可用要准确记录，但可以通过实际CLI安全点击/滚动/非输入树白名单观察与只读任务/文件元数据取得人工式设备证据，不能编造verify_ui ID或把未配置模型当产品失败。

两故事：一为当前batch真实Query→按条件补传→done→本机真实ZIP；二为前台切页进度/最终状态与重开落盘一致性。agent获本轮真实现任务Query/一次PUT/结果GET授权，不得因host已过跳真实网络。若旧地址失效就明确阻塞交用户，不扩权新申请。所有日志落盘只去敏阶段/码/ID摘要/实长/hash，不secret/完整URL/正文。

## 交付门槛

至少一份本任务的真实服务done与下载结果包满足外层签名/传输完成/实长/SHA256、物理文件存在和结果表关联，UI明确“解析服务成功、ZIP已保存、内容待结构校验”，然后停下交用户验收。达不到须写明精确失败阶段与后续所需条件，不能提前宣称打通。用户亲自验证通过前不继续M2-B。
