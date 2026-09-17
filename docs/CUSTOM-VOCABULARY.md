# 全局转录词汇表

从首页侧栏、设置或记录准备窗口打开“全局词汇表”。本表作用于 AWS Transcribe 的语音识别阶段，可提示产品名、缩写和专业术语；不能保证每次都正确识别。每场会议的“术语与备注”仍用于 AI 校对与总结，不会自动上传为全局词汇表。

## 使用

1. 添加中文或英文条目，填写词条和可选输出写法。备注仅存在本机。启用开关控制下次同步的内容。
2. 英语按字母读的缩写使用句点，例如 `A.W.S.`，输出写法为 `AWS`；短语用连字符，输入空格会自动转换。词条中的数字要写读音，输出写法可以包含数字、空格及符号。
3. 批量添加支持从表格复制两列：词条、输出写法，以制表符分隔，每行一个条目。重复或无效输入整批不保存。
4. 在设置选择 AWS profile 与 Transcribe 区域，在词汇表界面填写已有的同区域 S3 桶名。点击“同步到 AWS”。词条、输出写法会上传；本地备注不上传。
5. 等待各语言显示“已就绪”。准备记录时打开“使用全局自定义词汇表”；开始前会再次检查云端状态。未配置对应语言词条时正常转录，有启用条目但未同步就绪时会阻止开始并给出提示，可明确关闭本次词汇表选项后继续。

单一语言通过 `VocabularyName` 传入相应词汇表；中英混合通过 `VocabularyNames` 同时传入匹配语言的词汇表。麦克风与会议应用两路都使用相同配置。

## 文件与版本

采用 AWS 推荐的四列表格（Phrase、SoundsLike、IPA、DisplayAs），其中两个停用的发音列留空。未使用逐步弃用的 Phrases 列表方式。每种语言不超过 50,000 UTF-8 字节，每条词条／输出写法不超过 256 个字符；AWS 会继续检查各语言允许的字符。

本地库保存在偏好设置 `customVocabularyLibrary`。同步目标按 profile 和区域区分；改动词条、输出写法或启用状态会产生新的内容散列及云端名称，修改本地备注不会让云端版本过时。已有会议保存词汇表名称、语言、内容散列和词条数的快照。全局编辑不会回写历史转录，也不会更改已开始的转录流。

S3 对象保存于 `meetingrecord/vocabularies/<本地库 UUID>/`，仅包含词汇表文本。应用使用桶的默认加密配置；不设置公共 ACL，不更改桶策略。不会为此上传录音或完整转录。

“清理旧版本”只删除本地库登记、本应用命名空间内、当前词条不再使用且没有本地会议引用的词汇表及对应 S3 对象。其他应用创建的资源不参与清理。S3 开启版本控制时，对象的历史版本仍由桶自身的保留规则管理。跨设备或其他程序使用本应用创建的词汇表时，应自行保留相应版本。

同步等待有时间上限，超时或取消后再次同步会查询同名资源、继续等待，不创建重复词汇表。AWS 失败状态会保留；失败的同一内容版本可重新构建。READY 版本不会被原地覆盖。

## 权限与费用

同步身份需要：

- `transcribe:CreateVocabulary`、`transcribe:GetVocabulary`、`transcribe:UpdateVocabulary`（仅重建失败版本）。
- 清理旧版本时需要 `transcribe:DeleteVocabulary`。
- 目标桶上的 `s3:GetBucketLocation`，本应用对象前缀下的 `s3:PutObject`、`s3:GetObject`；清理时需要 `s3:DeleteObject`。
- 使用 SSE-KMS 的桶还需要对应 KMS 密钥及服务读取权限。以 AWS 返回的实际原因核对策略。
- 原有实时转录权限继续适用。

按所选 profile 使用已有 AWS 凭证，不保存密钥。S3 存储及请求按账户计费；开启词汇表不会改变原有两路转录的计费方式。AWS 默认每账户最多 100 个自定义词汇表，建议定期清理未使用版本。

## 排查与验证

排查同步错误时，先确认所选 profile 有可用的 AWS 签名凭证。Bedrock API Key 仅用于 Bedrock，不能替代 S3 或 Transcribe 的 AWS 凭证。错误提示会区分凭证获取失败、凭证过期和具体操作被拒绝，并标明出错步骤。

开发排查可用 `MeetingAIValidate --check-vocabulary-access PROFILE REGION BUCKET`，只检查桶区域及查询不存在的词汇表，不上传内容。`--sync-vocabulary-file PROFILE REGION INPUT_JSON OUTPUT_JSON` 会上传指定本地词汇库并创建资源，将状态写入独立输出文件；不会直接修改应用偏好设置或会议数据库。

0.4.1 已用应用相同的 Swift SDK 完成真实的桶区域查询、词汇表查询、S3 上传、创建及等待 READY 的验证。该次输入为用户配置的四个英文词条；桶名、词条内容和账号凭证未写入工程。此验证不代表识别准确率的量化评估。

## AWS 文档

- [自定义词汇表概览与限制](https://docs.aws.amazon.com/transcribe/latest/dg/how-vocabulary.html)
- [四列表格格式](https://docs.aws.amazon.com/transcribe/latest/dg/custom-vocabulary-create-table.html)
- [流式请求及多语言 VocabularyNames](https://docs.aws.amazon.com/transcribe/latest/APIReference/API_streaming_StartStreamTranscription.html)
- [词汇表语言必须与转录匹配](https://docs.aws.amazon.com/transcribe/latest/dg/custom-vocabulary-using.html)
