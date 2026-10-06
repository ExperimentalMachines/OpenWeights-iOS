import Foundation
import Combine
import OpenWeightsCore

enum WatchNotificationAuthorization: String {
    case notRequested, enabled, denied, unavailable
    var label: String {
        switch self { case .notRequested: return "Not requested"; case .enabled: return "Enabled"; case .denied: return "Off in Settings"; case .unavailable: return "Unavailable" }
    }
}
@MainActor protocol WatchScheduling: AnyObject {
    var authorization: WatchNotificationAuthorization { get }
    var schedulingWarning: String? { get }
    func update(_ watches: [ScheduledWatch], at date: Date) async throws
    func post(_ notice: WatchNotice, watch: ScheduledWatch) async throws -> Bool
    func requestPermission() async throws
}
extension WatchScheduling { var schedulingWarning: String? { nil } }
struct WatchCheckResult {
    let outcome: WatchRun.Outcome
    let summary: String
    var changed = false
}

@MainActor final class WatchController: ObservableObject {
    @Published private(set) var watches: [ScheduledWatch] = []
    @Published private(set) var checkingID: UUID?
    @Published private(set) var updating = false
    @Published private(set) var notifications = WatchNotificationAuthorization.notRequested
    @Published private(set) var schedulingWarning: String?
    @Published var error: String?
    @Published var toolEnabled: Bool { didSet { defaults.set(toolEnabled, forKey: "tools.watch.enabled") } }
    let store: WatchStore
    private let tools: WatchTools
    private let defaults: UserDefaults
    private let scheduler: (any WatchScheduling)?
    private weak var chat: ChatController?
    private var timer: Task<Void, Never>?
    private var loopActive = false
    private var checkingBackground = false
    private var foreground = false
    private var refreshEpoch = UUID()
    private var backgroundEpoch: UUID?
    private let clock: () -> Date
    init(store: WatchStore, defaults: UserDefaults = .standard, scheduler: (any WatchScheduling)? = nil, clock: @escaping () -> Date = Date.init) {
        self.store = store; tools = WatchTools(store: store); self.defaults = defaults; self.scheduler = scheduler; self.clock = clock
        toolEnabled = defaults.bool(forKey: "tools.watch.enabled")
    }
    deinit { timer?.cancel() }
    func bind(_ chat: ChatController) { self.chat = chat }
    var definitions: [AgentToolDefinition] { toolEnabled ? WatchToolDefinitions.all : [] }
    func restore() async { await refresh() }
    func refresh() async {
        let epoch = UUID(); refreshEpoch = epoch
        let saved = await store.list()
        guard epoch == refreshEpoch else { return }
        watches = saved
        do {
            try await scheduler?.update(saved, at: clock())
            guard epoch == refreshEpoch else { return }
            notifications = scheduler?.authorization ?? .unavailable
            schedulingWarning = scheduler?.schedulingWarning
            for watch in saved {
                for notice in [watch.resultNotice, watch.endNotice].compactMap({ $0 }) {
                    guard epoch == refreshEpoch else { return }
                    let current = await store.watch(watch.id)
                    guard current?.resultNotice?.id == notice.id || current?.endNotice?.id == notice.id else { continue }
                    if try await scheduler?.post(notice, watch: watch) == true {
                        try await store.acknowledgeNotice(watchID: watch.id, noticeID: notice.id)
                    }
                }
            }
        } catch { if epoch == refreshEpoch { self.error = error.localizedDescription } }
        if epoch == refreshEpoch { watches = await store.list() }
    }
    var webAuthorizationDisclosure: String {
        guard let web = chat?.web else { return "Web tools are unavailable." }
        return "Search queries go to: \(web.providerLabels). \(web.proxyDisclosure) Page addresses connect directly without cookies or credentials."
    }
    func webAuthorization(pages: String, queries: String) throws -> WatchWebAuthorization? {
        func lines(_ text: String) -> [String] { text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        let pageLines = lines(pages), queryLines = lines(queries)
        guard !pageLines.isEmpty || !queryLines.isEmpty else { return nil }
        guard let web = chat?.web else { throw WatchError.invalid("Web tools are unavailable.") }
        return try web.watchAuthorization(pages: pageLines, queries: queryLines)
    }
    @discardableResult func create(task: String, everyMinutes: Int, webAuthorization: WatchWebAuthorization? = nil) async -> Bool {
        await mutate { _ = try await self.store.start(task: task, everyMinutes: everyMinutes, at: self.clock(), webAuthorization: webAuthorization) }
    }
    @discardableResult func edit(_ id: UUID, task: String, everyMinutes: Int, webAuthorization: WatchWebAuthorization? = nil) async -> Bool {
        await mutate { _ = try await self.store.edit(id, task: task, everyMinutes: everyMinutes, at: self.clock(), webAuthorization: webAuthorization); self.cancelCheck(id) }
    }
    func pause(_ id: UUID) async { _ = await mutate { _ = try await self.store.pause(id); self.cancelCheck(id) } }
    func resume(_ id: UUID) async { _ = await mutate { _ = try await self.store.resume(id, at: self.clock()) } }
    func stop(_ id: UUID) async { _ = await mutate { _ = try await self.store.stop(id); self.cancelCheck(id) } }
    func forget(_ id: UUID) async { _ = await mutate { try await self.store.forget(id); self.cancelCheck(id) } }
    private func mutate(_ operation: () async throws -> Void) async -> Bool {
        guard !updating else { return false }
        updating = true; error = nil
        defer { updating = false }
        do { try await operation(); await refresh(); return true }
        catch { self.error = error.localizedDescription; await refresh(); return false }
    }
    func execute(_ call: AgentToolCall, mode: AgentMode, approval: ApprovedToolCall?) async -> ToolResult {
        let result = await tools.execute(call, enabled: toolEnabled, mode: mode, approval: approval, at: clock())
        await refresh(); return result
    }
    func requestNotifications() async {
        guard !updating else { return }
        updating = true; error = nil
        defer { updating = false }
        do { try await scheduler?.requestPermission(); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func setForeground(_ active: Bool) {
        foreground = active; timer?.cancel(); timer = nil
        if !active { if !checkingBackground, let id = checkingID { cancelCheck(id) }; return }
        timer = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                await self?.runDue(background: false)
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }
    func cancelCheck(_ id: UUID) { if checkingID == id { chat?.cancelWatch(id) } }
    func runBackground(_ epoch: UUID) async -> Bool {
        guard !loopActive, backgroundEpoch == nil else { return false }
        backgroundEpoch = epoch
        defer { if backgroundEpoch == epoch { backgroundEpoch = nil } }
        return await runDue(background: true)
    }
    func cancelBackground(_ epoch: UUID) {
        guard backgroundEpoch == epoch, let id = checkingID else { return }
        cancelCheck(id)
    }
    @discardableResult func runDue(background: Bool) async -> Bool {
        guard !loopActive, !Task.isCancelled, background || foreground else { return false }
        loopActive = true; checkingBackground = background
        defer { loopActive = false; checkingID = nil; checkingBackground = false }
        var succeeded = true
        do {
            let expired = try await store.expire(at: clock())
            // Submit the next discretionary request before iOS can expire this one.
            if background || !expired.isEmpty { await refresh() }
            let due = await store.due(at: clock())
            for watch in due {
                guard !Task.isCancelled, background || foreground else { break }
                guard let ticket = try await store.begin(watch.id, at: clock()) else { continue }
                checkingID = watch.id
                let result: WatchCheckResult
                if Task.isCancelled { result = WatchCheckResult(outcome: .skipped, summary: "Skipped: the scheduled execution was cancelled.") }
                else if await store.watch(watch.id)?.claim?.id != ticket.claim.id { checkingID = nil; continue }
                else if let chat { result = await chat.checkWatch(ticket.watch, background: background) }
                else { result = WatchCheckResult(outcome: .skipped, summary: "Skipped: no model was loaded.") }
                _ = try await store.record(ticket, outcome: result.outcome, summary: result.summary, at: clock(), changed: result.changed)
                checkingID = nil
                if result.outcome == .failed { succeeded = false }
            }
            if !due.isEmpty { await refresh() }
        } catch { self.error = error.localizedDescription; succeeded = false; await refresh() }
        return succeeded && !Task.isCancelled
    }
}
