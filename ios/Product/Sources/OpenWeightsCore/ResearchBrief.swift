import Foundation

public struct ResearchStepScope: Codable, Equatable, Sendable {
    public let goalID: UUID
    public let index: Int
    public let question: String
    public let cycleID: UUID?
    public init(goalID: UUID, index: Int, question: String, cycleID: UUID? = nil) { self.goalID = goalID; self.index = index; self.question = question; self.cycleID = cycleID }
}

public struct WebFetchEvidence: Codable, Equatable, Sendable {
    public let requestedURL: String
    public let finalURL: String
    public init(requestedURL: String, finalURL: String) { self.requestedURL = requestedURL; self.finalURL = finalURL }
}

public struct ResearchStepEvidence: Codable, Equatable, Sendable {
    public let index: Int
    public let question: String
    public let sources: [String]
    public init(index: Int, question: String, sources: [String]) { self.index = index; self.question = question; self.sources = sources }
}

public struct ResearchProgress: Codable, Equatable, Sendable {
    public var evidence: [ResearchStepEvidence] = []
    public var cycleID: UUID?
    public init() { cycleID = UUID() }
    public mutating func review(previous: TaskPlan?, proposed: TaskPlan?) -> TaskPlan? {
        let before = evidence
        evidence.removeAll { item in
            guard let proposed, proposed.steps.indices.contains(item.index) else { return true }
            let step = proposed.steps[item.index]
            return !step.done || step.text != item.question
        }
        let result = proposed.map(reviewed)
        // Explicit plan edits request new work. Retry evidence remains reusable
        // until that edit, then old tool messages cannot satisfy a rechecked step.
        if result != previous || before != evidence { cycleID = UUID() }
        return result
    }
    public func verifies(_ plan: TaskPlan) -> Bool {
        plan.isFinished && plan.steps.enumerated().allSatisfy { index, step in
            evidence.contains { $0.index == index && $0.question == step.text && !$0.sources.isEmpty }
        }
    }
    public func sources(for plan: TaskPlan) -> [String] {
        Array(Set(evidence.filter { plan.steps.indices.contains($0.index) && plan.steps[$0.index].text == $0.question && plan.steps[$0.index].done }.flatMap(\.sources))).sorted()
    }
    public func reviewed(_ plan: TaskPlan) -> TaskPlan {
        var value = plan
        for index in value.steps.indices where value.steps[index].done {
            if !evidence.contains(where: { $0.index == index && $0.question == value.steps[index].text && !$0.sources.isEmpty }) {
                value.steps[index].done = false
            }
        }
        return value
    }
}

public enum ResearchBrief {
    public static let plan = "Break this into a short numbered list of specific questions, five at most, that could each be answered by searching the web. Do not answer any of them yet. If you do not already know who or what this is about, that is not a reason to ask first: searching to find out is the research itself, so make it one of the questions instead."
    public static let step = "Research this one question. Search the web, read the best source you find, and report what it says along with the address you found it at. Only state facts that are actually in what you read; do not add a date, a figure, or a name from memory just because it sounds like it belongs. Do not research the other questions."
    public static let toolPrompt = "This step exists to search, not to answer from memory: the plan already decided this question needed one. Search the web for it and read a real source before answering. If the first search does not settle it, change the query and search again rather than answering from what you already believe or saying you cannot know: one weak search is not evidence the answer is unavailable, only that the first query was."
    public static let finish = "Now write the findings up as one document in Markdown. Start with a heading, then the answer in a few short sections. End with a Sources section listing the addresses you used. Do not search again: write only from what you found. If something could not be answered, say so rather than filling the gap."
    public static func fallback(_ question: String) -> TaskPlan {
        var bounded = ""
        for character in question.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard bounded.utf16.count + String(character).utf16.count <= 60 else { break }
            bounded.append(character)
        }
        return TaskPlan(steps: [TaskStep(text: bounded)])
    }
    public static func scopedTools(_ messages: [StoredMessage], scope: ResearchStepScope) -> [StoredMessage] {
        messages.filter { $0.role == .tool && $0.researchStep == scope }
    }
    public static func correlatedSources(_ tools: [StoredMessage]) -> [String] {
        let successful = tools.filter { $0.role == .tool && $0.status == .complete && $0.toolResultCheckpointFailed != true }
        let searched = Set(successful.filter { $0.toolName == "web_search" }.flatMap { $0.searchEvidence?.hits.map(\.url) ?? [] })
        return Array(Set(successful.filter { $0.toolName == "fetch_url" }.compactMap { message in
            guard let read = message.fetchEvidence, searched.contains(read.requestedURL) else { return nil }
            return read.finalURL
        })).sorted()
    }
    public static func refusal(_ tools: [StoredMessage]) -> String? {
        if !correlatedSources(tools).isEmpty { return nil }
        if tools.contains(where: { $0.toolName == "web_search" && $0.status == .complete && $0.searchEvidence != nil }) {
            return "This step searched but never opened a result: fetch one of the addresses the search returned, then answer from what it says."
        }
        return "This step did not get a successful search: search the web for it, then open the best result before answering."
    }
}
