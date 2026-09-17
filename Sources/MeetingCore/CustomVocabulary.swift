import Foundation
import CryptoKit

public enum VocabularyLanguage: String, Codable, CaseIterable, Sendable {
    case chinese = "zh-CN", english = "en-US"
    public var title: String { self == .chinese ? "中文" : "English" }
    public func applies(to language: RecognitionLanguage) -> Bool {
        language == .mixed || (language == .chinese && self == .chinese) || (language == .english && self == .english)
    }
}

public struct VocabularyEntry: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var language: VocabularyLanguage = .english
    public var phrase = ""
    public var displayAs = ""
    public var note = ""
    public var enabled = true
    public init() {}

    public func validated() throws -> VocabularyEntry {
        var result = self
        result.phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).joined(separator: "-")
        result.displayAs = displayAs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.phrase.isEmpty, result.phrase.unicodeScalars.count <= 256 else {
            throw VocabularyError.invalid("词条不能为空，且不能超过 256 个字符。")
        }
        guard !result.phrase.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) else {
            throw VocabularyError.invalid("词条中不能包含数字，请写出数字的读音；数字可放在“输出写法”中。")
        }
        let allowed = CharacterSet.letters.union(.nonBaseCharacters).union(CharacterSet(charactersIn: "-.'"))
        guard result.phrase.unicodeScalars.allSatisfy(allowed.contains) else {
            throw VocabularyError.invalid("词条仅支持字母、汉字、连字符、英文句点和撇号；特殊符号请放在输出写法中。")
        }
        guard result.displayAs.unicodeScalars.count <= 256,
              !result.displayAs.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              note.count <= 2_000 else {
            throw VocabularyError.invalid("输出写法不能包含制表符、换行或超过 256 字；备注不能超过 2000 字。")
        }
        return result
    }
}

public struct VocabularyScope: Codable, Equatable, Sendable {
    public let profile: String
    public let region: String
    public init(profile: String, region: String) {
        self.profile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct VocabularyBinding: Codable, Equatable, Sendable {
    public let language: VocabularyLanguage
    public let name: String
    public let digest: String
    public let entryCount: Int
    public init(language: VocabularyLanguage, name: String, digest: String, entryCount: Int) {
        self.language = language; self.name = name; self.digest = digest; self.entryCount = entryCount
    }
}

public struct VocabularySnapshot: Codable, Equatable, Sendable {
    public let scope: VocabularyScope
    public let bindings: [VocabularyBinding]
    public init(scope: VocabularyScope, bindings: [VocabularyBinding]) { self.scope = scope; self.bindings = bindings }
    public func validate(scope: VocabularyScope) throws {
        guard self.scope == scope else { throw VocabularyError.invalid("词汇表的 AWS profile 或区域与本次转录不一致，请重新同步。") }
        guard Set(bindings.map(\.language)).count == bindings.count,
              bindings.allSatisfy({ $0.name.range(of: #"^[A-Za-z0-9._-]{1,200}$"#, options: .regularExpression) != nil }) else {
            throw VocabularyError.invalid("词汇表快照无效，请重新同步后开始记录。")
        }
    }
    public var description: String {
        bindings.map { "\($0.language.title) \($0.entryCount) 条" }.joined(separator: " · ")
    }
}

public enum VocabularyState: String, Codable, Sendable {
    case pending, ready, failed
    public var title: String { switch self { case .pending: "处理中"; case .ready: "已就绪"; case .failed: "失败" } }
}

public struct VocabularyPlan: Sendable {
    public let binding: VocabularyBinding
    public let table: Data
    public let key: String
}

public struct VocabularyDeployment: Codable, Equatable, Identifiable, Sendable {
    public var id: String { scope.profile + "/" + scope.region + "/" + binding.name }
    public let binding: VocabularyBinding
    public let scope: VocabularyScope
    public let bucket: String
    public let key: String
    public var state: VocabularyState
    public var failure: String?
    public var checkedAt: Date
    public init(plan: VocabularyPlan, scope: VocabularyScope, bucket: String, state: VocabularyState,
                failure: String? = nil, checkedAt: Date = Date()) {
        binding = plan.binding; key = plan.key; self.scope = scope; self.bucket = bucket
        self.state = state; self.failure = failure; self.checkedAt = checkedAt
    }
}

public struct CustomVocabularyLibrary: Codable, Sendable {
    public var id = UUID()
    public var entries: [VocabularyEntry] = []
    public var bucket = ""
    public var useByDefault = true
    public var deployments: [VocabularyDeployment] = []
    public init() {}
    public var resourcePrefix: String { "mr-\(id.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))-" }
    public var objectPrefix: String { "meetingrecord/vocabularies/\(id.uuidString.lowercased())/" }

    public mutating func save(_ entry: VocabularyEntry) throws {
        let entry = try entry.validated()
        guard !entries.contains(where: {
            $0.id != entry.id && $0.language == entry.language && $0.phrase.lowercased() == entry.phrase.lowercased()
        }) else { throw VocabularyError.invalid("该语言中已存在相同词条，请编辑现有条目。") }
        var next = self
        if let index = next.entries.firstIndex(where: { $0.id == entry.id }) { next.entries[index] = entry }
        else { next.entries.append(entry) }
        _ = try next.plans()
        self = next
    }

    public mutating func importLines(_ text: String, language: VocabularyLanguage) throws -> Int {
        var next = self
        var keys = Set(entries.map { $0.language.rawValue + "/" + $0.phrase.lowercased() })
        var count = 0
        for (index, line) in text.components(separatedBy: .newlines).enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let columns = line.components(separatedBy: "\t")
            guard columns.count <= 2 else { throw VocabularyError.invalid("第 \(index + 1) 行应只有词条和输出写法两列。") }
            var entry = VocabularyEntry()
            entry.language = language; entry.phrase = columns[0]; entry.displayAs = columns.count == 2 ? columns[1] : ""
            entry = try entry.validated()
            guard keys.insert(language.rawValue + "/" + entry.phrase.lowercased()).inserted else {
                throw VocabularyError.invalid("第 \(index + 1) 行词条重复，未导入任何条目。")
            }
            next.entries.append(entry); count += 1
        }
        _ = try next.plans()
        self = next
        return count
    }

    public func plans() throws -> [VocabularyPlan] {
        try VocabularyLanguage.allCases.compactMap { language in
            let selected = try entries.filter { $0.enabled && $0.language == language }.map { try $0.validated() }
                .sorted { $0.phrase < $1.phrase }
            guard !selected.isEmpty else { return nil }
            guard Set(selected.map { $0.phrase.lowercased() }).count == selected.count else {
                throw VocabularyError.invalid("同一语言存在重复词条。")
            }
            let text = "Phrase\tSoundsLike\tIPA\tDisplayAs\n" +
                selected.map { "\($0.phrase)\t\t\t\($0.displayAs)\n" }.joined()
            let data = Data(text.utf8)
            guard data.count <= 50_000 else { throw VocabularyError.invalid("\(language.title)词汇表超过 AWS 的 50 KB 限制，请减少启用词条。") }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let name = resourcePrefix + language.rawValue.lowercased() + "-" + digest.prefix(16)
            return VocabularyPlan(binding: .init(language: language, name: name, digest: digest, entryCount: selected.count),
                                  table: data, key: objectPrefix + name + ".txt")
        }
    }

    public func snapshot(language: RecognitionLanguage, scope: VocabularyScope) throws -> VocabularySnapshot? {
        let plans = try plans().filter { $0.binding.language.applies(to: language) }
        guard !plans.isEmpty else { return nil }
        for plan in plans {
            guard deployments.contains(where: { $0.scope == scope && $0.binding == plan.binding && $0.state == .ready }) else {
                throw VocabularyError.invalid("\(plan.binding.language.title)词汇表尚未在当前 profile／区域同步就绪。请先同步，或关闭本次词汇表选项。")
            }
        }
        return .init(scope: scope, bindings: plans.map(\.binding))
    }

    public mutating func record(_ deployment: VocabularyDeployment) {
        deployments.removeAll { $0.id == deployment.id }
        deployments.append(deployment)
    }

    public func cleanupCandidates(scope: VocabularyScope, retained: [VocabularySnapshot]) throws -> [VocabularyDeployment] {
        let current = Set(try plans().map(\.binding.name))
        // Different profiles may refer to the same AWS account. Preserve any locally referenced name.
        let protected = Set(retained.flatMap(\.bindings).map(\.name))
        return deployments.filter {
            $0.scope == scope && $0.binding.name.hasPrefix(resourcePrefix) && $0.key.hasPrefix(objectPrefix) &&
            !current.contains($0.binding.name) && !protected.contains($0.binding.name)
        }
    }

    public static func validateBucket(_ bucket: String) throws {
        guard bucket.range(of: #"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"#, options: .regularExpression) != nil else {
            throw VocabularyError.invalid("请填写已有的同区域 S3 桶名（不是 s3:// 地址）。")
        }
    }
}

public enum VocabularyError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): message } }
}
