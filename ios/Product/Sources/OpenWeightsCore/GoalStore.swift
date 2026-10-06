import Foundation

public struct WorkGoal: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case planning, working, writing, done, stopped, halted }
    public static let maximumSteps = 12
    public static let maximumFailures = 2
    public let id: UUID
    public let conversationID: UUID
    public let task: String
    public var plan: TaskPlan?
    public var stepsTaken: Int
    public var state: State
    public var note: String?
    public var steering: [String]
    public var research: ResearchProgress?
    public var planReviewID: UUID?
    public var isRunning: Bool { state == .planning || state == .working || state == .writing }
    public var hasBudget: Bool { stepsTaken < Self.maximumSteps }
    public init(task: String, conversationID: UUID, research: Bool = false) {
        self.id = UUID(); self.conversationID = conversationID; self.task = task
        self.plan = nil; self.stepsTaken = 0; self.state = .planning; self.note = nil; self.steering = []; self.research = research ? ResearchProgress() : nil
    }
    public static func shouldRetry(failures: Int, tools: [StoredMessage]) -> Bool {
        failures < maximumFailures && !tools.contains { $0.toolResultCheckpointFailed == true }
    }
    public static func stepRefusal(before: TaskPlan, after: TaskPlan, tools: [StoredMessage]) -> String? {
        if tools.contains(where: { $0.toolResultCheckpointFailed == true }) {
            return "A tool result could not be checkpointed. Inspect its actual result before resuming."
        }
        guard before.steps.map(\.text) == after.steps.map(\.text),
              let next = before.steps.firstIndex(where: { !$0.done }) else { return "The step changed the plan instead of completing its assigned action." }
        let newlyDone = after.steps.indices.filter { after.steps[$0].done && !before.steps[$0].done }
        if !newlyDone.isEmpty && newlyDone != [next] { return "This step closed more than the one it was given, so it was not marked done." }
        if before.steps.indices.contains(where: { before.steps[$0].done && !after.steps[$0].done }) {
            return "This step reopened completed work, so it was not marked done."
        }
        if tools.contains(where: { $0.toolName == "advance" }) && newlyDone.isEmpty {
            return "This step's advance call did not close the step it was given, so it was not marked done."
        }
        if !tools.isEmpty && tools.allSatisfy({ $0.status != .complete }) {
            return "This step's tool calls did not succeed, so it was not marked done."
        }
        return nil
    }
}

public struct GoalSnapshot: Codable, Equatable, Sendable {
    public var version = 1
    public var revision: UInt64
    public var goal: WorkGoal?
    public init(revision: UInt64, goal: WorkGoal?) { self.revision = revision; self.goal = goal }
}

public enum GoalError: LocalizedError {
    case invalid(String)
    case stale
    public var errorDescription: String? {
        switch self { case .invalid(let text): return text; case .stale: return "This goal is no longer active." }
    }
}

public actor GoalStore {
    private let file: URL
    private var value: GoalSnapshot
    public init(file: URL) throws {
        self.file = file
        var snapshot = GoalSnapshot(revision: 0, goal: nil)
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count <= 131_072 else { throw GoalError.invalid("The goal snapshot exceeds its storage limit. Existing data was preserved.") }
            snapshot = try JSONDecoder().decode(GoalSnapshot.self, from: data)
            try Self.validate(snapshot)
            if snapshot.goal?.isRunning == true {
                snapshot.goal?.state = .halted
                snapshot.goal?.note = "Interrupted when the app stopped. Review the plan and actual results before resuming."
                guard snapshot.revision < UInt64.max else { throw GoalError.invalid("The goal revision cannot advance.") }
                snapshot.revision += 1
                try Self.write(snapshot, to: file)
            }
        }
        value = snapshot
    }
    public func snapshot() -> GoalSnapshot { value }
    @discardableResult public func start(task: String, conversationID: UUID, research: Bool = false) throws -> GoalSnapshot {
        guard value.goal?.isRunning != true else { throw GoalError.invalid("Stop the current goal before starting another.") }
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, task.utf16.count <= 16_384 else { throw GoalError.invalid("Give a task of at most 16,384 characters.") }
        return try commit(WorkGoal(task: task, conversationID: conversationID, research: research))
    }
    @discardableResult public func planned(_ plan: TaskPlan, expectedID: UUID) throws -> GoalSnapshot {
        var goal = try active(expectedID)
        goal.plan = goal.research?.reviewed(plan) ?? plan
        goal.state = goal.plan!.isFinished ? (goal.research == nil ? .done : .writing) : .working; goal.note = nil
        return try commit(goal)
    }
    @discardableResult public func advanced(_ plan: TaskPlan, expectedID: UUID, sources: [String] = []) throws -> GoalSnapshot {
        var goal = try active(expectedID)
        guard goal.hasBudget else { throw GoalError.invalid("The goal has spent its step budget.") }
        if var research = goal.research {
            guard let before = goal.plan, let index = before.steps.firstIndex(where: { !$0.done }),
                  WorkGoal.stepRefusal(before: before, after: plan, tools: []) == nil, plan.steps[index].done, !sources.isEmpty else {
                throw GoalError.invalid("Research cannot advance without a fetched search result for its assigned question.")
            }
            research.evidence.removeAll { $0.index == index }
            research.evidence.append(ResearchStepEvidence(index: index, question: before.steps[index].text, sources: sources))
            goal.research = research
        }
        goal.plan = plan; goal.stepsTaken += 1
        if plan.isFinished { goal.state = goal.research == nil ? .done : .writing }
        else if !goal.hasBudget { goal.state = .halted; goal.note = "Stopped after 12 steps. Review the results before starting another goal." }
        return try commit(goal)
    }
    @discardableResult public func reviewPlan(_ plan: TaskPlan?, expectedID: UUID) throws -> GoalSnapshot {
        guard var goal = value.goal, goal.id == expectedID, !goal.isRunning else { throw GoalError.stale }
        let previous = goal.plan
        if var research = goal.research {
            goal.plan = research.review(previous: previous, proposed: plan); goal.research = research
        } else { goal.plan = plan }
        if goal.plan != previous { goal.planReviewID = UUID() }
        if goal.state == .done, goal.plan != previous {
            goal.state = .halted; goal.note = "The plan changed. Review it before resuming."
        }
        return try commit(goal)
    }
    @discardableResult public func resume(plan: TaskPlan?, expectedID: UUID) throws -> GoalSnapshot {
        guard var goal = value.goal, goal.id == expectedID, [.halted, .stopped].contains(goal.state), goal.hasBudget else { throw GoalError.stale }
        let previous = goal.plan
        if var research = goal.research {
            goal.plan = research.review(previous: goal.plan, proposed: plan); goal.research = research
        } else { goal.plan = plan }
        if goal.plan != previous { goal.planReviewID = UUID() }
        goal.state = goal.plan == nil ? .planning : goal.plan!.isFinished ? (goal.research == nil ? .done : .writing) : .working
        goal.note = nil
        return try commit(goal)
    }
    @discardableResult public func finishResearch(expectedID: UUID) throws -> GoalSnapshot {
        var goal = try active(expectedID)
        guard goal.state == .writing, let plan = goal.plan, goal.research?.verifies(plan) == true else {
            throw GoalError.invalid("Every research question needs verified sources before the report can finish.")
        }
        goal.state = .done; goal.note = nil
        return try commit(goal)
    }
    @discardableResult public func stop(expectedID: UUID) throws -> GoalSnapshot { try finish(.stopped, note: nil, expectedID: expectedID) }
    @discardableResult public func halt(_ note: String, expectedID: UUID) throws -> GoalSnapshot { try finish(.halted, note: note, expectedID: expectedID) }
    private func finish(_ state: WorkGoal.State, note: String?, expectedID: UUID) throws -> GoalSnapshot {
        guard var goal = value.goal, goal.id == expectedID else { throw GoalError.stale }
        if goal.state == .done { return value }
        goal.state = state; goal.note = note.map { Self.prefix($0, limit: 4_096) }
        return try commit(goal)
    }
    @discardableResult public func clear(expectedID: UUID) throws -> GoalSnapshot {
        guard value.goal?.id == expectedID, value.goal?.isRunning != true else { throw GoalError.stale }
        return try commit(nil)
    }
    @discardableResult public func steer(_ message: String, expectedID: UUID) throws -> GoalSnapshot {
        var goal = try active(expectedID)
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return value }
        goal.steering = Array((goal.steering + [Self.prefix(message, limit: 500)]).suffix(16))
        return try commit(goal)
    }
    public func takeSteering(expectedID: UUID) throws -> (GoalSnapshot, [String]) {
        var goal = try active(expectedID)
        let messages = goal.steering; goal.steering = []
        return (try commit(goal), messages)
    }
    private func active(_ expectedID: UUID) throws -> WorkGoal {
        guard let goal = value.goal, goal.id == expectedID, goal.isRunning else { throw GoalError.stale }
        return goal
    }
    private func commit(_ goal: WorkGoal?) throws -> GoalSnapshot {
        guard value.revision < UInt64.max else { throw GoalError.invalid("The goal revision cannot advance.") }
        let next = GoalSnapshot(revision: value.revision + 1, goal: goal)
        try Self.validate(next); try Self.write(next, to: file)
        value = next
        return next
    }
    private static func validate(_ value: GoalSnapshot) throws {
        guard value.version == 1 else { throw GoalError.invalid("Unsupported goal snapshot version. Existing data was preserved.") }
        guard let goal = value.goal else { return }
        if let research = goal.research {
            guard research.evidence.count <= 5, Set(research.evidence.map(\.index)).count == research.evidence.count,
                  research.evidence.allSatisfy({ item in
                      (0..<5).contains(item.index) && !item.question.isEmpty && item.question.utf16.count <= 60 &&
                      !item.sources.isEmpty && item.sources.count <= 6 && item.sources.allSatisfy { source in
                          source.utf16.count <= 2_048 && (try? PublicWebAddress(source)) != nil
                      }
                  }), (goal.state != .writing && goal.state != .done) || goal.plan.map(research.verifies) == true else {
                throw GoalError.invalid("Invalid research evidence. Existing data was preserved.")
            }
        } else if goal.state == .writing { throw GoalError.invalid("A regular goal cannot enter research writing.") }
        guard !goal.task.isEmpty, goal.task.utf16.count <= 16_384, (0...WorkGoal.maximumSteps).contains(goal.stepsTaken),
              (goal.note?.utf16.count ?? 0) <= 4_096, goal.steering.count <= 16,
              goal.steering.allSatisfy({ $0.utf16.count <= 500 }),
              goal.plan.map({ !$0.steps.isEmpty && $0.steps.count <= 5 && $0.steps.allSatisfy { !$0.text.isEmpty && $0.text.utf16.count <= 60 } }) ?? true else {
            throw GoalError.invalid("Invalid goal snapshot. Existing data was preserved.")
        }
    }
    private static func write(_ value: GoalSnapshot, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 131_072 else { throw GoalError.invalid("The goal exceeds its storage limit.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
    private static func prefix(_ text: String, limit: Int) -> String {
        var result = ""
        for character in text {
            guard result.utf16.count + String(character).utf16.count <= limit else { break }
            result.append(character)
        }
        return result
    }
}
