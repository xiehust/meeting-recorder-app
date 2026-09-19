# 校对与总结的模型提供方

全局设置和「本会议的 AI 设置」都可为校对、总结分别配置提供方，支持混合使用。全局默认值用于新会议；旧会议可点击「采用当前全局默认值」。更改配置不改写已有校对或纪要版本。

## Bedrock Runtime Responses API

- 默认提供方。沿用本机 AWS profile、模型区域与 SigV4（服务名 `bedrock`）。
- 地址：`https://bedrock-runtime.{region}.amazonaws.com/openai/v1/responses`。
- 保留现有 GPT 预设；选择「自定义 Model ID」可输入服务支持的完整模型／推理配置 ID，不添加前缀、不替换模型、不受预设列表约束。自定义 ID 的实际可用性由区域、服务支持与账户权限决定。
- 自定义模型默认不发送 `reasoning`。需要时可选择具体推理强度；服务必须支持该值。

## 第三方 Responses API

填写 URL、API Key 与 Model ID。使用 `Authorization: Bearer <API Key>`，不读取 AWS profile 凭证。

| 填写地址 | 实际请求地址 |
|---|---|
| `https://proxy.example.com` | `https://proxy.example.com/v1/responses` |
| `https://proxy.example.com/v1` | `https://proxy.example.com/v1/responses` |
| `https://proxy.example.com/openai/v1` | `https://proxy.example.com/openai/v1/responses` |
| `https://proxy.example.com/custom/responses` | 保持该完整地址 |

远程服务要求 HTTPS；本机 `localhost`、`127.0.0.1`、`[::1]` 可用 HTTP。URL 不接受用户名、密码、查询参数或片段；凭证填写在 API Key 输入框。

「保存 API Key」立即写入 macOS 钥匙串（service：`local.meetingrecord.responses`）。Key 按规范化后的完整端点分别保存，同一端点可由校对、总结或其他会议共用；切换地址不会把原 Key 发给新地址。Key 不进入普通设置、会议快照、导出或诊断。只检查是否配置时不读取 Key 内容。

每组配置都有「验证模型调用」。可验证未保存的 Key；留空则读取该地址已保存的 Key。检查发送固定测试文字，会产生少量推理用量，不发送会议内容。「保存并关闭／保存」用于保存模型配置；输入框里的 Key 需要单独点击「保存 API Key」才能供后续处理使用。

## 协议、版本与失败处理

两种提供方复用 Responses 请求与文本解析：`model`、`instructions`、`input`、`max_output_tokens`、`store: false`、`stream: false`。选「服务默认」时省略 `reasoning`。代理需支持非流式 Responses 协议，返回 `status: completed` 与 `output[].content[].type: output_text`；仅支持 Chat Completions 的地址不可用。

校对、分块续接、生成纪要、引用检查、保存版本和导出沿用同一流程。版本保存提供方、地址、模型和推理强度；调用记录保存响应实际返回的模型与 token 用量。续接只复用输入和配置完全匹配的未完成版本。

不跟随 HTTP 重定向，不自动重试推理，不因失败回退到其他提供方。停止等待不能撤回已发送的模型请求。错误不会保存代理响应正文，以免代理回显 Key 或会议文字。

旧版本没有 provider 字段时仍使用 Bedrock。原 Mantle/global 预设转换保留，历史版本不迁移。参见 [Bedrock Runtime](BEDROCK-RUNTIME.md)。

## 验证范围

离线测试覆盖旧配置解码、自定义 ID、可选 reasoning、URL 规范化、Key 端点隔离、SigV4 区域、Bearer 请求、代理响应与用量、HTTP 失败与未完成响应、禁止应用层重试／回退、不同阶段使用不同提供方及版本保存。第三方实际兼容性需在设置中用用户自己的服务验证。

2026-09-19：全套 186 项测试通过（Core 69、Cloud 85、Audio 32）；本地 App 编译与签名验证通过。界面验证确认全局／单会议入口、独立提供方切换、完整请求地址预览、自定义 Model ID、服务默认推理强度及未配置 Key 时禁用调用检查。界面测试使用临时配置后取消，未改变现有会议设置，也未发送真实推理请求。

协议参考：[OpenAI Responses API](https://platform.openai.com/docs/api-reference/responses/create)。本轮官方页面访问被拒绝，实现基于应用已有 Responses 协议与模拟接口验证，未据此声称验证了任意第三方模型。

## 代理路径实测补充（2026-09-19）

本机 Codex 使用的代理基础路径为 `/openai/v1`。只填写域名时，App 按标准基础地址规则生成 `/v1/responses`，在该代理上返回 HTTP 404；应填写服务提供的完整基础地址，或完整 `/openai/v1/responses` 端点。App 不会根据域名猜测或自动重试其他路径。

使用现有代理凭证、`global.openai.gpt-5.6-sol`、`medium` 和与 App 连接检查相同的固定短文本及请求字段，正确路径返回 HTTP 200、`status: completed` 和有效文本；用量为输入 23、输出 5 tokens。该验证未发送会议内容，也未修改 App 中的 Key。更换 App 中的端点后，需要为新地址保存 Key；此前保存的 Key 仍绑定原端点。
