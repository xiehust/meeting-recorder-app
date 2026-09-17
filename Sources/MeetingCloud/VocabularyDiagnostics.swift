import Foundation
import AWSSDKIdentity
import AWSClientRuntime
import ClientRuntime
import MeetingCore

public enum VocabularyOperation: String, Sendable {
    case configure = "初始化 AWS 客户端"
    case bucketRegion = "检查 S3 桶区域"
    case upload = "上传词汇表到 S3"
    case lookup = "查询词汇表"
    case create = "创建词汇表"
    case rebuild = "重新构建词汇表"
    case deleteVocabulary = "删除旧词汇表"
    case deleteObject = "清理 S3 词汇表文件"

    var action: String? {
        switch self {
        case .configure: nil
        case .bucketRegion: "s3:GetBucketLocation"
        case .upload: "s3:PutObject"
        case .lookup: "transcribe:GetVocabulary"
        case .create: "transcribe:CreateVocabulary"
        case .rebuild: "transcribe:UpdateVocabulary"
        case .deleteVocabulary: "transcribe:DeleteVocabulary"
        case .deleteObject: "s3:DeleteObject"
        }
    }
}

public struct VocabularyOperationError: LocalizedError, Sendable {
    public let operation: VocabularyOperation
    public let scope: VocabularyScope
    public let detail: String
    public init(operation: VocabularyOperation, scope: VocabularyScope, underlying: Error) {
        self.operation = operation; self.scope = scope
        detail = VocabularyDiagnostics.message(underlying, action: operation.action)
    }
    public var errorDescription: String? {
        "\(operation.rawValue)失败（profile：\(scope.profile)，区域：\(scope.region)）。\n\(detail)"
    }
}

enum VocabularyDiagnostics {
    static func message(_ error: Error, action: String? = nil) -> String {
        if let error = error as? VocabularyOperationError { return error.localizedDescription }
        if let error = error as? VocabularyError { return error.localizedDescription }
        if error is CancellationError { return "同步已取消；已提交的 AWS 构建可能继续，稍后可再次同步检查。" }
        let type = String(describing: Swift.type(of: error)).lowercased()
        // Provider errors may contain credential_process output. Never display the underlying dump.
        if error is AWSCredentialIdentityResolverError || type.contains("credential") {
            return "无法获取可用的 AWS 签名凭证。请在设置中选择已配置凭证的 profile，或更新当前 profile 的登录／访问凭证。Bedrock API Key 不能用于 S3 和 Transcribe。"
        }
        let service = error as? AWSServiceError
        let code = service?.errorCode.flatMap(safeIdentifier)
        let classification = (code ?? type).lowercased()
        let status = (error as? HTTPError)?.httpResponse.statusCode.rawValue
        let message: String
        if ["expiredtoken", "invalidclienttokenid", "unrecognizedclient", "invalidaccesskeyid",
            "invalidtoken", "signaturedoesnotmatch", "invalidsignature"].contains(where: classification.contains) {
            message = "AWS 访问凭证无效或已过期。请重新登录或更新所选 profile 的凭证。"
        } else if classification.contains("accessdenied") || classification.contains("forbidden") || status == 403 {
            message = "AWS 拒绝了 \(action ?? "当前操作")。请检查当前身份对该资源的权限。"
        } else if classification.contains("nosuchbucket") {
            message = "S3 桶不存在，请填写已有的同区域桶名。"
        } else if classification.contains("limit") || classification.contains("throttl") {
            message = "AWS 配额或请求频率受限，请清理未使用的旧版本或稍后再试。"
        } else if classification.contains("badrequest") || classification.contains("validation") {
            message = "AWS 拒绝了请求参数。请检查词条格式、词汇表名称、语言及 S3 区域。"
        } else {
            message = "请求未完成，请检查网络、AWS profile 和服务配置。"
        }
        var details: [String] = []
        if let code { details.append("AWS 错误：\(code)") }
        if let request = service?.requestID.flatMap(safeIdentifier) { details.append("请求 ID：\(request)") }
        return message + (details.isEmpty ? "" : "\n" + details.joined(separator: " · "))
    }

    private static func safeIdentifier(_ value: String) -> String? {
        value.range(of: #"^[A-Za-z0-9._:/+=-]{1,160}$"#, options: .regularExpression) != nil ? value : nil
    }
}
