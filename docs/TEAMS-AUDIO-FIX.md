# 0.1.1 · Teams 远端发言未转录

## 用户报告与证据

2026-09-17，用户真实 Teams 会议中只能看到自己的转录，听得到的远端发言没有出现。

仅分析了记录元数据与进程／设备信息，未输出或另存会议正文，也未重新采集会议声音：

- 该记录有 25 段麦克风转录、0 段应用转录。
- 应用轨被“超过 8 秒未收到音频数据”看门狗停止，随后没有恢复。
- Core Audio 中登记了 Teams 的 5 个音频进程：ModuleHost、WebView helpers、通知服务；没有以 `com.microsoft.teams2` 主标识登记的音频进程。
- 默认输出为 `External Headphones`，UID 为 `BuiltInHeadphoneOutputDevice`，0 个输入流、1 个输出流。
- 本次记录关闭了本地缓存。缺失的远端音频未保留，应用不能为这次记录补转。

## 修正

1. **采集辅助进程**：枚举 Core Audio 音频进程，核对实际可执行文件是否位于选中的应用安装包内，使用对应的 AudioObjectID 创建立体声 Tap。精确登记安装包内、属于该应用命名空间的 helper bundle IDs，支持加入会议时才启动的辅助进程。不使用系统全局 Tap。
2. **时钟**：独立输出设备作为私有 aggregate 的时钟，关闭“等 Tap 收到第一段音频才启动”的选项；输出回调只写零，不改变系统默认设备。存在硬件输入流的设备（包括双向蓝牙耳机）不加入 aggregate，避免把设备麦克风混入远端轨。
3. **等待音频可以恢复**：应用轨超过 8 秒无帧时显示等待提示并记录待核对区间，继续保留 Tap；帧恢复后关闭区间、恢复状态。麦克风断开仍按异常处理。
4. **延迟建立转录流**：第一块 PCM 到达才启动 AWS 请求，时间偏移以这块音频为准，避免权限弹窗或对方尚未开口导致空流超时。启动与结束状态用锁保护，单个会话只启动一次。
5. **转换收尾**：停止采集时排空重采样器剩余数据。48 kHz → 16 kHz 的合成样本验证中，100 ms 音频的最后 240 个输出采样原先没有送出，现已保留。
6. **诊断**：新会议保存应用轨的精确 bundle ID 列表、匹配进程数量和时钟设备名称；不保存凭证或新增音频正文日志。

## 验证

- `bash scripts/test.sh`：28 项测试通过，0 失败。
- 新增测试覆盖：Teams 主进程没有音频对象时选中三个辅助音频对象；排除相似路径、外部应用和越界符号链接；提前登记 helper；耳机时钟；双向蓝牙硬件输入隔离；静音超过 8 秒后恢复；重采样输出和无输入停止。
- 使用编译后的 `MeetingAudio.applicationScope` 对本机运行中的 Teams 做只读检查：成功匹配 5 个音频进程，包含 `com.microsoft.teams2.modulehost` 和 `com.microsoft.teams2.helper`。该检查没有创建 Tap。
- 缓存关闭的旧记录保留原样，不插入伪造的远端转录。
- 0.1.1 已完成签名校验并重启；已有 2 场会议正常加载，29 段原文的数据库保存内容经哈希核对完全一致。

仍需用户在 0.1.1 上进行真实 Teams 耳机会议复测：当对方说话时，“会议应用”音量应变化，随后应出现远端发言人的转录。可让自己先说话、对方等待 10 秒以上再说，验证不会被早期静音停掉。蓝牙、设备热切换和长会议测试仍不视为已通过。

## 参考

- [Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- macOS 26 SDK `AudioHardware.h`：`kAudioAggregateDeviceMainSubDeviceKey` 是 aggregate 时间源；`kAudioAggregateDeviceTapAutoStartKey` 非零会等待被采集进程开始音频。
