import Foundation
import OpenWeightsCore

private struct WatchFixtureWebResolver: PublicWebResolving {
    func resolve(host: String, timeout: TimeInterval) async throws -> [String] { ["8.8.8.8"] }
}
private actor WatchFixtureWebConnector: PublicWebConnecting {
    var requests = 0
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        requests += 1
        return WebHTTPResponse(status: 200, headers: ["content-type": "text/plain"], body: Data("Cedar status".utf8))
    }
}
private actor WatchFixtureSearchTransport: SearchHTTPTransport {
    var requests = 0
    func send(_ request: SearchHTTPRequest, timeout: TimeInterval) async throws -> WebHTTPResponse {
        requests += 1
        return WebHTTPResponse(status: 200, headers: ["content-type": "text/html"], body: Data("<div data-type='web'><a href='https://example.com/'>Cedar</a><div class='snippet'>Public Cedar information with enough details to be useful.</div></div>".utf8))
    }
}
private final class WatchFixtureProxyVault: SearchProxyCredentialStoring {
    func read(for endpoint: SearchProxyEndpoint) throws -> SearchProxyCredentials? { nil }
    func save(_ credentials: SearchProxyCredentials?, for endpoint: SearchProxyEndpoint?) throws {}
}
@MainActor final class FixtureWatchScheduler: WatchScheduling {
    var authorization = WatchNotificationAuthorization.denied
    var accepted = false
    var posted: [UUID] = []
    var updates = 0
    var onPost: (() async throws -> Void)?
    func update(_ watches: [ScheduledWatch], at date: Date) async throws { updates += 1 }
    func post(_ notice: WatchNotice, watch: ScheduledWatch) async throws -> Bool {
        posted.append(notice.id)
        let operation = onPost; onPost = nil; try await operation?()
        return accepted
    }
    func requestPermission() async throws { authorization = .enabled; accepted = true }
}
@MainActor final class FixtureWatchClock { var now = Date() }

extension ControllerChecks {
    @MainActor static func watchChecks(_ passed: inout [String]) async throws {
        func requiredValue<T>(_ value: T?) throws -> T { guard let value else { throw CheckFailure("Missing source authorization") }; return value }
        for mode in [AgentMode.auto, .yolo] {
            let fixture = try Fixture(mode: .watchRequest, write: false); defer { fixture.cleanup() }
            fixture.files.mode = mode; fixture.watches.toolEnabled = true
            try await fixture.loadAndSend(); try await wait("Watch approval absent") { fixture.chat.pendingToolApproval != nil }
            try require(await fixture.watches.store.list().isEmpty, "A watch started before exact approval.")
            try require(fixture.chat.pendingToolApprovalContext?.contains("60 checks") == true, "The watch approval omitted its limits.")
            fixture.chat.answerToolApproval(approved: true)
            try await wait("Watch request did not finish") { !fixture.chat.busy }
            let saved = await fixture.watches.store.list()
            try require(saved.count == 1 && saved[0].task == "Remind me to review Cedar", "Approved watch was lost or duplicated.")
            let reopened = try WatchStore(file: fixture.root.appendingPathComponent("watches.json"))
            try require(await reopened.list().count == 1, "The approved watch was not durable.")
        }
        passed.append("watch-chat-request-always-needs-exact-approval-in-auto-and-yolo-and-survives-reopen")

        let access = try Fixture(mode: .fetchTwice, write: false, webClient: PublicWebClient(resolver: WatchFixtureWebResolver(), connector: WatchFixtureWebConnector())); defer { access.cleanup() }
        access.web.fetchEnabled = true
        let authorization = try requiredValue(access.watches.webAuthorization(pages: "example.com/page\nexample.com/next", queries: ""))
        try require(await access.watches.create(task: "Check Cedar status", everyMinutes: 1, webAuthorization: authorization), "Watch source creation failed.")
        let savedAccess = await access.watches.store.list()[0]
        var repeated = savedAccess; repeated.lastSummary = "An old external finding."
        await access.chat.load(access.chat.downloads.models[0])
        let checked = await access.chat.checkWatch(repeated, background: true)
        try require(checked.outcome == .checked && access.runtime.captures[0].messages[0]["content"]?.contains(authorization.promptDescription) == true && access.runtime.captures[2].messages.filter { $0["role"] == "tool" }.allSatisfy { $0["content"]?.contains("Read:") == true }, "Approved repeated sources did not reach the isolated watch prompt/results.")
        let reloaded = try WatchStore(file: access.root.appendingPathComponent("watches.json"))
        try require(await reloaded.watch(savedAccess.id)?.webAuthorization == authorization && access.chat.current == nil && access.chat.pendingToolApproval == nil, "Source authorization or isolated chat state was lost.")
        passed.append("approved-watch-sources-survive-reopen-and-prior-findings-without-chat-history-or-live-approval")

        let freshConnector = WatchFixtureWebConnector()
        let recovered = try Fixture(mode: .watchStaleThenFetch, write: false, webClient: PublicWebClient(resolver: WatchFixtureWebResolver(), connector: freshConnector)); defer { recovered.cleanup() }
        recovered.web.fetchEnabled = true; await recovered.chat.load(recovered.chat.downloads.models[0])
        let freshAuthorization = try requiredValue(recovered.watches.webAuthorization(pages: "example.com/page", queries: ""))
        var freshWatch = ScheduledWatch(task: "Check Cedar status", everyMinutes: 1, at: Date()); freshWatch.webAuthorization = freshAuthorization; freshWatch.lastSummary = "Cedar status"
        let refreshed = await recovered.chat.checkWatch(freshWatch, background: true)
        let freshRequests = await freshConnector.requests
        try require(refreshed.outcome == .checked && !refreshed.changed && refreshed.summary == "Cedar status" && recovered.runtime.captures.count == 3 && recovered.runtime.captures[1].messages.last?["content"]?.contains("This check is not complete") == true && freshRequests == 1, "A stale answer was accepted without one bounded correction and fresh approved evidence.")
        try require(recovered.chat.current == nil && !recovered.chat.busy && recovered.chat.contextUsed == 0, "Fresh-source repair mutated chat or retained watch context.")
        passed.append("stale-web-watch-answer-repairs-once-reads-approved-source-and-preserves-unchanged-finding")

        let noReadConnector = WatchFixtureWebConnector()
        let stubborn = try Fixture(mode: .watchReminder, write: false, webClient: PublicWebClient(resolver: WatchFixtureWebResolver(), connector: noReadConnector)); defer { stubborn.cleanup() }
        stubborn.web.fetchEnabled = true; await stubborn.chat.load(stubborn.chat.downloads.models[0])
        let noRead = await stubborn.chat.checkWatch(freshWatch, background: true)
        let noReadRequests = await noReadConnector.requests
        try require(noRead.outcome == .failed && stubborn.runtime.captures.count == 2 && noReadRequests == 0 && !stubborn.chat.busy && stubborn.chat.pendingToolApproval == nil, "A model that ignores fresh reads succeeded or retried without a bound.")
        passed.append("web-watch-without-current-read-fails-after-one-correction-and-releases-chat")

        let refusedConnector = WatchFixtureWebConnector()
        let refused = try Fixture(mode: .watchRefusedFetch, write: false, webClient: PublicWebClient(resolver: WatchFixtureWebResolver(), connector: refusedConnector)); defer { refused.cleanup() }
        refused.web.fetchEnabled = true; await refused.chat.load(refused.chat.downloads.models[0])
        var wrongWatch = freshWatch; wrongWatch.webAuthorization = try requiredValue(refused.watches.webAuthorization(pages: "example.com/next", queries: ""))
        let failedRead = await refused.chat.checkWatch(wrongWatch, background: true)
        let refusedRequests = await refusedConnector.requests
        try require(failedRead.outcome == .failed && refused.runtime.captures.count == 3 && refusedRequests == 0 && refused.runtime.captures[1].messages.last?["role"] == "tool", "A refused request was counted as fresh evidence.")
        passed.append("refused-watch-source-is-not-current-evidence-and-does-not-contact-unapproved-address")

        let queryTransport = WatchFixtureSearchTransport()
        let query = try Fixture(mode: .search, write: false, searchTransport: queryTransport, proxyCredentials: WatchFixtureProxyVault()); defer { query.cleanup() }
        query.web.searchEnabled = true
        query.web.setEngine(.duckduckgo, enabled: false); query.web.setEngine(.yahoo, enabled: false)
        let queryAuthorization = try requiredValue(query.watches.webAuthorization(pages: "", queries: "Cedar status"))
        await query.web.beginTurn(carriesUntrustedText: true, carriesPrivateData: true)
        let call = AgentToolCall(id: "approved-query", name: "web_search", argumentsJSON: "{\"query\":\"Cedar status\"}")
        for _ in 0..<2 {
            let result = await query.web.execute(call, mode: .auto, approval: nil, workspace: nil, unattended: true, watchAuthorization: queryAuthorization)
            try require(!result.rejected, "An explicitly approved query refused repeated execution.")
        }
        let initialRequests = await queryTransport.requests
        try require(initialRequests == 2, "Repeated approved searches did not reach their provider.")
        let privateCall = AgentToolCall(id: "unapproved-query", name: "web_search", argumentsJSON: "{\"query\":\"Cedar status private secret\"}")
        let wrong = await query.web.execute(privateCall, mode: .auto, approval: nil, workspace: nil, unattended: true, watchAuthorization: queryAuthorization)
        query.web.setEngine(.yahoo, enabled: true)
        let changedProviders = await query.web.execute(call, mode: .auto, approval: nil, workspace: nil, unattended: true, watchAuthorization: queryAuthorization)
        try query.web.saveProxy(address: "http://proxy.example:8080")
        let changedProxy = await query.web.execute(call, mode: .auto, approval: nil, workspace: nil, unattended: true, watchAuthorization: queryAuthorization)
        let finalRequests = await queryTransport.requests
        try require(wrong.rejected && changedProviders.rejected && changedProxy.rejected && finalRequests == initialRequests, "Unapproved query or changed provider/proxy sent a request.")
        passed.append("repeated-query-approval-is-bound-to-exact-query-providers-and-proxy-with-no-private-data-expansion")

        let cancelClock = FixtureWatchClock()
        let cancelAccess = try Fixture(mode: .fetch, write: false, clock: { cancelClock.now }, webClient: PublicWebClient(resolver: WatchFixtureWebResolver(), connector: WatchFixtureWebConnector())); defer { cancelAccess.cleanup() }
        cancelAccess.web.fetchEnabled = true; await cancelAccess.chat.load(cancelAccess.chat.downloads.models[0])
        let approvedPage = try requiredValue(cancelAccess.watches.webAuthorization(pages: "example.com/page", queries: ""))
        _ = await cancelAccess.watches.create(task: "Check Cedar", everyMinutes: 1, webAuthorization: approvedPage)
        let cancelID = await cancelAccess.watches.store.list()[0].id; cancelClock.now = cancelClock.now.addingTimeInterval(61)
        let sourceGate = PreparationGate(); cancelAccess.runtime.streamGate = sourceGate
        let running = Task { await cancelAccess.watches.runBackground(UUID()) }; try await waitForGate(sourceGate)
        _ = await cancelAccess.watches.edit(cancelID, task: "Check another condition", everyMinutes: 1)
        await sourceGate.release(); _ = await running.value
        let removed = await cancelAccess.watches.store.watch(cancelID)!
        try require(removed.webAuthorization == nil && removed.claim == nil && removed.runs == 0 && removed.history.isEmpty && !cancelAccess.chat.busy, "Editing did not revoke sources and cancel old in-flight results.")
        passed.append("watch-editor-revocation-cancels-in-flight-model-and-refuses-late-results-without-spending-budget")

        let declined = try Fixture(mode: .watchRequest, write: false); defer { declined.cleanup() }
        declined.watches.toolEnabled = true; try await declined.loadAndSend()
        try await wait("Watch decline prompt absent") { declined.chat.pendingToolApproval != nil }
        declined.chat.answerToolApproval(approved: false); try await wait("Watch decline did not finish") { !declined.chat.busy }
        try require(await declined.watches.store.list().isEmpty, "Declining created a watch.")
        let stopped = try Fixture(mode: .watchRequest, write: false); defer { stopped.cleanup() }
        stopped.watches.toolEnabled = true; try await stopped.loadAndSend()
        try await wait("Watch Stop prompt absent") { stopped.chat.pendingToolApproval != nil }
        stopped.chat.cancel(); try await wait("Watch Stop did not finish") { !stopped.chat.busy }
        try require(await stopped.watches.store.list().isEmpty, "Stop created a watch.")
        passed.append("declining-or-stopping-watch-approval-does-not-create-a-schedule")

        for enabled in [false, true] {
            let disabled = try Fixture(mode: .watchRequest, write: false); defer { disabled.cleanup() }
            disabled.watches.toolEnabled = enabled
            if enabled { disabled.files.mode = .plan }
            try await disabled.loadAndSend(); try await wait("Watch gate did not finish") { !disabled.chat.busy }
            try require(await disabled.watches.store.list().isEmpty, "Disabled or Plan watch changed schedules.")
            try require(disabled.chat.pendingToolApproval == nil && disabled.runtime.captures.allSatisfy { !$0.tools.contains("watch") }, "A disabled or Plan watch was offered.")
        }
        passed.append("watch-switch-and-plan-mode-refuse-unoffered-scheduling")

        let isolated = try Fixture(mode: .watchReminder, supportsTools: false, write: false); defer { isolated.cleanup() }
        try await isolated.loadAndSend(); try await wait("Initial chat did not finish") { !isolated.chat.busy }
        let conversation = isolated.chat.current
        let watch = ScheduledWatch(task: "Remind me to review Cedar", everyMinutes: 1, at: Date())
        let resets = isolated.runtime.resetCount
        let first = await isolated.chat.checkWatch(watch, background: false)
        var previous = watch; previous.lastSummary = first.summary
        let second = await isolated.chat.checkWatch(previous, background: false)
        try require(first.outcome == .checked && first.changed && first.summary == "Review Cedar now." && second.outcome == .checked && !second.changed, "First finding or unchanged marker was mishandled.")
        try require(isolated.chat.current == conversation && isolated.chat.pendingToolApproval == nil && isolated.chat.checkingWatchID == nil && !isolated.chat.busy, "Watch mutated the open conversation or left it busy.")
        let capture = isolated.runtime.captures.last!
        try require(capture.messages.count == 2 && capture.messages.last?["content"] == watch.task && capture.tools.isEmpty, "A watch inherited conversation history or unsupported tools.")
        try require(isolated.runtime.resetCount == resets + 4 && isolated.chat.contextUsed == 0, "Standalone checks retained model context.")
        passed.append("watch-uses-isolated-prompt-keeps-chat-unchanged-resets-context-and-parses-first-versus-unchanged")

        let writing = try Fixture(mode: .write); defer { writing.cleanup() }
        await writing.chat.load(writing.chat.downloads.models[0])
        let refusedWrite = await writing.chat.checkWatch(watch, background: false)
        let factsAfterCheck = await writing.memory.store.list()
        try require(refusedWrite.outcome == .checked && factsAfterCheck.isEmpty && writing.chat.pendingToolApproval == nil, "A watch wrote memory or suspended on approval.")
        let scheduling = try Fixture(mode: .watchRequest, write: false); defer { scheduling.cleanup() }
        scheduling.watches.toolEnabled = true; await scheduling.chat.load(scheduling.chat.downloads.models[0])
        _ = await scheduling.chat.checkWatch(watch, background: false)
        try require(await scheduling.watches.store.list().isEmpty, "A watch created another watch without a person.")
        passed.append("unattended-checks-refuse-memory-writes-and-new-watches-without-showing-approval")

        let reader = try Fixture(mode: .read, read: true, write: false); defer { reader.cleanup() }
        try await reader.memory.store.remember("Prefers tea"); await reader.chat.load(reader.chat.downloads.models[0])
        let reading = await reader.chat.checkWatch(watch, background: false)
        try require(reading.outcome == .checked && reader.runtime.captures[1].messages.contains { $0["role"] == "tool" && ($0["content"] ?? "").contains("Prefers tea") }, "An enabled read did not reach the standalone answer.")
        passed.append("watch-can-read-enabled-memory-on-request-without-writing-or-injecting-chat-history")

        for mode in [FixtureRuntime.Mode.fileReplace, .watchReadThenWrite] {
            let files = try Fixture(mode: mode, write: false); defer { files.cleanup() }
            try await files.prepareFiles(mode: .yolo); await files.chat.load(files.chat.downloads.models[0])
            _ = await files.chat.checkWatch(watch, background: false)
            let original = try String(contentsOf: files.sharedFolder.appendingPathComponent("user.txt"), encoding: .utf8)
            try require(original == "Original Cedar" && files.chat.pendingToolApproval == nil, "The unattended check replaced a user file or waited for approval.")
            if mode == .watchReadThenWrite {
                try require(files.runtime.captures[2].messages.contains { $0["role"] == "tool" && $0["tool_name"] == "write_file" && ($0["content"] ?? "").contains("needs approval") }, "The test did not attempt and refuse a write after reading.")
                try require(!FileManager.default.fileExists(atPath: files.sharedFolder.appendingPathComponent("new.txt").path), "Untrusted read permitted an unattended write.")
            }
        }
        passed.append("watch-refuses-user-file-replacement-and-writes-after-untrusted-reads-even-if-chat-is-yolo")

        let gated = try Fixture(mode: .watchReminder, write: false, haltReason: { "Battery below the limit" }); defer { gated.cleanup() }
        let unloaded = await gated.chat.checkWatch(watch, background: false)
        await gated.chat.load(gated.chat.downloads.models[0]); let battery = await gated.chat.checkWatch(watch, background: false)
        let gpu = try Fixture(mode: .watchReminder, write: false, backend: .llamaMetal); defer { gpu.cleanup() }
        await gpu.chat.load(gpu.chat.downloads.models[0]); let background = await gpu.chat.checkWatch(watch, background: true)
        try require(unloaded.outcome == .skipped && battery.outcome == .skipped && background.outcome == .skipped && gated.runtime.captures.isEmpty && gpu.runtime.captures.isEmpty, "A missing model, guarded device or background GPU started inference.")
        passed.append("watch-skips-before-inference-with-no-loaded-model-device-halt-or-background-gpu")

        let capped = try Fixture(mode: .watchCapped, write: false); defer { capped.cleanup() }
        await capped.chat.load(capped.chat.downloads.models[0]); let incomplete = await capped.chat.checkWatch(watch, background: false)
        try require(incomplete.outcome == .failed && !incomplete.changed && capped.runtime.resetCount >= 2, "A capped watch answer was published as a complete finding.")
        passed.append("capped-watch-answer-fails-and-clears-context-without-publishing-a-finding")

        let clock = FixtureWatchClock(); let scheduler = FixtureWatchScheduler()
        let coordinator = try Fixture(mode: .watchReminder, write: false, scheduler: scheduler, clock: { clock.now }); defer { coordinator.cleanup() }
        await coordinator.chat.load(coordinator.chat.downloads.models[0])
        try require(await coordinator.watches.create(task: "Review Cedar", everyMinutes: 1), "Controller watch creation failed.")
        clock.now = clock.now.addingTimeInterval(61)
        try require(await coordinator.watches.runBackground(UUID()), "Background CPU fixture check failed.")
        var stored = await coordinator.watches.store.list()[0]
        try require(stored.runs == 1 && stored.resultNotice != nil && stored.claim == nil && scheduler.posted.count == 1, "Denied notifications lost the durable finding or left a claim.")
        await coordinator.watches.requestNotifications()
        stored = await coordinator.watches.store.list()[0]
        try require(stored.resultNotice == nil && coordinator.watches.notifications == .enabled && scheduler.posted.count == 2, "Enabling notifications did not retry and acknowledge the pending notice.")
        passed.append("cpu-background-controller-check-claims-once-keeps-denied-notice-and-retries-after-permission")

        let staleClock = FixtureWatchClock()
        let stale = try Fixture(mode: .watchReminder, write: false, clock: { staleClock.now }); defer { stale.cleanup() }
        await stale.chat.load(stale.chat.downloads.models[0]); _ = await stale.watches.create(task: "Review Cedar", everyMinutes: 1)
        let id = await stale.watches.store.list()[0].id; staleClock.now = staleClock.now.addingTimeInterval(61)
        let gate = PreparationGate(); stale.runtime.streamGate = gate
        let epoch = UUID(); let checking = Task { await stale.watches.runBackground(epoch) }
        try await waitForGate(gate)
        try require(!(await stale.watches.runBackground(UUID())), "A concurrent background callback started another check.")
        stale.watches.cancelBackground(epoch)
        try require(stale.runtime.cancellationCount == 1, "Overlap replaced the running background cancellation handle.")
        await stale.watches.pause(id); await gate.release(); _ = await checking.value
        let paused = await stale.watches.store.watch(id)!
        try require(paused.state == .paused && paused.runs == 0 && paused.history.isEmpty && paused.resultNotice == nil && !stale.chat.busy, "A paused check published a late result.")
        stale.runtime.streamGate = nil
        let before = stale.runtime.cancellationCount; stale.watches.cancelBackground(epoch)
        try require(stale.runtime.cancellationCount == before, "An old expiration callback cancelled later work.")
        passed.append("overlapping-background-callback-preserves-cancel-handle-and-paused-check-cannot-publish-late-result")

        let skipClock = FixtureWatchClock()
        let noModel = try Fixture(mode: .watchReminder, write: false, clock: { skipClock.now }); defer { noModel.cleanup() }
        _ = await noModel.watches.create(task: "Review Cedar", everyMinutes: 1); skipClock.now = skipClock.now.addingTimeInterval(600)
        _ = await noModel.watches.runBackground(UUID()); _ = await noModel.watches.runBackground(UUID())
        let skipped = await noModel.watches.store.list()[0]
        try require(skipped.runs == 0 && skipped.history.count == 1 && skipped.history[0].outcome == .skipped && skipped.nextDueAt > skipClock.now, "Catch-up replayed a backlog or spent the budget without a model.")
        passed.append("catch-up-skips-missing-model-once-without-backlog-or-check-budget-consumption")

        try require(ChatController.workHaltReason(criticalTemperature: false, batteryLevel: 0.7, appActive: false, requiresForeground: false) == nil,
                    "An inactive app blocked an eligible CPU background check.")
        try require(ChatController.workHaltReason(criticalTemperature: false, batteryLevel: 0.7, appActive: false, requiresForeground: true)?.contains("inactive") == true,
                    "An inactive app admitted foreground work.")
        try require(ChatController.workHaltReason(criticalTemperature: true, batteryLevel: 0.7, appActive: false, requiresForeground: false)?.contains("too hot") == true &&
                    ChatController.workHaltReason(criticalTemperature: false, batteryLevel: 0.14, appActive: false, requiresForeground: false)?.contains("15%") == true,
                    "Background admission bypassed critical heat or low battery.")
        try require(ChatController.workHaltReason(criticalTemperature: false, batteryLevel: 0.15, appActive: false, requiresForeground: false) == nil &&
                    ChatController.workHaltReason(criticalTemperature: false, batteryLevel: -1, appActive: false, requiresForeground: false) == nil,
                    "The known-battery threshold changed or an unknown reading became a fabricated low-battery reading.")
        passed.append("device-policy-allows-background-cpu-without-bypassing-foreground-heat-or-known-battery-guards")

        let grantClock = FixtureWatchClock()
        let granted = try Fixture(mode: .watchReminder, write: false, haltReason: { "Paused while inactive" },
                                  watchHaltReason: { background in ChatController.workHaltReason(criticalTemperature: false, batteryLevel: 0.7, appActive: false, requiresForeground: !background) },
                                  clock: { grantClock.now }); defer { granted.cleanup() }
        await granted.chat.load(granted.chat.downloads.models[0])
        let inactiveForeground = await granted.chat.checkWatch(ScheduledWatch(task: "Review Cedar", everyMinutes: 1, at: Date()), background: false)
        try require(inactiveForeground.outcome == .skipped && granted.runtime.captures.isEmpty,
                    "The foreground watch started inference while its app was inactive.")
        passed.append("inactive-foreground-watch-skips-before-inference-with-distinct-background-policy")
        _ = await granted.watches.create(task: "Review Cedar", everyMinutes: 1)
        grantClock.now = grantClock.now.addingTimeInterval(61)
        let grantGate = PreparationGate(); granted.runtime.streamGate = grantGate
        let grantRun = Task { await granted.watches.runBackground(UUID()) }
        try await waitForGate(grantGate)
        granted.chat.prepareForInactivity(); granted.watches.setForeground(false)
        await grantGate.release(); _ = await grantRun.value
        let grantResult = await granted.watches.store.list()[0]
        try require(grantResult.runs == 1 && grantResult.history.last?.outcome == .checked && granted.runtime.cancellationCount == 0,
                    "An authorized background CPU watch was cancelled by foreground lifecycle routing.")
        passed.append("authorized-background-cpu-watch-survives-inactive-chat-and-watch-routing")

        for critical in [true, false] {
            var stopConditions = false
            let guardedClock = FixtureWatchClock()
            let guarded = try Fixture(mode: .watchReminder, write: false,
                watchHaltReason: { background in ChatController.workHaltReason(criticalTemperature: stopConditions && critical,
                    batteryLevel: stopConditions && !critical ? 0.14 : 0.7, appActive: false, requiresForeground: !background) },
                clock: { guardedClock.now }); defer { guarded.cleanup() }
            await guarded.chat.load(guarded.chat.downloads.models[0])
            _ = await guarded.watches.create(task: "Review Cedar", everyMinutes: 1)
            guardedClock.now = guardedClock.now.addingTimeInterval(61)
            let deviceGate = PreparationGate(); guarded.runtime.streamGate = deviceGate
            let deviceRun = Task { await guarded.watches.runBackground(UUID()) }
            try await waitForGate(deviceGate); stopConditions = true
            try await wait("Background device guard did not cancel inference") { guarded.runtime.cancellationCount > 0 }
            await deviceGate.release(); _ = await deviceRun.value
            let deviceResult = await guarded.watches.store.list()[0]
            try require(deviceResult.runs == 0 && deviceResult.history.last?.outcome == .skipped && deviceResult.resultNotice == nil && !guarded.chat.busy,
                        "Device-stopped background inference published a finding or spent a check.")
        }
        passed.append("background-watch-critical-heat-and-low-battery-transitions-cancel-without-publishing-or-spending-budget")
    }
}
