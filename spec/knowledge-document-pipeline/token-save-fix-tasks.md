# Tasks: MinerU Token 保存链路修复与真实验证

**日期**：2026-10-14。
**基线提交**：`a799981 feat(knowledge): 增加 MinerU 安全配置与复杂文件转发链路`；已按用户要求先提交一次，未推送。修复作为后续未提交变更，不再次自动commit。
**授权例外**：用户同意沿用M2-A契约，跳过重复需求/架构/任务审核，直接限定修复、回归、构建与设备验证。报告在本目录独立命名，旧M2-A报告保留。

## 现象与已核对事实

用户在模拟器输入Token后点击保存，仍未配置且没有错误提示。生产装配使用真实MineruCredentialStore/AssetStoreKit及MineruTransportAdapter/rcp，不是生产Mock；host现用假凭据端口，不能证明真实平台保存。

官方新增关键资产文档和SDK均说明设置IS_PERSISTENT属性需要STORE_PERSISTENT_DATA权限，默认false；现addSecret显式设置false但应用无该权限，属于确定的SDK调用风险。应省略默认属性而不扩权限。实际设备根因与保存状态仍须运行证据，不能只据源码宣称已修好。另需检查按钮/回调、错误传播、输入清理和状态刷新，用户反馈无错误提示不能忽略。

## 范围与安全边界

仅修凭据存取、状态反馈及发现的直接阻塞，不添加权限/新功能，不改M1原件/schema/wire/数据。凭据仍Asset SECRET、DEVICE_UNLOCKED、SyncType.NEVER、非群组/不卸载持久，不明文降级。错误仅阶段/稳定分类/真实数值code，不能输出Token/认证头/原始响应/签名地址。

用户批准只查询生产别名非秘密属性；真实Asset CRUD用独立测试别名及非秘密值，之后只清该测试别名，不覆盖/删除现有用户Key。真实解析仅由应用的安全适配器内部消费Key，不能将Key读取到agent上下文、shell参数或脚本文件。

用户明确授权读取本机`.cache/m2-input/user-pdf/`内PDF并交MinerU解析。当前列出11份，选一份符合20MiB/50页及免费额度限制的文件做一次真实联调，不批量提交。优先必要元信息/页数/哈希，报告不复制正文。没有可用生产凭据、选择器可见文件或安全调用路径时如实阻塞，不扫描其他目录/捏样本/重试此前禁止的HDC写入，不运行未审核的paste-to-emulator用户脚本。

## Implementation

- [X] F001 核对SDK、按钮→service→真实Asset→属性状态链，建立可复现的无秘密回归及错误反馈期望，目标 /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/test/DocumentParseServiceCases.ets
- [X] F002 修复默认持久属性/真实平台参数错误及去敏code保留，核对同helper的Token与租约密钥行为，不增加STORE_PERSISTENT_DATA，目标 /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/MineruCredentialStore.ets
- [X] F003 修复保存动作/异步状态/界面错误与输入清理的直接问题，不能假已保存或吞错误；按真实需要最小修改service/view并host留证，目标 /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/DocumentParseService.ets
- [X] F004 完整host回归保留原148与新用例，记录SDK风险/实际修复/未完成设备和API验证，不运行构建或设备操作，目标 /Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-document-pipeline/token-save-fix-implementation.md

顺序F001→F002→F003→F004。仅spec-implementation执行，发现不属于凭据保存的其他范围先记风险；不擅自增加诊断入口或写生产Key。

## Verification

<!-- verification_scope: build+ui -->

**本轮验证结案（2026-10-15，INCOMPLETE）**：以下[X]仅表示唯一验证委派及结果记录结束，不表示全部验收通过。F005实际构建1次并正常缓存签名安装启动成功，host180/180；F006自动工具两次初始化失败，仅CLI观察修复版页面未配置，无本轮保存尝试或真实独立alias CRUD证据；F007已对授权目录一件PDF作本机大小/13页/哈希预检，但因生产未配置和agent不得代填凭据，远端任务0。没有覆盖/删除/读取生产Key、上传文件或执行后续API。权威分层结果以token-save-fix-verification.md为准，不能标实际保存/认证已成功。

- [X] F005 静态检查后构建、正常缓存签名部署到唯一Mate90Pro/127.0.0.1:5555，失败限定修复；不清库/卸载/强签/登录/读签名秘密，目标 /Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-document-pipeline/token-save-fix-verification.md
- [X] F006 真实Asset独立非秘密测试别名CRUD与生产属性状态、应用保存反馈/刷新/重开可达性验证；不覆盖现Key或截图密码，工具失败不能假UI通过，目标 /Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-document-pipeline/token-save-fix-verification.md
- [X] F007 用用户授权目录一件符合预算PDF在应用内部实际请求MinerU，确认真实申请/上传/查询/包接收或精确失败阶段；不得把Mock/HTTP200/本机保存当鉴权或文件解析成功，缺条件明确未完成，目标 /Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-document-pipeline/token-save-fix-verification.md

spec-verify仅本次新修复委派一次；初build最多10次，故事验证每项最多初次加两次限定修复再验，故事修复后最终各一次无修复复验，无故事修复则跳最终。F006与F007两故事各一条复合用例，生产属性结果不能代替真实认证有效性；同alias查ATTRIBUTES不得触SECRET。所有host/build/平台/真实API证据分别落盘并去敏，总spec只追加真实结论，旧INCOMPLETE不覆盖。

## 交付

明确回答：是否调用真实SDK、保存是否成功、UI为何仍未配置、错误属于哪层、真实API是否实际成功。不能要求用户把Token发到对话；如果真实Key未保存且agent不能代填，则修复后让用户重填，再报告本轮API未完成，而非绕过安全边界验证。
