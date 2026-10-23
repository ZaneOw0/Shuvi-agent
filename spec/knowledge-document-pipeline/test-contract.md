# M2-A host 测试契约 v1

已批准实现范围 T001–T031。新端口假值仅非秘密单元测试，不是真实 Token、Office 文件、MinerU 产物或实际免费额度。控制 JSON 字段来自官方文档，不读取包内 schema。没有下载、真实联网/连接测试、设备写入或自动扫描。

| 范围 | 冻结用例 | 必须结果 |
|---|---|---|
| 设置 | CRUD、锁定、存储失败、UTF-8超1024、换行/控制字符 | 默认关；成功才配置；无公共secret；更新/删除撤销Grant |
| 原件 | 四格式、实长/哈希/版本、PDF1/50/51页、未知能力、OOXML目录异常 | 未过预检零请求；保留副本，不送M1 |
| 同意 | 完整文件/内嵌图、非敏感测试、未知隐私、免费、接收/参数/凭据版本 | 任一缺项/变更零外发；普通个人资料阻止 |
| 预算 | 20/40/100MiB、3件、30/200MiB包、20/30MiB临时 | 边界接受、加一拒绝；待清理计入，不删旧件 |
| JSON | 严格字段/关键重复/ID/安全整数/数组/状态、标准转义与数值 | 1MiB/16深/4096tokens/16KiB字符串；无parse断言/正则整文 |
| 接收方 | 角色精确主机/路径、443、userinfo/IP/fragment/编码混淆/3xx | Token仅控制面，未知host和redirect拒绝 |
| 任务 | 六状态、检查点/身份租约先落盘再PUT、singleitem | data_id不幂等；未知不重提；done不算包接收 |
| 流式 | chunk超限/未知长度/中断/取消/ZIP外层完整结束/实长/摘要 | 写前硬cap；仅UNVALIDATED，不解压/CRC/索引 |
| 恢复 | 429/鉴权/过期/15min/90query/pause/delete/revision/迟到 | 查已有batch；slot不释放；真实终态才释放；最小tombstone |
| 隔离 | 原96、六fixture/golden、M1库/wire/历史 | SHA保持；M2不依赖 M1 normalize/index/repository |

fixture在DocumentParseCases以有界字符串构造，ID用unit-data-1/unit-batch-1。状态白名单waiting-file/pending/converting/running/done/failed。成功目的地仅官方文档精确主机/前缀，虚构无秘密路径，不执行。没有ZIP/Office二进制样本。测试先留业务RED再GREEN，转译失败不算RED。host只转译纯模块和测试，不装配SDK/UI；每轮capture落盘并分层报告。
