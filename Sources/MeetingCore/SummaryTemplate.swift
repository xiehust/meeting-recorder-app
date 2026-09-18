import Foundation

public enum SummarySectionKind: String, Codable, CaseIterable, Sendable {
    case points, decisions, actions, questions
    public var title: String {
        switch self {
        case .points: "要点"
        case .decisions: "明确决策"
        case .actions: "行动项（负责人／日期）"
        case .questions: "待确认问题"
        }
    }
}

public struct SummaryTemplateSection: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var kind: SummarySectionKind
    public var instructions: String
    public init(id: String = UUID().uuidString, title: String, kind: SummarySectionKind = .points, instructions: String = "") {
        self.id = id; self.title = title; self.kind = kind; self.instructions = instructions
    }
}

public struct SummaryTemplate: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var instructions: String
    public var overviewTitle: String
    public var sections: [SummaryTemplateSection]
    public var revision: Int
    public var isBuiltIn: Bool { id.hasPrefix("builtin.") }
    public var selectionKey: String { "\(id)@\(revision)" }
    public var displayName: String { isBuiltIn ? L10n.text(name) : name }
    public var displayInstructions: String { isBuiltIn ? L10n.text(instructions) : instructions }
    public var displayOverviewTitle: String { isBuiltIn ? L10n.text(overviewTitle) : overviewTitle }
    public var displaySectionTitles: [String] { sections.map { isBuiltIn ? L10n.text($0.title) : $0.title } }
    public func displayTitle(for section: SummaryTemplateSection) -> String {
        isBuiltIn ? L10n.text(section.title) : section.title
    }
    public func displayInstructions(for section: SummaryTemplateSection) -> String {
        isBuiltIn ? L10n.text(section.instructions) : section.instructions
    }
    /// A new user-owned copy may start in the current interface language; the source snapshot is untouched.
    public func localizedDuplicate() -> SummaryTemplate {
        .init(name: displayName + L10n.tr("（副本）"), instructions: displayInstructions,
              overviewTitle: displayOverviewTitle, sections: sections.map {
                  .init(id: $0.id, title: displayTitle(for: $0), kind: $0.kind, instructions: displayInstructions(for: $0))
              })
    }

    public init(id: String = "custom." + UUID().uuidString, name: String, instructions: String,
                overviewTitle: String = "概览", sections: [SummaryTemplateSection], revision: Int = 1) {
        self.id = id; self.name = name; self.instructions = instructions
        self.overviewTitle = overviewTitle; self.sections = sections; self.revision = revision
    }

    public func validated() throws -> SummaryTemplate {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        value.overviewTitle = overviewTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, revision >= 1, !value.name.isEmpty, value.name.count <= 80,
              !value.instructions.isEmpty, value.instructions.count <= 6_000,
              !value.overviewTitle.isEmpty, value.overviewTitle.count <= 100 else {
            throw SummaryTemplateError.invalid("请填写模板名称、总结要求和概览标题；名称最多 80 字，总结要求最多 6000 字。")
        }
        guard (1...16).contains(sections.count), Set(sections.map(\.id)).count == sections.count else {
            throw SummaryTemplateError.invalid("模板需包含 1–16 个章节，章节标识不能重复。")
        }
        for index in value.sections.indices {
            value.sections[index].title = value.sections[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
            let section = value.sections[index]
            guard !section.id.isEmpty, !section.title.isEmpty, section.title.count <= 100, section.instructions.count <= 2_000 else {
                throw SummaryTemplateError.invalid("每个章节需有标题；标题最多 100 字，章节要求最多 2000 字。")
            }
        }
        guard value.instructions.count + value.sections.reduce(0, { $0 + $1.instructions.count }) <= 12_000 else {
            throw SummaryTemplateError.invalid("模板要求总长度不能超过 12000 字。")
        }
        return value
    }

    public func duplicate() -> SummaryTemplate {
        .init(name: name + "（副本）", instructions: instructions, overviewTitle: overviewTitle, sections: sections)
    }

    public func outputOverviewTitle(language: String) -> String {
        if language == SummaryLanguage.japanese.rawValue, isBuiltIn { return L10n.text(overviewTitle, language: .japanese) }
        guard language == "English", isBuiltIn else { return overviewTitle }
        switch id {
        case Self.interview.id: return "Interview overview"
        case Self.training.id: return "Training overview"
        default: return "Meeting overview"
        }
    }

    public func outputTitle(for section: SummaryTemplateSection, language: String) -> String {
        if language == SummaryLanguage.japanese.rawValue, isBuiltIn { return L10n.text(section.title, language: .japanese) }
        guard language == "English", isBuiltIn else { return section.title }
        let titles: [String: [String: String]] = [
            "builtin.meeting": ["topics": "Discussion", "decisions": "Confirmed decisions", "actions": "Action items", "questions": "Open questions"],
            "builtin.interview": ["experience": "Candidate experience and responsibilities", "qa": "Key questions and answers",
                                 "evidence": "Job-related evidence", "strengths": "Demonstrated strengths",
                                 "followup": "Verification and follow-up questions", "next": "Agreed next steps"],
            "builtin.training": ["objectives": "Objectives and knowledge framework", "knowledge": "Key concepts",
                                "steps": "Procedures and examples", "qa": "Learner questions and answers",
                                "practice": "Practice and assignments", "questions": "Open questions and missing information"]
        ]
        return titles[id]?[section.id] ?? section.title
    }

    public static var blank: SummaryTemplate {
        .init(name: "", instructions: "", sections: [.init(title: "关键内容", instructions: "归纳有原文依据的关键内容。")])
    }

    public static let meeting = SummaryTemplate(
        id: "builtin.meeting", name: "会议纪要",
        instructions: "整理会议目的、关键讨论、明确达成的决策、行动项和待确认问题。区分讨论建议与最终决定，突出下一步工作；未明确的负责人和日期留空。",
        overviewTitle: "会议概览",
        sections: [
            .init(id: "topics", title: "主要议题", instructions: "按主题归纳讨论重点与不同意见。"),
            .init(id: "decisions", title: "已确认决策", kind: .decisions, instructions: "只列明确达成的决定，不把建议或条件写成确定承诺。"),
            .init(id: "actions", title: "行动项", kind: .actions, instructions: "记录任务、明确负责人及原文中的截止日期。"),
            .init(id: "questions", title: "待确认问题", kind: .questions, instructions: "保留分歧、缺失信息与后续需要确认的问题。")
        ])
    public static let interview = SummaryTemplate(
        id: "builtin.interview", name: "面试纪要（面试官视角）",
        instructions: "从面试官视角整理与岗位相关的面试记录。区分候选人自述、回答中展示的证据和仍需核实的信息；能力评价必须引用回答依据，避免人格推测。不依据年龄、性别、婚育、种族、健康等敏感信息作评价。不编造岗位标准、评分或录用／淘汰结论，招聘判断由面试官确认。",
        overviewTitle: "面试概览",
        sections: [
            .init(id: "experience", title: "候选人经历与职责", instructions: "记录候选人描述的项目、角色和工作范围，明确这些是自述。"),
            .init(id: "qa", title: "关键问题与回答", instructions: "成对归纳面试问题、回答、追问和补充，保留重要细节。"),
            .init(id: "evidence", title: "岗位能力证据", instructions: "按专业知识、问题分析、实践经验等已涉及维度整理证据，不虚构评价标准。"),
            .init(id: "strengths", title: "表现亮点", instructions: "仅列回答或演示中有明确依据的岗位相关亮点，区分观察与推断。"),
            .init(id: "followup", title: "待核实与追问", kind: .questions, instructions: "列出回答不充分、证据不足及可供面试官进一步追问的问题。"),
            .init(id: "next", title: "已约定的后续事项", kind: .actions, instructions: "只列双方明确约定的材料、补充说明或后续沟通，不自动给出录用结论。")
        ])
    public static let training = SummaryTemplate(
        id: "builtin.training", name: "培训纪要",
        instructions: "面向学员整理便于复习的培训记录，突出学习目标、知识框架、核心概念、操作步骤、案例、问答和课后实践。仅依据实际讲授内容，不补写未讲解的知识，不把学员疑问当成讲师结论；步骤有缺失时明确标为待补充。",
        overviewTitle: "培训概览",
        sections: [
            .init(id: "objectives", title: "培训目标与知识框架", instructions: "归纳实际说明的目标、适用场景与知识脉络。"),
            .init(id: "knowledge", title: "核心知识点", instructions: "整理关键概念、原理、注意事项和易错点。"),
            .init(id: "steps", title: "操作步骤与案例", instructions: "按讲授顺序整理操作步骤、示例和案例结果，不补全未讲解的步骤。"),
            .init(id: "qa", title: "学员问答", instructions: "区分学员问题与讲师回答，未回答的问题列为未解决。"),
            .init(id: "practice", title: "课后实践与任务", kind: .actions, instructions: "只记录实际布置的练习或后续任务，负责人和期限未明确则留空。"),
            .init(id: "questions", title: "待补充与待确认", kind: .questions, instructions: "整理未解答的问题、缺失步骤与后续需要补充的资料。")
        ])
    public static let builtIns: [SummaryTemplate] = [.meeting, .interview, .training]
}

public enum SummaryTemplateError: LocalizedError {
    case invalid(String), builtInReadOnly, duplicateName
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .builtInReadOnly: "内置模板只读，请复制为自定义模板后修改。"
        case .duplicateName: "已有同名模板，请换一个名称。"
        }
    }
}

public struct SummaryTemplateLibrary: Codable, Sendable {
    public private(set) var custom: [SummaryTemplate] = []
    public var all: [SummaryTemplate] { SummaryTemplate.builtIns + custom }
    public init() {}
    @discardableResult public mutating func save(_ draft: SummaryTemplate) throws -> SummaryTemplate {
        guard !draft.isBuiltIn, draft.id.hasPrefix("custom.") else { throw SummaryTemplateError.builtInReadOnly }
        var value = try draft.validated()
        guard !all.contains(where: { $0.id != value.id && $0.name.localizedCaseInsensitiveCompare(value.name) == .orderedSame }) else {
            throw SummaryTemplateError.duplicateName
        }
        if let index = custom.firstIndex(where: { $0.id == value.id }) {
            let previous = custom[index]
            value.revision = previous.revision
            if value == previous { return previous }
            value.revision += 1
            custom[index] = value
        } else { value.revision = 1; custom.append(value) }
        return value
    }
    public mutating func delete(id: String) throws {
        guard !id.hasPrefix("builtin.") else { throw SummaryTemplateError.builtInReadOnly }
        custom.removeAll { $0.id == id }
    }
    public func validateLoaded() throws {
        guard Set(custom.map(\.id)).count == custom.count else { throw SummaryTemplateError.invalid("模板库包含重复标识。") }
        for value in custom {
            guard value.id.hasPrefix("custom.") else { throw SummaryTemplateError.builtInReadOnly }
            _ = try value.validated()
        }
    }
}
