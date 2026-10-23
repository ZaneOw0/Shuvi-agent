# Chat Completions API

来源：DeepSeek 开放平台文档 https://api-docs.deepseek.com/zh-cn/api/create-chat-completion （节选，2026-10-02 抓取）

POST

## /chat/completions

根据输入的上下文，来让模型补全对话内容。

## Request

- application/json

### Body

**messages** object[] required

对话的消息列表。`Possible values:` `>= 1`

- System message：`role` 取值为 `system`；`content` 为 system 消息的内容；`name` 可选，用于区分相同角色的参与者。
- User message：`role` 取值为 `user`；`content` 可以是字符串，也可以是内容块数组（可携带图片）。内容块类型 `text` 时使用 `text` 字段；类型 `image_url` 时使用 `image_url.url`，支持 `http(s)` URL（最多 8192 个字符）或 base64 编码的 data URL（`data:image/jpeg;base64,...`），支持格式 JPEG、PNG、GIF、WebP；`detail` 可选值为 `low`、`high`、`original`、`auto`，其中 `low` 会把图片缩小到 512x512。类型 `file` 时使用 `file_id`（形如 `file-api-...`，与 `file_data` 互斥）或 `file_data`。
- Assistant message：`role` 取值为 `assistant`；`content` 可为 null；`prefix` 为 Beta 参数，设为 true 时模型会以该消息提供的前缀开始回答，使用该功能必须把 `base_url` 设为 `https://api.deepseek.com/beta`。
- Tool message：`role` 取值为 `tool`；需要 `tool_call_id` 与 `content`。

**model** string required

`Possible values:` `deepseek-flash`、`deepseek-v4-pro`

**thinking** object nullable

- `type`：`enabled` 或 `disabled`，默认 `enabled`。
- `reasoning_effort`：`none`、`low`、`high`、`max`。`none` 关闭思考模式；默认强度为 `high`；出于兼容考虑 `minimal` 映射为 `low`，`medium`/`xhigh` 映射为 `high`。

**max_tokens** integer nullable

限制一次请求中模型生成 completion 的最大 token 数，取值范围 1 到 384K（393216）。未设置时，非思考模式默认 8K，思考模式默认 64K（`reasoning_effort` 为 `max` 时为 128K）。

**response_format** object nullable

设置为 `{ "type": "json_object" }` 以启用 JSON 模式。注意：如果 `finish_reason="length"`，说明生成超过 `max_tokens` 或超过最大上下文长度，消息内容可能被部分截断。

**stop** string | string[] nullable

最多包含 16 个 string 的 list，遇到这些词时停止生成。

**stream** boolean nullable

设置为 true 时以 SSE（server-sent events）形式流式返回，消息流以 `data: [DONE]` 结尾。

**stream_options** object nullable

必须与 `stream: true` 一起使用，否则返回 `400` 错误。`include_usage` 设为 true 时，流式返回的所有块都包含 `usage` 字段，除最后一个块外该字段为 null。

**temperature** number nullable

采样温度，取值 0 到 2，默认 1。更高的值（如 0.8）输出更随机，更低的值（如 0.2）更集中。思考模式下不生效。

**top_p** number nullable

默认 1。取值必须大于 0 且不超过 1。该参数仅在思考模式下生效，有效取值范围 0.95–1.0，低于 0.95 的取值按 0.95 处理；非思考模式下恒为 1.0。

**tools** object[] nullable

目前仅支持 `function`。`function.name` 必须由 a-z、A-Z、0-9 组成，或包含下划线和连字符，最大长度 128 个字符。`function.parameters` 以 JSON Schema 描述。`strict` 默认为 false，设为 true 时使用 strict 模式确保输出符合 schema（Beta）。

**tool_choice** string | object nullable

`none` 表示不调用 tool；`auto` 表示模型可自行选择；`required` 表示必须调用。当没有 tool 时默认 `none`，有 tool 时默认 `auto`。思考模式下不支持 `required` 与指定具体 tool，否则返回 `400`。

**logprobs** boolean nullable；**top_logprobs** integer nullable，取值 ≤ 20。

**user_id** nullable

可选字符集为 `[a-zA-Z0-9\-_]`，最大长度 512，请勿包含用户隐私信息。可用于内容安全处理、KVCache 缓存隔离与调度隔离。

**frequency_penalty** deprecated；**presence_penalty** deprecated。传入不再产生效果。

## Responses

### 200 (No streaming)

返回一个 `chat completion` 对象：

```json
{
  "id": "930c60df-bf64-41c9-a88e-3ec75f81e00e",
  "choices": [
    {
      "finish_reason": "stop",
      "index": 0,
      "message": {
        "content": "Hello! How can I help you today?",
        "role": "assistant"
      },
      "logprobs": null
    }
  ],
  "created": 1705651092,
  "model": "deepseek-flash",
  "object": "chat.completion",
  "system_fingerprint": "fp_7a09fdf9c2",
  "usage": {
    "completion_tokens": 10,
    "prompt_tokens": 16,
    "total_tokens": 26,
    "prompt_tokens_details": {
      "cached_tokens": 0
    },
    "prompt_cache_hit_tokens": 0,
    "prompt_cache_miss_tokens": 16
  }
}
```

`finish_reason` 取值：`stop`（自然停止或遇到 stop 序列）、`length`（达到上下文或 max_tokens 限制）、`content_filter`（触发过滤策略）、`tool_calls`（进行了工具调用）、`insufficient_system_resource`（推理资源不足）、`aborted`（被中断）。

### 200 (Streaming)

返回包含一系列 `chat completion chunk` 对象的流式输出，Content-Type 为 `text/event-stream`：

```
data: {"id": "1f633d8bfc032625086f14113c411638", "choices": [{"index": 0, "delta": {"content": "", "role": "assistant"}, "finish_reason": null, "logprobs": null}], "created": 1718345013, "model": "deepseek-flash", "object": "chat.completion.chunk"}
data: {"choices": [{"delta": {"content": "Hello", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "object": "chat.completion.chunk"}
data: {"choices": [{"delta": {"content": "?", "role": "assistant"}, "finish_reason": "stop", "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "object": "chat.completion.chunk", "usage": {"completion_tokens": 9, "prompt_tokens": 17, "total_tokens": 26, "prompt_cache_hit_tokens": 0, "prompt_cache_miss_tokens": 17}}
data: [DONE]
```

调用示例（OpenAI 兼容）：

```python
from openai import OpenAI

client = OpenAI(api_key="<DeepSeek API Key>", base_url="https://api.deepseek.com")

response = client.chat.completions.create(
    model="deepseek-flash",
    messages=[
        {"role": "system", "content": "你是一个专业的助手"},
        {"role": "user", "content": "你好"},
    ],
    stream=False,
)

print(response.choices[0].message.content)
```

```bash
curl https://api.deepseek.com/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${DEEPSEEK_API_KEY}" \
  -d '{
        "model": "deepseek-flash",
        "messages": [
          {"role": "system", "content": "You are a helpful assistant."},
          {"role": "user", "content": "Hello!"}
        ],
        "stream": false
      }'
```
