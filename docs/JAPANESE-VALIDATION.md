# 中日英处理验证 · 0.6.0

> 以下是 0.6.0 的历史验证记录。0.6.1 新录音只提供中英、英日两种混合选项，旧三语配置保留兼容；当前选项见 [识别语言](RECOGNITION-LANGUAGES.md)。

## 配置

- 界面：简体中文、English、日本語，可跟随系统或手动切换。
- 识别：中文 `zh-CN`、英文 `en-US`、日文 `ja-JP`、中英混合、中日英混合。
- 原有 `mixed` 保存值仍表示中英混合；新的 `multilingual` 才包含日文。历史会议不迁移语言设置。
- 纪要：中文、English、日本語，单独保存输出选择。内置模板的章节、导出标题和说明按输出语言生成，原文引用不翻译。
- 词汇表：三种语言分别维护、构建和匹配；日文支持汉字、平假名、片假名。重复词条按语言区分，同步前必须通过本地校验和 AWS 的语言字符校验。

## 自动化验证

128 项测试通过：MeetingCore 52、MeetingCloud 51、MeetingAudio 25。新增验证覆盖：

- 系统语言匹配、手动选择、英文回退、全部译文插值与 Unicode、历史数据保护。
- 日文固定识别和三语混合的实时／批量参数、各语言词汇表匹配，原有中英混合的兼容性。
- 日文假名分词拼接、说话人分段、时间偏移；不插入英文式多余空格。
- 日文词条批量导入、重复检查、READY 状态要求、保存及读取。
- 日文总结提示、内置模板标题、原文引用、Markdown / TXT 导出；日文不确定决策保留为待确认事项。

## 桌面界面验证

在打包后的 0.6.0 应用中，验证日文选择重启后保留，并在同一个设置窗口中依次切换日文 → 英文 → 中文 → 跟随系统。语言标题和下拉选项同步刷新，识别菜单包含五种模式，纪要菜单包含三种语言。最终恢复为跟随系统。升级前后比较会议内容、原文校验表、AWS／录音配置、词汇表库和模板库，均保留；本地音频缓存仍开启。

## 真实 AWS 验证

使用本机已配置的 `default` profile、`us-west-2`，以及已有同区域 S3 桶。测试使用 macOS 合成语音（Kyoko、Tingting、Samantha）和固定示例文本，没有发送用户会议内容，也没有修改用户词汇表库或 AWS 权限。

| 项目 | 结果 |
| --- | --- |
| 日文词汇表上传、创建、等待 READY、读取状态 | 通过 |
| 日文实时转录，带日文词汇表和说话人标签 | 通过，收到确定结果 |
| 中日英混合实时转录，带日文词汇表 | 通过，收到确定结果 |
| 日文批量转录，带日文词汇表 | 通过，保存结果后清理任务和 S3 输入／输出 |
| 中日英混合批量转录，按语言匹配词汇表 | 通过，保存结果后清理任务和 S3 输入／输出 |
| 三语测试文本 → AI 校对 → 日文培训纪要 | 通过，验证模板章节、原文引用及原文保留 |
| 测试词汇表和 S3 词汇表文件清理 | 通过 |

这些验证确认参数、服务接入和处理流程可用，不代表已完成真实日语会议、口音、噪声或频繁语言切换的识别准确率评估。

## 重复验证

以下命令调用 AWS，会产生少量用量；使用合成测试文件和独立测试词汇表。不会读写桌面应用的会议数据库或偏好设置。

```sh
MeetingAIValidate --sync-vocabulary-file PROFILE REGION INPUT_JSON RECEIPT_JSON
MeetingAIValidate --check-stream-file PROFILE REGION AUDIO_FILE japanese RECEIPT_JSON
MeetingAIValidate --check-stream-file PROFILE REGION MULTILINGUAL_AUDIO multilingual RECEIPT_JSON
MeetingAIValidate --check-batch-file PROFILE REGION BUCKET AUDIO_FILE japanese RECEIPT_JSON
MeetingAIValidate --check-batch-file PROFILE REGION BUCKET MULTILINGUAL_AUDIO multilingual RECEIPT_JSON
MeetingAIValidate --check-summary-language PROFILE REGION 日本語
MeetingAIValidate --clean-vocabulary-file PROFILE REGION RECEIPT_JSON
```

流式测试最多接受 60 秒文件，并检查确定结果；日文／三语测试检查返回的日文假名。摘要测试使用内置的中日英固定文本。`RECEIPT_JSON` 参数用于加载独立测试词汇表的已就绪快照，不是用户库。清理命令仅允许 receipt 中与指定 profile、区域和该库命名空间一致的资源。批量失败时保留 receipt 路径供继续或清理。

参考：[支持语言](https://docs.aws.amazon.com/transcribe/latest/dg/supported-languages.html)、[流式请求参数](https://docs.aws.amazon.com/transcribe/latest/APIReference/API_streaming_StartStreamTranscription.html)、[批量请求参数](https://docs.aws.amazon.com/transcribe/latest/APIReference/API_StartTranscriptionJob.html)。
