# 测试语料来源与许可

本目录存放个人知识库分块测试使用的**真实公开文本**与**明确标注的自撰样本**。抓取或编写日期：2026-10-02。

| 文件 | 领域 | 来源 | 许可与使用说明 |
|---|---|---|---|
| `deepseek-chat-completions.md` | 计算机 / 工程接口文档 | DeepSeek 开放平台《Chat Completions API》文档，https://api-docs.deepseek.com/zh-cn/api/create-chat-completion | 公开技术文档，节选用于测试，版权归 DeepSeek；仅作测试样例，不再分发 |
| `who-hypertension-factsheet.md` | 医学 | 世界卫生组织实况报道《高血压》，https://www.who.int/zh/news-room/fact-sheets/detail/hypertension （页面标注日期 2025-09-25） | 世卫组织公开实况报道，按原文转载用于测试，注明来源 |
| `apache-license-2.0.txt` | 法律 / 协议条款 | Apache License 2.0 全文，https://www.apache.org/licenses/LICENSE-2.0.txt | 许可文本本身允许复制分发，条款编号 1–9 适合验证长条款文档分块 |
| `engineering-readme-mixed.md` | 计算机 / 混合格式 | **自撰**，模仿真实工程 README：Markdown + 代码块 + JSON + 命令行 + URL + 版本号与日期 | 自撰内容，与本仓库 S1 骨架一致，不涉及第三方版权 |
| `project-design-zh.md` | 计算机 / 中文长文档 | **自撰**，个人知识库方案说明（数千字，分节） | 自撰内容，用于验证中文长文档分段 |
| `unicode-edge-cases.txt` | 特殊字符 | **自撰**，按 Unicode 标准构造：零宽字符、组合字符、代理对、ZWJ 表情序列、变体选择符、双向控制符、长链接 | 自撰内容，用于验证不丢字符与不拆分字符 |

## 未能纳入的真实来源（如实记录）

- `zh.wikipedia.org`、`zh.wikisource.org`：本机网络不可达（Transport error），无法抓取医学/文学条目；
- `ctext.org`：站点明确声明「不授权抓取」，按要求**未使用**其内容，因此**文学/日记类真实文本未纳入**；
- `www.npc.gov.cn` 法条页面：抓取返回站点首页而非法条正文，未能取到中文法条原文；中文「条款式长文」用例由 `apache-license-2.0.txt`（英文条款）与 `project-design-zh.md`（中文分节）覆盖。

抓取方式：`webfetch`（deveco CLI 自带），仅用于生成本目录的测试样本。
