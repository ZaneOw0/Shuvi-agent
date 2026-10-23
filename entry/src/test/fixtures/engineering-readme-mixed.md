# shuvi-knowledge-service 集成说明（自撰测试样本）

本项目为个人知识库的最小检索骨架，覆盖「原文 → 文档 → 分块 → 索引」与「问题 → 检索 → 向量 → 片段」两条链路。以下内容用于验证混合格式文档的分块行为：Markdown 标题、列表、表格、围栏代码块、JSON、命令行、URL、版本号与日期混排。

## 1. 环境要求

| 组件 | 版本 | 说明 |
|---|---|---|
| HarmonyOS SDK | 26.0.0 | API Level 26 |
| DevEco Studio | 26.0.0.821 | 本机安装目录见环境变量 DEVECO_HOME |
| Hvigor | 6.26.4 | 构建入口 |
| Node.js | 24.14.1 | IDE 配套版本，与 PATH 版本可能不同 |

安装与构建命令：

```bash
# 依赖安装（首次）
ohpm install --all

# 仅构建，不安装
devecocli build

# 一键签名 + 构建 + 安装 + 启动
scripts/dev-run.cmd
```

## 2. 配置文件

`build-profile.json5` 是仓库模板，`signingConfigs` 为空数组：

```json5
{
  "app": {
    "signingConfigs": [],
    "products": [
      {
        "name": "default",
        "compatibleSdkVersion": "26.0.0",
        "runtimeOS": "HarmonyOS",
        "targetSdkVersion": "26.0.0"
      }
    ]
  }
}
```

本地签名材料缓存在 `.local/`，脚本退出时会自动还原模板，因此 `git status` 里不应出现 `build-profile.json5` 的改动。若发现该文件被改动，请执行 `git checkout -- build-profile.json5`。

## 3. 接口返回示例

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "documentId": "doc-3-1790938065692",
    "chunkCount": 5,
    "indexVersion": "pseudo:hash:v1:64",
    "createdAt": "2026-10-02T18:47:45+08:00",
    "embedding": {
      "dim": 64,
      "space": "pseudo:hash:v1:64",
      "distanceMetric": "cosine"
    }
  }
}
```

## 4. 状态码

- `0`：成功。
- `801`：能力不支持。实测中，`StoreConfig.vector = true` 建表全部返回该码。
- `14800021`：SQLite 通用错误。实测中，含 `customtokenizer` 的 FTS5 虚表建表返回该码。
- `1021201008`：向量阈值高于分档阈值。
- `1021200001`：数据库损坏。

## 5. 相关链接

- 项目仓库：https://github.com/example-org/shuvi-knowledge-service
- 接口文档：https://api-docs.deepseek.com/zh-cn/api/create-chat-completion
- 带查询参数的长链接示例：https://example.com/api/v2/knowledge/search?query=%E9%AB%98%E8%A1%80%E5%8E%8B%E7%9A%84%E5%8D%B1%E9%99%A9%E5%9B%A0%E7%B4%A0&topK=5&channel=vector,keyword&embedSpace=pseudo%3Ahash%3Av1%3A64&includeArchived=false&since=2026-01-01T00%3A00%3A00%2B08%3A00&until=2026-12-31T23%3A59%3A59%2B08%3A00&requestId=7f3c9a12-4b8e-4d21-9f60-2c5ab1e0d77a&trace=9c1f7b2a8d4e6f0b3a5c7d9e1f2a4b6c8d0e2f4a6b8c0d2e4f6a8b0c2d4e6f8a
- 超长无参数链接：https://cdn.example.com/assets/2026/10/02/9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a0/document-archive.tar.gz

## 6. 变更记录

- 2026-09-26：合并 main 的工程更新（合并提交 9260eb3）。
- 2026-10-02 18:47：S1 机制验证，导入 4 篇样例，命中 5 块，倒排 5 行，删除后对账 0 孤儿。
- 2026-10-02 19:39：补充分块 host 测试，31 项通过，修复英文句号未纳入切分边界的问题。

## 7. 注意事项

1. 分块上限为 512 字符，重叠约 10%，切分优先段落、其次中文与英文句末标点、最后硬切。
2. 索引与向量不进同步，各设备在本机重建。
3. 索引链路中的虚表写入必须与普通表分开提交，否则写入不落库。
4. 能力探测不能只看 `isVectorSupported()` 与 `isTokenizerSupported()`，必须实际建表并写入一次。
