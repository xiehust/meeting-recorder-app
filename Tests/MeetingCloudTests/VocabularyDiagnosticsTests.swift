import Testing
import AWSSDKIdentity
import AWSTranscribe
import AWSClientRuntime
import MeetingCore
@testable import MeetingCloud

private struct ServiceFailure: Error, AWSServiceError {
    let errorCode: String?
    let requestID: String? = "request-123"
    var typeName: String? { "ServiceFailure" }
    var message: String? = "private provider or request details"
}

@Test func missingVocabularyBadRequestIsRecognizedWithoutSwallowingOtherBadRequests() {
    #expect(AWSVocabularyRemote.isMissingVocabulary(AWSTranscribe.BadRequestException(
        message: "The requested vocabulary couldn't be found. Check the vocabulary name and try your request again.")))
    #expect(AWSVocabularyRemote.isMissingVocabulary(AWSTranscribe.NotFoundException()))
    #expect(!AWSVocabularyRemote.isMissingVocabulary(AWSTranscribe.BadRequestException(message: "Invalid language code")))
    #expect(!AWSVocabularyRemote.isMissingVocabulary(ServiceFailure(errorCode: "AccessDeniedException")))
}

@Test func missingCredentialsAreDistinctFromPermissionsAndProviderDetailsStayPrivate() {
    let failure = VocabularyOperationError(operation: .bucketRegion, scope: .init(profile: "default", region: "us-west-2"),
        underlying: AWSCredentialIdentityResolverError.failedToResolveAWSCredentials("private provider or request details"))
    let message = VocabularyService.userMessage(failure)
    #expect(message.contains("检查 S3 桶区域失败"))
    #expect(message.contains("profile：default"))
    #expect(message.contains("AWS 签名凭证"))
    #expect(message.contains("Bedrock API Key"))
    #expect(!message.contains("权限不足"))
    #expect(!message.contains("private provider"))
}

@Test func permissionsIncludeTheFailingActionAndExpiredTokensRequestLoginInstead() {
    let scope = VocabularyScope(profile: "example-profile", region: "us-west-2")
    let denied = VocabularyOperationError(operation: .upload, scope: scope,
        underlying: ServiceFailure(errorCode: "AccessDeniedException"))
    let message = VocabularyService.userMessage(denied)
    #expect(message.contains("s3:PutObject"))
    #expect(message.contains("AccessDeniedException"))
    #expect(message.contains("request-123"))
    #expect(!message.contains("private provider"))
    let expired = VocabularyOperationError(operation: .create, scope: scope,
        underlying: ServiceFailure(errorCode: "ExpiredTokenException"))
    #expect(VocabularyService.userMessage(expired).contains("凭证无效或已过期"))
    #expect(!VocabularyService.userMessage(expired).contains("检查当前身份对该资源的权限"))
}
