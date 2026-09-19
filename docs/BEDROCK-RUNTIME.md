# Bedrock Runtime Responses · 0.5.1

选择 Bedrock 提供方时，校对、纪要和连接验证使用以下端点。第三方代理与自定义模型配置参见 [模型提供方](MODEL-PROVIDERS.md)。

```text
POST https://bedrock-runtime.{region}.amazonaws.com/openai/v1/responses
```

请求使用本机所选 AWS profile 的凭证签名，SigV4 服务名为 `bedrock`，签名区域与接入区域相同。沿用 Responses JSON 输入、显式推理强度、`store: false` 和 `stream: false`，不启用 background、服务端工具或自定义 project。

| 模型 | 请求中的 model |
|---|---|
| GPT-6 Astra | `global.openai.gpt-6-astra` |
| GPT-5.6 Sol | `global.openai.gpt-5.6-sol` |
| GPT-5.6 Terra | `global.openai.gpt-5.6-terra` |
| GPT-5.6 Luna | `global.openai.gpt-5.6-luna` |

这些预设 ID 是系统定义的全球跨区域推理配置，不是裸模型 ID。应用请求所选接入区域，由 AWS 按 global 配置路由到支持的目的区域。预设沿用原有校验；显式选择自定义 Model ID 时按原样发送，默认省略 reasoning 参数，不受预设列表与预设区域限制。

## 配置与历史版本

启动新版时，将当前默认设置中可识别的旧 Mantle 配置迁移为 Runtime/global，并重置旧端点的连接验证提示。AWS profile、区域、模型选择与推理强度保持原值。

旧会议的新调用也会转换已知旧配置：空 model ID 或与模型选择匹配的 `openai.*` ID 会解析为相应的 `global.openai.*`。不接受其他未知端点、重复 `global.` 前缀或与所选模型不一致的 ID。

历史校对、纪要与调用记录不迁移，以保留其真实生成配置。未完成的旧 Mantle 校对不会与新 Runtime 请求拼成同一个版本，重新处理会产生新版本；已完成的校对可继续作为生成新纪要的文字输入。

## 权限与请求行为

Runtime Responses 使用 `bedrock:InvokeModel`，需要覆盖推理目标和账户默认 project，以及跨区域推理所需的目标模型权限。错误提示已更新，应用不修改 IAM 或 SCP 策略。

继续禁用自动推理重试和 HTTP 跳转；请求失败不会回退到 Mantle。响应记录保存实际使用的 Runtime URL。`store: false` 不需要应用再执行存储响应的读取、取消或删除操作。

## 验证

离线测试覆盖四个模型的 ID、已知旧配置转换、配置幂等性、历史记录保留、Runtime Host 与路径、SigV4 的区域及 `bedrock` 服务名、关闭存储，以及未完成旧校对的新版本处理。

2026-09-17 验证：116 项测试通过。使用 `default` profile、`us-west-2`、medium 档位和不含会议内容的固定测试文字，四个 `global.openai.*` 模型均通过 Runtime Responses 真实调用并返回有效 JSON。此检查验证连接及请求兼容性，不代表会议校对质量评估。

```sh
bash scripts/test.sh
# 少量合成文字调用四个模型，不发送会议内容；使用 default profile
.build/out/Products/Debug/MeetingAIValidate --probe-models
```

官方依据：

- [Endpoints supported by Amazon Bedrock](https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html)
- [Responses API](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html)
- [Prerequisites for running model inference](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-prereq.html)
