# 原图视觉问答真实 API 测试

> 状态：**已执行一次真实 API**（host Node 脚本；不是设备 ArkTS transport/账单验收）。
> 范围：真实 DeepSeek 视觉 API 的协议/模型/引用冒烟；**不是**设备 ArkTS transport、应用 UI、账单或 OpenHarmony 真机验收。

## 1. 安全边界

- 不要把 API Key 发到对话、文档、截图、脚本、日志或测试数据中。
- 命令使用隐藏输入，Key 只作为该 Node 进程的临时环境变量；进程结束/命令结束时清除。
- 脚本不写 Key 到磁盘，不打印 Authorization、请求体或响应原始正文。
- 使用仓库内合成图片 `entry/src/ohosTest/resources/rawfile/vision/api-text.png`，不含个人资料。
- 真实请求会产生供应商计费；只发一次，实际费用以 DeepSeek 账单为准。

## 2. 命令

在仓库根目录的 Git Bash 中执行：

```bash
read -rsp 'DeepSeek API key (input hidden): ' DEEPSEEK_API_KEY; echo
DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" node scripts/test-deepseek-vision.cjs
rc=$?
unset DEEPSEEK_API_KEY
echo "rc=$rc"
```

可选指定模型（默认 `deepseek-flash`）：

```bash
DEEPSEEK_MODEL='deepseek-flash' DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
  node scripts/test-deepseek-vision.cjs
```

不要把 Key 作为命令行参数，例如 `--key sk-...`；它会进入 shell 历史和进程列表。

## 3. 脚本行为

- 请求：`POST https://api.deepseek.com/chat/completions`。
- 使用与 route 2 相同的严格 JSON/引用系统提示、本次问题、合成 PNG 的 `image_url` data URL。
- 参数：`response_format={"type":"json_object"}`、`thinking={"type":"disabled"}`、`stream=false`、`max_tokens=1024`。
- 成功时只打印：HTTP 状态、模型、prompt/completion tokens、回答、引用；不打印 Key 或原始响应。
- 校验：HTTP 200、模型匹配、单 choice、`finish_reason=stop`、usage、`answer` 非空、`citations=[1]`、回答含 `[1]`。
- 失败时打印安全错误码，例如 `DEEPSEEK_HTTP_401`、`DEEPSEEK_ANSWER_REFERENCE_INVALID`，不打印供应商原始正文。

## 4. 通过/失败含义

通过只证明：

- 当前 Key/账户/模型能接受该图片请求；
- 返回符合预期 JSON 和 `[1]` 引用；
- 供应商报告了 token 用量。

不能证明：

- 应用内 `ArkTsVisionChatTransport` 在设备上的行为；
- 图片选择/同意/停止/后台 UI；
- 实际扣费、余额、退款或账单核验；
- OpenHarmony 真机兼容性。

## 5. 记录

如用户同意，可把脚本输出（不含 Key）写入 `.cache/test-logs/`：

```bash
DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" node scripts/test-deepseek-vision.cjs \
  > .cache/test-logs/deepseek-vision-real-api.txt
```

该文件仍可能包含模型回答；只使用合成图片，且不把它当作账单证据。

## 6. 当前结果

- 无 Key 安全失败：`DEEPSEEK_API_KEY_REQUIRED`，未发起网络请求；证据 `.cache/test-logs/2026-10-26-vision-route2-real-api-nokey-42101a3/`。
- 2026-10-26 用户在本机 Windows PowerShell 用 `Read-Host -AsSecureString` 隐藏输入 Key，执行一次真实请求：`HTTP=200`、`MODEL=deepseek-flash`、prompt 452 tokens、completion 25 tokens、回答“图中的英文字符和数字是『RUNTIME 42』[1]”、`citations=[1]`、rc=0。Key 未进入对话/日志/仓库。
- 证据：`.cache/test-logs/2026-10-26-vision-route2-real-api-user/transcript.txt`（用户终端输出转录，非脚本自动 capture；不含 Key）。
- 实际扣费、余额和账单未核验；一次成功请求不等于费用上限或退款能力。
- 设备 ArkTS transport、图片选择/同意 UI 和真机仍未执行；本结果只证明供应商视觉 API/该 payload/提示词可用。
