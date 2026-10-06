import Foundation

public struct ScheduledWatch: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case active, paused, stopped, failed, expired }
    public static let maximumActive = 4
    public static let maximumRuns = 60
    public static let maximumFailures = 3
    public static let lifetime: TimeInterval = 72 * 60 * 60
    public let id: UUID
    public var generation: UUID
    public var task: String
    public var everyMinutes: Int
    public var webAuthorization: WatchWebAuthorization?
    public let createdAt: Date
    public var state: State
    public var nextDueAt: Date
    public var lastRunAt: Date?
    public var lastSummary: String?
    public var runs: Int
    public var consecutiveFailures: Int
    public var history: [WatchRun]
    public var claim: WatchClaim?
    public var resultNotice: WatchNotice?
    public var endNotice: WatchNotice?
    public var expiresAt: Date { createdAt.addingTimeInterval(Self.lifetime) }
    public func isSpent(at date: Date) -> Bool { runs >= Self.maximumRuns || date >= expiresAt }
    public init(task: String, everyMinutes: Int, at date: Date, webAuthorization: WatchWebAuthorization? = nil) {
        id = UUID(); generation = UUID(); self.task = task; self.everyMinutes = everyMinutes
        self.webAuthorization = webAuthorization
        createdAt = date; state = .active; nextDueAt = date.addingTimeInterval(Double(everyMinutes) * 60)
        lastRunAt = nil; lastSummary = nil; runs = 0; consecutiveFailures = 0; history = []
        claim = nil; resultNotice = nil; endNotice = nil
    }
}

public struct WatchClaim: Codable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public init(at date: Date) { id = UUID(); startedAt = date }
}

public struct WatchCheckTicket: Equatable, Sendable {
    public let watch: ScheduledWatch
    public let claim: WatchClaim
}

public struct WatchRun: Codable, Equatable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable { case checked, skipped, failed }
    public let id: UUID
    public let at: Date
    public let finishedAt: Date
    public let outcome: Outcome
    public let summary: String
    public let changed: Bool
}

public struct WatchNotice: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case result, ended }
    public let id: UUID
    public let kind: Kind
    public let body: String
}

public enum WatchVerdict {
    public struct Finding: Equatable, Sendable {
        public let summary: String
        public let changed: Bool
    }
    public static func read(_ reply: String, previous: String?) -> Finding {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = try! NSRegularExpression(pattern: "(?:^|\\n)\\s*\\*{0,2}(CHANGED|UNCHANGED)\\*{0,2}[.!]?\\s*$")
        let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        var summary = text
        var verdict: String?
        if let match, let whole = Range(match.range, in: text), let word = Range(match.range(at: 1), in: text) {
            verdict = String(text[word]); summary.removeSubrange(whole)
        }
        summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty { summary = verdict == "UNCHANGED" ? previous ?? "Nothing new." : "Nothing new." }
        let changed = previous == nil || (verdict.map { $0 == "CHANGED" } ?? (summary != previous?.trimmingCharacters(in: .whitespacesAndNewlines)))
        return Finding(summary: summary, changed: changed)
    }
}

public enum WatchError: LocalizedError {
    case invalid(String)
    case missing
    public var errorDescription: String? {
        switch self {
        case .invalid(let text): return text
        case .missing: return "This watch is no longer available."
        }
    }
}

public actor WatchStore {
    private struct Snapshot: Codable {
        var version = 1
        var watches: [ScheduledWatch] = []
    }
    private let file: URL
    private var value: Snapshot
    public init(file: URL, at date: Date = Date()) throws {
        try Self.check(date)
        self.file = file
        var saved = Snapshot()
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count <= Self.maximumBytes else { throw WatchError.invalid("The watch snapshot exceeds its storage limit. Existing data was preserved.") }
            saved = try JSONDecoder().decode(Snapshot.self, from: data)
            try Self.validate(saved)
            var changed = false
            for index in saved.watches.indices {
                var watch = saved.watches[index]
                if [.active, .paused].contains(watch.state), watch.isSpent(at: date) {
                    Self.end(&watch, state: .expired); changed = true
                } else if let claim = watch.claim {
                    Self.record(&watch, claim: claim, outcome: .skipped,
                        summary: "Skipped: the app stopped before this check completed.", at: max(date, claim.startedAt), changed: false)
                    changed = true
                }
                saved.watches[index] = watch
            }
            if changed { try Self.write(saved, to: file) }
        }
        value = saved
    }
    public func list() -> [ScheduledWatch] { value.watches.sorted { $0.createdAt > $1.createdAt } }
    public func watch(_ id: UUID) -> ScheduledWatch? { value.watches.first { $0.id == id } }
    public func due(at date: Date) -> [ScheduledWatch] {
        value.watches.filter { $0.state == .active && $0.claim == nil && !$0.isSpent(at: date) && $0.nextDueAt <= date }
            .sorted { $0.nextDueAt == $1.nextDueAt ? $0.id.uuidString < $1.id.uuidString : $0.nextDueAt < $1.nextDueAt }
    }
    @discardableResult public func start(task: String, everyMinutes: Int, at date: Date = Date(), webAuthorization: WatchWebAuthorization? = nil) throws -> ScheduledWatch {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.check(task: task, minutes: everyMinutes); try Self.check(date); try webAuthorization?.validate()
        var next = value
        Self.expire(&next, at: date)
        guard next.watches.filter({ $0.state == .active }).count < ScheduledWatch.maximumActive else {
            throw WatchError.invalid("Four watches are already active. Pause or stop one before starting another.")
        }
        let watch = ScheduledWatch(task: task, everyMinutes: everyMinutes, at: date, webAuthorization: webAuthorization)
        next.watches.append(watch); try commit(next)
        return watch
    }
    @discardableResult public func edit(_ id: UUID, task: String, everyMinutes: Int, at date: Date = Date(), webAuthorization: WatchWebAuthorization? = nil) throws -> ScheduledWatch {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.check(task: task, minutes: everyMinutes); try Self.check(date); try webAuthorization?.validate()
        return try change(id) { watch in
            guard [.active, .paused].contains(watch.state), !watch.isSpent(at: date) else { throw WatchError.invalid("An ended watch cannot be edited. Start a new watch instead.") }
            let taskChanged = watch.task != task
            watch.task = task; watch.webAuthorization = webAuthorization; watch.everyMinutes = everyMinutes; watch.nextDueAt = date.addingTimeInterval(Double(everyMinutes) * 60)
            watch.generation = UUID(); watch.claim = nil
            // A result from the old task must not become the comparison for the edited task.
            if taskChanged { watch.lastSummary = nil; watch.resultNotice = nil }
        }
    }
    @discardableResult public func pause(_ id: UUID) throws -> ScheduledWatch {
        try change(id) { watch in
            guard watch.state == .active else { return }
            watch.state = .paused; watch.generation = UUID(); watch.claim = nil
        }
    }
    @discardableResult public func resume(_ id: UUID, at date: Date = Date()) throws -> ScheduledWatch {
        try Self.check(date)
        _ = try expire(at: date)
        guard value.watches.filter({ $0.state == .active }).count < ScheduledWatch.maximumActive else {
            throw WatchError.invalid("Four watches are already active. Pause or stop one first.")
        }
        var next = value; Self.expire(&next, at: date)
        guard let index = next.watches.firstIndex(where: { $0.id == id }) else { throw WatchError.missing }
        guard next.watches[index].state == .paused else { throw WatchError.invalid("Only a paused watch with remaining time and checks can resume.") }
        next.watches[index].state = .active; next.watches[index].generation = UUID()
        next.watches[index].nextDueAt = date.addingTimeInterval(Double(next.watches[index].everyMinutes) * 60)
        try commit(next); return next.watches[index]
    }
    @discardableResult public func stop(_ id: UUID) throws -> ScheduledWatch {
        try change(id) { watch in
            guard [.active, .paused].contains(watch.state) else { return }
            watch.state = .stopped; watch.generation = UUID(); watch.claim = nil
        }
    }
    public func forget(_ id: UUID) throws {
        var next = value
        guard let index = next.watches.firstIndex(where: { $0.id == id }) else { throw WatchError.missing }
        next.watches.remove(at: index); try commit(next)
    }
    @discardableResult public func expire(at date: Date = Date()) throws -> [ScheduledWatch] {
        try Self.check(date)
        var next = value; let ended = Self.expire(&next, at: date)
        if !ended.isEmpty { try commit(next) }
        return ended
    }
    public func begin(_ id: UUID, at date: Date = Date()) throws -> WatchCheckTicket? {
        try Self.check(date)
        var next = value
        guard let index = next.watches.firstIndex(where: { $0.id == id }) else { return nil }
        var watch = next.watches[index]
        guard watch.state == .active else { return nil }
        if watch.isSpent(at: date) {
            Self.end(&watch, state: .expired); next.watches[index] = watch; try commit(next); return nil
        }
        guard watch.claim == nil, watch.nextDueAt <= date else { return nil }
        let claim = WatchClaim(at: date); watch.claim = claim
        next.watches[index] = watch; try commit(next)
        return WatchCheckTicket(watch: watch, claim: claim)
    }
    @discardableResult public func record(_ ticket: WatchCheckTicket, outcome: WatchRun.Outcome, summary: String,
                                         at date: Date = Date(), changed: Bool = false) throws -> ScheduledWatch? {
        try Self.check(date)
        var next = value
        guard let index = next.watches.firstIndex(where: { $0.id == ticket.watch.id }) else { return nil }
        var watch = next.watches[index]
        // A paused, edited, removed or already-recorded check cannot publish a late answer.
        guard watch.state == .active, watch.generation == ticket.watch.generation, watch.claim == ticket.claim else { return nil }
        Self.record(&watch, claim: ticket.claim, outcome: outcome, summary: summary, at: max(date, ticket.claim.startedAt), changed: changed)
        next.watches[index] = watch; try commit(next); return watch
    }
    public func acknowledgeNotice(watchID: UUID, noticeID: UUID) throws {
        _ = try change(watchID) { watch in
            if watch.resultNotice?.id == noticeID { watch.resultNotice = nil }
            if watch.endNotice?.id == noticeID { watch.endNotice = nil }
        }
    }
    private func change(_ id: UUID, _ update: (inout ScheduledWatch) throws -> Void) throws -> ScheduledWatch {
        var next = value
        guard let index = next.watches.firstIndex(where: { $0.id == id }) else { throw WatchError.missing }
        try update(&next.watches[index]); try commit(next); return next.watches[index]
    }
    private func commit(_ next: Snapshot) throws {
        try Self.validate(next); try Self.write(next, to: file); value = next
    }
    private static func record(_ watch: inout ScheduledWatch, claim: WatchClaim, outcome: WatchRun.Outcome, summary: String, at date: Date, changed: Bool) {
        let summary = prefix(summary, limit: 400)
        watch.claim = nil
        let run = WatchRun(id: claim.id, at: claim.startedAt, finishedAt: date, outcome: outcome, summary: summary,
                           changed: outcome == .checked && changed)
        watch.history = Array((watch.history + [run]).suffix(20))
        watch.nextDueAt = date.addingTimeInterval(Double(watch.everyMinutes) * 60)
        if outcome != .skipped {
            watch.lastRunAt = claim.startedAt; watch.lastSummary = summary; watch.runs += 1
            watch.consecutiveFailures = outcome == .failed ? watch.consecutiveFailures + 1 : 0
        }
        if outcome == .checked && changed { watch.resultNotice = WatchNotice(id: run.id, kind: .result, body: summary) }
        if watch.consecutiveFailures >= ScheduledWatch.maximumFailures { end(&watch, state: .failed) }
        else if watch.isSpent(at: date) { end(&watch, state: .expired) }
    }
    @discardableResult private static func expire(_ next: inout Snapshot, at date: Date) -> [ScheduledWatch] {
        var ended: [ScheduledWatch] = []
        for index in next.watches.indices where [.active, .paused].contains(next.watches[index].state) && next.watches[index].isSpent(at: date) {
            end(&next.watches[index], state: .expired); ended.append(next.watches[index])
        }
        return ended
    }
    private static func end(_ watch: inout ScheduledWatch, state: ScheduledWatch.State) {
        watch.state = state; watch.generation = UUID(); watch.claim = nil
        let body = state == .failed ? "This watch stopped after three consecutive failed checks." : "This watch ended after \(watch.runs) checks or its 72-hour window."
        watch.endNotice = WatchNotice(id: UUID(), kind: .ended, body: body)
    }
    private static func check(task: String, minutes: Int) throws {
        guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, task.utf16.count <= 16_384 else {
            throw WatchError.invalid("Give a watch task of at most 16,384 characters.")
        }
        guard (1...1440).contains(minutes) else { throw WatchError.invalid("Use an interval between 1 and 1,440 minutes.") }
    }
    private static func check(_ date: Date) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw WatchError.invalid("The watch time is invalid.") }
    }
    private static func validate(_ snapshot: Snapshot) throws {
        guard snapshot.version == 1 else { throw WatchError.invalid("Unsupported watch snapshot version. Existing data was preserved.") }
        guard Set(snapshot.watches.map(\.id)).count == snapshot.watches.count,
              snapshot.watches.filter({ $0.state == .active }).count <= ScheduledWatch.maximumActive else {
            throw WatchError.invalid("Invalid watch snapshot. Existing data was preserved.")
        }
        for watch in snapshot.watches {
            try watch.webAuthorization?.validate()
            try check(task: watch.task, minutes: watch.everyMinutes); try check(watch.createdAt); try check(watch.nextDueAt)
            if let date = watch.lastRunAt { try check(date) }
            guard (0...ScheduledWatch.maximumRuns).contains(watch.runs), (0...ScheduledWatch.maximumFailures).contains(watch.consecutiveFailures),
                  watch.consecutiveFailures <= watch.runs, (watch.lastSummary?.utf16.count ?? 0) <= 400, watch.history.count <= 20,
                  Set(watch.history.map(\.id)).count == watch.history.count, watch.claim == nil || watch.state == .active,
                  (watch.runs == 0) == (watch.lastRunAt == nil),
                  watch.history.filter({ $0.outcome != .skipped }).count <= watch.runs,
                  watch.resultNotice == nil || watch.resultNotice?.kind == .result,
                  watch.endNotice == nil || (watch.endNotice?.kind == .ended && [.expired, .failed].contains(watch.state)),
                  watch.state != .active || (watch.runs < ScheduledWatch.maximumRuns && watch.consecutiveFailures < ScheduledWatch.maximumFailures) else {
                throw WatchError.invalid("Invalid watch counters or pending check. Existing data was preserved.")
            }
            if let claim = watch.claim { try check(claim.startedAt) }
            for run in watch.history {
                try check(run.at); try check(run.finishedAt)
                guard run.finishedAt >= run.at, run.summary.utf16.count <= 400, !run.changed || run.outcome == .checked else {
                    throw WatchError.invalid("Invalid watch history. Existing data was preserved.")
                }
            }
            for notice in [watch.resultNotice, watch.endNotice].compactMap({ $0 }) {
                guard notice.body.utf16.count <= 400 else { throw WatchError.invalid("Invalid watch notice. Existing data was preserved.") }
            }
        }
    }
    private static let maximumBytes = 8 * 1024 * 1024
    private static func write(_ snapshot: Snapshot, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumBytes else { throw WatchError.invalid("Watch storage is full. Remove older watches before adding more.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
    private static func prefix(_ text: String, limit: Int) -> String {
        var result = ""; var size = 0
        for character in text {
            let count = String(character).utf16.count
            guard size + count <= limit else { break }
            result.append(character); size += count
        }
        return result
    }
}
