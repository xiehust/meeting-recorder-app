# M0 验证记录

状态：开发中。本文严格区分已检查与仍需实际音频／云端请求验证的项目。

## 本机与只读检查

日期：2026-09-17。

| 项目 | 结果 |
|---|---|
| 系统 | macOS 26.6.2；PRD 写的是 26.2.2，实际验证以本机为准 |
| Swift | 6.4，Apple Command Line Tools |
| 构建 SDK | macOS 26.5；脚本避开本机默认的 macOS 27 SDK |
| Teams | 26163.407.4839.8659 |
| Zoom | 7.1.5 (84650) |
| AWS profile | 用户确认 `default` |
| 现有 profile 区域 | `us-west-2`；用作两服务的初始配置 |
| STS CLI | 凭证只读检查通过；未记录账户 ID 或 ARN |
| Bedrock 目录 | 列出 `openai.gpt-6-astra`、`openai.gpt-5.6-sol`、`openai.gpt-5.6-terra`、`openai.gpt-5.6-luna` |
| 推理授权、medium 请求 | 未发送推理请求，待验证 |
| Astra 访问元数据 | `GetFoundationModelAvailability` 返回 AUTHORIZED，agreement / entitlement / region 均 AVAILABLE；仍需实际请求验证 |

官方 OpenAI Bedrock 文档显示 Astra 支持 `us-west-2`，Mantle 和 Runtime 的路径、模型 ID／推理路由需分别确定。目录可见不能替代具体接口的调用验证。当前没有猜测 Runtime inference profile 或执行跨区域降级。

## 自动化验证

`bash scripts/test.sh` 已通过：**28 项测试，0 失败**（0.1.1）。

- 14 项核心测试：原始结果去重与冲突保护、人工编辑、校对来源与版本检查、暂停时间、说话人重连隔离、合并撤销与循环保护、单段归属、导出备注隔离、SQLite 重启恢复、事务回滚及关联音频删除。
- 4 项转录适配测试：中英混合与说话人请求参数、固定语言请求互斥、单个服务结果内多人拆分、标点不破坏时间范围、麦克风默认“我”。
- 2 项采集看门狗回归测试、8 项音频范围／设备时钟／重采样测试，详见 [Teams 修复记录](TEAMS-AUDIO-FIX.md)。
- 完整 SwiftUI 可执行程序编译通过。权限 plist 和 shell 脚本语法验证通过。
- 测试仅使用合成数据，不采集麦克风，不调用 Transcribe 或模型推理。

## 原生应用检查

对 `dist/MeetingRecord.app` 完成以下检查：

| 检查 | 结果 |
|---|---|
| 本机签名与启动 | `codesign --verify --deep --strict` 通过，主窗口正常显示 |
| 启动边界 | 初始会议数量为 0，未创建 Audio 目录 |
| 交互示例 | 成功创建标记为示例的 4 段转录、3 位发言人 |
| 人工编辑 | UI 保存后数据库有独立 edit，原文仍为原始文本；重点标记正常显示 |
| 图形应用 AWS 凭证 | 设置内通过 Swift SDK 完成 STS 检查：`default / us-west-2` 有效 |
| 记录确认 | 确认框未勾选时，开始按钮 `enabled = false`；打开与取消面板没有录音 |
| 原生导出 | 通过 NSSavePanel 导出的 Markdown 含人工修订文本、时间戳及示例标记 |
| 正常退出／重启 | 示例、4 段原文、人工编辑仍可读取，没有音频缓存目录 |
| 视觉检查 | 检查原生主窗口截图，标题、列表、转录、人物标签与操作没有遮挡或溢出 |

以上检查没有点击开始录音，没有请求麦克风或系统音频权限，没有向 Transcribe 上传音频。它们不替代下面的真实采集验收。

## 真实采集验收步骤

测试录音必须由用户在应用中确认启动。开发过程中不自动开始采集用户会议。

1. `bash scripts/build-app.sh`，从 `.app` 启动。
2. **未确认边界**：打开 Teams 或 Zoom，忽略提醒；检查没有 Tap、麦克风引擎、缓存文件或转录请求启动。
3. **本地采集**：戴耳机，打开 Teams，选“仅本地采集验证”并明确开启音频缓存；取得 macOS 权限。分别让远端和本人发言，两路音量与缓存必须独立。检查无关应用声音未被捕获。记录 Teams helper 进程是否被 bundle 范围包含。
4. **暂停**：记录 10 秒后暂停 15 秒再恢复。新文件的会议偏移应相差 25 秒，而不是 10 秒；暂停区间不得写入新采集内容。
5. **云端组合**：启用实时转录，中英混合，三名远端发言者交替发言。检查两个流、分离标签、确定字幕、中文和英文原话。记录 SDK 凭证读取／刷新与服务参数实际行为。
6. **来源变化**：拔插耳机、切换蓝牙、断开麦克风、退出会议客户端。每个受影响轨道应显示异常并标记缺口；不能静默改成全系统采集。
7. **网络失败**：分别在缓存开／关状态断网。开缓存应继续本机写入并标“待补转”，关缓存应标缺失。当前补转待实现，不能把这个测试视为 AC-08 完成。
8. **收尾**：停止前说一句完整的话，检查最后的确定结果；服务未返回的临时结果须留下收尾不完整提示。
9. 重复上述步骤验证 Zoom。再分别验证外放和蓝牙；未完成前不得承诺回声抑制。
10. 两小时连续记录，检查延迟、CPU、内存、磁盘、UI 响应、后台和锁屏。休眠应暂停，唤醒不自动录音。

## 当前里程碑范围

- **M0**：本机检查和验证工具已具备；真实音频与模型推理组合待验证。
- **M1**：手动采集、流式转录与本地资料基础实现；自动重连、补转、设备切换增强待完成。
- **M2**：仅数据保护与配置基建；LLM 校对、总结、差异与版本 UI 待开发。
- **M3**：基础搜索、导出、运行提醒提前实现；发布签名、到期清理、性能与完整验收待完成。

## 文档依据

- [Core Audio Taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- 本机 macOS 26 SDK 的 `CATapDescription.h`：`bundleIDs` 与 `processRestoreEnabled`。
- [Transcribe StartStreamTranscription](https://docs.aws.amazon.com/transcribe/latest/APIReference/API_streaming_StartStreamTranscription.html)
- [Transcribe 流式最佳实践](https://docs.aws.amazon.com/transcribe/latest/dg/streaming.html)
- [OpenAI on Amazon Bedrock](https://developers.openai.com/api/docs/guides/amazon-bedrock)
