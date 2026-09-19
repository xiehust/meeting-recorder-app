import Foundation
import MeetingCore
import MeetingCloud

extension AppStore {
    func recordingHotwords(language: RecognitionLanguage) -> [String] {
        vocabularyLibrary.entries.filter { $0.enabled && $0.language.applies(to: language) }.prefix(5000)
            .map { $0.displayAs.isEmpty ? $0.phrase.replacingOccurrences(of: "-", with: " ") : $0.displayAs }
    }
    /// Conservative UTF-8 budget for the streaming endpoint's 100-token hotword limit.
    func doubaoHotwords(language: RecognitionLanguage) -> [String] {
        var remaining = 80, result: [String] = []
        for entry in vocabularyLibrary.entries where entry.enabled && entry.language.applies(to: language) {
            let word = entry.displayAs.isEmpty ? entry.phrase.replacingOccurrences(of: "-", with: " ") : entry.displayAs
            let count = word.utf8.count + 1
            if count <= remaining { result.append(word); remaining -= count }
        }
        return result
    }
    var vocabularyScope: VocabularyScope { .init(profile: settings.profile, region: settings.transcribeRegion) }

    func loadVocabularyLibrary() {
        guard let data = UserDefaults.standard.data(forKey: "customVocabularyLibrary") else { return }
        do {
            let library = try JSONDecoder().decode(CustomVocabularyLibrary.self, from: data)
            guard Set(library.entries.map(\.id)).count == library.entries.count else { throw VocabularyError.invalid("词条 ID 重复。") }
            _ = try library.plans()
            vocabularyLibrary = library
            vocabularyStatus = vocabularyReadiness(language: .multilingual)
        } catch {
            vocabularyLibraryError = "全局词汇表读取失败，原数据已保留。请检查本地设置后重新打开应用。"
        }
    }

    func persistVocabulary(_ library: CustomVocabularyLibrary) throws {
        if let vocabularyLibraryError { throw VocabularyError.invalid(vocabularyLibraryError) }
        UserDefaults.standard.set(try JSONEncoder().encode(library), forKey: "customVocabularyLibrary")
        vocabularyLibrary = library
        if !vocabularyBusy { vocabularyStatus = vocabularyReadiness(language: .multilingual) }
    }

    func saveVocabularyEntry(_ entry: VocabularyEntry) throws {
        guard !vocabularyBusy else { throw VocabularyError.invalid("同步进行中，请稍后编辑。") }
        var next = vocabularyLibrary
        try next.save(entry)
        try persistVocabulary(next)
    }

    func deleteVocabularyEntry(_ id: UUID) {
        guard !vocabularyBusy else { return }
        var next = vocabularyLibrary; next.entries.removeAll { $0.id == id }
        do { try persistVocabulary(next) } catch { vocabularyError = error.localizedDescription }
    }

    func importVocabulary(_ text: String, language: VocabularyLanguage) throws -> Int {
        guard !vocabularyBusy else { throw VocabularyError.invalid("同步进行中，请稍后编辑。") }
        var next = vocabularyLibrary
        let count = try next.importLines(text, language: language)
        try persistVocabulary(next)
        return count
    }

    func setVocabularyOptions(bucket: String? = nil, useByDefault: Bool? = nil) {
        guard !vocabularyBusy else { return }
        var next = vocabularyLibrary
        if let bucket { next.bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let useByDefault { next.useByDefault = useByDefault }
        do { try persistVocabulary(next) } catch { vocabularyError = error.localizedDescription }
    }

    func vocabularyReadiness(language: RecognitionLanguage) -> String {
        if let vocabularyLibraryError { return vocabularyLibraryError }
        do {
            return try vocabularyLibrary.snapshot(language: language, scope: vocabularyScope)
                .map { "已就绪 · \($0.description)" } ?? "当前语言暂无启用词条，按普通方式转录"
        } catch { return error.localizedDescription }
    }

    func synchronizeVocabulary(bucket: String) {
        guard !vocabularyBusy else { return }
        setVocabularyOptions(bucket: bucket)
        let library = vocabularyLibrary
        let scope = vocabularyScope
        let plans: [VocabularyPlan]
        do {
            if let vocabularyLibraryError { throw VocabularyError.invalid(vocabularyLibraryError) }
            try CustomVocabularyLibrary.validateBucket(library.bucket)
            plans = try library.plans()
            guard !plans.isEmpty else { throw VocabularyError.invalid("请先添加并启用至少一个词条。") }
        } catch { vocabularyError = error.localizedDescription; return }
        vocabularyBusy = true; vocabularyError = nil; vocabularyStatus = "正在连接 AWS…"
        vocabularyTask = Task { [weak self] in
            guard let self else { return }
            defer { self.vocabularyBusy = false; self.vocabularyTask = nil }
            do {
                let service = VocabularyService(remote: try await AWSVocabularyRemote(scope: scope))
                try await service.synchronize(plans: plans, scope: scope, bucket: library.bucket,
                                              previous: library.deployments) { [weak self] deployment in
                    try await self?.recordVocabularyDeployment(deployment)
                }
                self.vocabularyStatus = "同步完成，新录音可使用已就绪词汇表。"
            } catch { self.vocabularyError = VocabularyService.userMessage(error); self.vocabularyStatus = "同步未完成" }
        }
    }

    private func recordVocabularyDeployment(_ deployment: VocabularyDeployment) throws {
        var next = vocabularyLibrary; next.record(deployment)
        try persistVocabulary(next)
        vocabularyStatus = "\(deployment.binding.language.title)：\(deployment.state.title)"
    }

    var vocabularyCleanupCandidates: [VocabularyDeployment] {
        guard ready else { return [] }
        return (try? vocabularyLibrary.cleanupCandidates(scope: vocabularyScope,
            retained: meetings.compactMap(\.settings.transcriptionVocabulary)
                + meetings.flatMap { ($0.batchVersions ?? []).compactMap(\.settings.transcriptionVocabulary) })) ?? []
    }

    func cleanOldVocabularyVersions() {
        guard ready, !starting, !vocabularyBusy else { return }
        let candidates = vocabularyCleanupCandidates
        guard !candidates.isEmpty else { return }
        let scope = vocabularyScope
        vocabularyBusy = true; vocabularyError = nil
        vocabularyTask = Task { [weak self] in
            guard let self else { return }
            defer { self.vocabularyBusy = false; self.vocabularyTask = nil }
            do {
                let remote = try await AWSVocabularyRemote(scope: scope)
                for candidate in candidates {
                    try Task.checkCancellation()
                    self.vocabularyStatus = "正在清理 \(candidate.binding.language.title)旧版本…"
                    try await remote.delete(candidate)
                    var next = self.vocabularyLibrary; next.deployments.removeAll { $0.id == candidate.id }
                    try self.persistVocabulary(next)
                }
                self.vocabularyStatus = "已清理 \(candidates.count) 个未使用的旧版本。"
            } catch { self.vocabularyError = VocabularyService.userMessage(error) }
        }
    }
}
