import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

@MainActor private final class BackgroundWatchReplyGate {
    var enabled = false
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func holdIfEnabled() async {
        guard enabled else { return }
        entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

extension ProductTests {
    @MainActor func testNativeBackgroundCPUWatchInactiveRoutingAndRecovery() async throws {
        let suite = "openweights.background-routing-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let gate = BackgroundWatchReplyGate()
        let observed = NativeObservedRuntime(LlamaRuntime(gpuLayers: 0), beforeReply: { await gate.holdIfEnabled() })
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")), sessionIdentifier: suite)
        let watchFile = root.appendingPathComponent("watches.json"), conversationFile = root.appendingPathComponent("conversations.json")
        let store = try WatchStore(file: watchFile), watches = WatchController(store: store, defaults: defaults)
        let chat = ChatController(store: try ConversationStore(file: conversationFile), downloads: downloads, watches: watches, defaults: defaults,
            runtimeFactory: { _ in observed }, goalHaltReason: { "Paused while inactive" },
            watchHaltReason: { background in ChatController.workHaltReason(criticalTemperature: false, batteryLevel: 0.7, appActive: false, requiresForeground: !background) })
        watches.bind(chat)
        var completed = false, evidence: [String: Any] = [:], modelRecord: [String: Any] = [:]
        defer {
            gate.release(); chat.cancel(); watches.setForeground(false)
            let value: [String: Any] = ["purpose":"native-real-cpu-watch-controlled-inactive-routing-recovery", "completed":completed,
                "observations":evidence, "model":modelRecord, "runtimeTrace":observed.snapshot(), "operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations":["Real pinned CPU inference. Test-only conditions inject an inactive app at 70% battery without critical heat. Actual native conditions are retained separately.",
                    "The gate holds delivery of the actual final reply after native generation, not the CPU worker. Lifecycle callbacks are delivered directly while the check owns that pending reply.",
                    "This does not prove an OS-granted background task, actual suspension/termination, notifications, energy or general model quality."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Background CPU watch inactive routing"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let source = cachedDirectory(artifact:"gguf",revision:try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source,file:try XCTUnwrap(pinned.files.first)); await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first)
        model.backend = .llamaCPU; model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1
        model.settings.outputTokens = 128; model.settings.thinking = false
        try await downloads.save(model); await chat.load(model); XCTAssertNil(chat.error)
        modelRecord = ["repository":pinned.repository ?? "", "revision":pinned.revision ?? "", "sha256":pinned.files.first?.sha256 ?? "",
                       "backend":model.backend.rawValue, "outputTokens":model.settings.outputTokens, "contextTokens":model.settings.contextTokens, "temperature":model.settings.temperature]
        chat.draft = "Reply with Cedar."; await chat.send(); try await waitUntil(seconds:120) { !chat.busy }
        XCTAssertNil(chat.error); let original = try XCTUnwrap(chat.current)
        let originalBytes = try Data(contentsOf: conversationFile)
        let watch = try await store.start(task:"This is a due reminder. Tell me to review Cedar now in one short sentence.",everyMinutes:1,at:Date().addingTimeInterval(-61))
        let denied = await chat.checkWatch(watch,background:false)
        XCTAssertEqual(denied.outcome,.skipped); XCTAssertTrue(denied.summary.contains("inactive"))
        evidence["foregroundOutcome"] = denied.outcome.rawValue; evidence["foregroundSummary"] = denied.summary
        gate.enabled = true
        let run = Task { await watches.runBackground(UUID()) }
        defer { run.cancel() }
        try await waitUntil(seconds:120) { gate.entered }
        XCTAssertEqual(chat.checkingWatchID,watch.id); XCTAssertTrue(chat.busy)
        evidence["conditionsAtHeldReply"] = nativeDeviceConditions()
        chat.prepareForInactivity(); watches.setForeground(false)
        XCTAssertTrue(chat.busy); XCTAssertEqual(chat.checkingWatchID,watch.id)
        gate.release(); let ran = await run.value
        let savedValue = await store.watch(watch.id); let saved = try XCTUnwrap(savedValue)
        let finding = saved.lastSummary ?? ""
        evidence["ran"] = ran; evidence["finding"] = finding; evidence["runs"] = saved.runs
        evidence["outcome"] = saved.history.last?.outcome.rawValue ?? ""; evidence["runSummary"] = saved.history.last?.summary ?? ""
        XCTAssertTrue(ran); XCTAssertEqual(saved.runs,1); XCTAssertEqual(saved.history.last?.outcome,.checked)
        XCTAssertTrue(finding.localizedCaseInsensitiveContains("Cedar")); XCTAssertNotNil(saved.resultNotice); XCTAssertNil(saved.claim)
        XCTAssertEqual(chat.current,original); XCTAssertEqual(try Data(contentsOf:conversationFile),originalBytes)
        XCTAssertFalse(chat.busy); XCTAssertNil(chat.checkingWatchID)
        let reopened = try WatchStore(file:watchFile); let durable = await reopened.watch(watch.id)
        XCTAssertEqual(durable,saved)
        evidence["storedChatBytesUnchanged"] = try Data(contentsOf:conversationFile) == originalBytes
        evidence["watchReopenedExactly"] = durable == saved
        gate.enabled = false
        chat.draft = "Reply briefly with Cedar again."; await chat.send(); try await waitUntil(seconds:120) { !chat.busy }
        XCTAssertNil(chat.error); XCTAssertEqual(chat.current?.messages.last?.status,.complete)
        evidence["recoveryAnswer"] = chat.current?.messages.last?.content ?? ""
        completed = ran && saved.runs == 1 && saved.history.last?.outcome == .checked && finding.localizedCaseInsensitiveContains("Cedar") && durable == saved && chat.error == nil && chat.current?.messages.last?.status == .complete
    }
}
