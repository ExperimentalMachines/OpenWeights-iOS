import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

@MainActor private func scriptWatchWait(until condition: () -> Bool) async throws {
    let end = ProcessInfo.processInfo.systemUptime + 10
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < end else { throw URLError(.timedOut) }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}
private func scriptWatchAttach(_ evidence: [String: Any], to test: XCTestCase) {
    if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted]) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.lifetime = .keepAlways; test.add(attachment)
    }
}
@MainActor extension ProductTests {
    func testNativeScriptWatchPrivateInputsPauseAndChatRecovery() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The isolated helper requires iOS 26.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("script-watch-policy-" + UUID().uuidString)
        let suite = "openweights.script-watch-policy." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { defaults.removePersistentDomain(forName: suite); UIApplication.shared.isIdleTimerDisabled = idle; try? FileManager.default.removeItem(at: root) }
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")), sessionIdentifier: suite)
        var model = LocalModel(name: "Watch controller fixture, no inference", backend: .llamaCPU, entryFile: "fixture.gguf", files: [ModelFile(path: "fixture.gguf")])
        let directory = downloads.directory(model); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(model.entryFile); let data = Data("GGUF fixture, not model weights".utf8); try data.write(to: file)
        model.files[0].bytes = Int64(data.count); model.files[0].sha256 = try ModelFileTransfer.hash(file); model.state = .ready; try await downloads.save(model)
        let folder = root.appendingPathComponent("Shared"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"total":30}"#.utf8).write(to: folder.appendingPathComponent("sales.json"))
        let files = WorkspaceController(bookmarkFile: root.appendingPathComponent("workspace.bookmark"), defaults: defaults)
        await files.choose(folder); XCTAssertNil(files.error); files.enabled = []; files.mode = .ask
        let web = WebController(defaults: defaults); web.searchEnabled = false; web.mediaEnabled = false
        let runner = IsolatedScriptRunner(), runtime = NativeScriptChatFixtureRuntime()
        let watches = WatchController(store: try WatchStore(file: root.appendingPathComponent("watches.json")), defaults: defaults)
        let chat = ChatController(store: try ConversationStore(file: root.appendingPathComponent("conversations.json")), downloads: downloads, files: files, watches: watches, web: web, scriptRunner: runner, defaults: defaults, runtimeFactory: { _ in runtime })
        watches.bind(chat); var completed = false; var actions: [String] = []; var stopSeconds = 0.0; var helperPID: Int32 = 0
        defer {
            chat.cancel()
            scriptWatchAttach(["purpose": "native-script-watch-policy", "completed": completed, "actionsReached": actions, "hostPID": getpid(), "helperPID": helperPID, "pauseReturnSeconds": stopSeconds, "error": chat.error ?? watches.error ?? "", "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations": ["Scripted model replies with the real isolated helper and app-owned chosen-folder input. Controller background entry executes while XCTest remains foreground. No OS background grant, external file provider, touch or notification delivery."]], to: self)
        }
        await chat.load(model); XCTAssertNil(chat.error); _ = await chat.newConversation(); let original = chat.current
        chat.scriptEnabled = true
        runtime.setArguments(#"{"source":"const fs=require('fs'); JSON.parse(await fs.promises.readFile('sales.json')).total+1","files":["sales.json"]}"#)
        let watch = ScheduledWatch(task: "Calculate the private total", everyMinutes: 1, at: Date())
        let checked = await chat.checkWatch(watch, background: true)
        XCTAssertEqual(checked.outcome, .checked); XCTAssertEqual(checked.summary, "31"); XCTAssertEqual(chat.current, original)
        XCTAssertNil(chat.pendingToolApproval); XCTAssertFalse(chat.busy); XCTAssertEqual(chat.contextUsed, 0)
        helperPID = try XCTUnwrap(runner.lastProcessID); XCTAssertNotEqual(helperPID, getpid())
        let search = AgentToolCall(id: "search", name: "web_search", argumentsJSON: #"{"query":"Cedar"}"#)
        let guarded = await web.requiresApproval(search, mode: .auto); XCTAssertTrue(guarded)
        actions.append("private-input-watch-script-runs-in-auto-separate-helper-with-egress-guard-and-unchanged-chat")
        runtime.setArguments(#"{"source":"while(true){}"}"#)
        let pausedWatch = try await watches.store.start(task: "Run the pending calculation", everyMinutes: 1, at: Date().addingTimeInterval(-61))
        let running = Task { await watches.runBackground(UUID()) }
        try await scriptWatchWait { runner.lastStage == "waiting-for-reply" && chat.checkingWatchID == pausedWatch.id }
        let start = ProcessInfo.processInfo.systemUptime; await watches.pause(pausedWatch.id); _ = await running.value
        stopSeconds = ProcessInfo.processInfo.systemUptime - start
        let savedValue = await watches.store.watch(pausedWatch.id); let saved = try XCTUnwrap(savedValue)
        XCTAssertEqual(saved.state, .paused); XCTAssertEqual(saved.runs, 0); XCTAssertNil(saved.lastSummary); XCTAssertNil(saved.claim)
        XCTAssertLessThan(stopSeconds, 1); XCTAssertFalse(chat.busy); XCTAssertNil(chat.checkingWatchID); XCTAssertFalse(runner.hasPendingRequest); XCTAssertEqual(chat.current, original)
        actions.append("watch-pause-cancels-active-helper-without-stale-finding-or-spent-run")
        files.mode = .auto; runtime.setArguments(#"{"source":"7*8"}"#); chat.draft = "Recover after the watch"; await chat.send()
        try await scriptWatchWait { !chat.busy }; XCTAssertNil(chat.error); XCTAssertEqual(chat.current?.messages.last?.content, "56")
        actions.append("interactive-chat-script-recovers-after-watch-cancellation")
        completed = actions.count == 3 && checked.summary == "31" && saved.runs == 0 && chat.current?.messages.last?.content == "56" && chat.error == nil
    }

    func testNativeModelGeneratedScriptWatchPersistsFindingAndKeepsChat() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The isolated helper requires iOS 26.") }
        let pinned = try NativeAgentArtifact.selected()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("script-watch-model-" + UUID().uuidString)
        let suite = "openweights.script-watch-model." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { defaults.removePersistentDomain(forName: suite); UIApplication.shared.isIdleTimerDisabled = idle; try? FileManager.default.removeItem(at: root) }
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")), sessionIdentifier: suite)
        let files = WorkspaceController(bookmarkFile: root.appendingPathComponent("workspace.bookmark"), defaults: defaults); files.mode = .ask; files.enabled = []
        let watchFile = root.appendingPathComponent("watches.json"), conversationFile = root.appendingPathComponent("conversations.json")
        let watches = WatchController(store: try WatchStore(file: watchFile), defaults: defaults)
        let observed = NativeObservedRuntime(LlamaRuntime(gpuLayers: 0)), runner = IsolatedScriptRunner()
        let chat = ChatController(store: try ConversationStore(file: conversationFile), downloads: downloads, files: files, watches: watches, scriptRunner: runner, defaults: defaults, runtimeFactory: { _ in observed })
        watches.bind(chat); var completed = false; var finding = ""; var chatUnchanged = false; var actions: [String] = []
        defer {
            chat.cancel()
            var artifact = NativeAgentArtifact.evidence(pinned); artifact["effectiveBackend"] = ModelBackend.llamaCPU.rawValue
            scriptWatchAttach(["purpose": "native-model-generated-script-watch", "completed": completed, "actionsReached": actions, "finding": finding, "chatUnchanged": chatUnchanged, "hostPID": getpid(), "helperPID": runner.lastProcessID ?? 0, "error": chat.error ?? watches.error ?? "", "runtimeTrace": observed.snapshot(), "artifact": artifact, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations": ["One real greedy CPU watch calculation on the pinned 1.7B model, running the controller background entry while XCTest remains foreground. No actual OS-granted background time, notification delivery, general model quality or default-model recommendation."]], to: self)
        }
        let source = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Models/gguf/" + (try XCTUnwrap(pinned.revision)) + "/" + pinned.entryFile)
        try ModelDownloads.verify(source, file: try XCTUnwrap(pinned.files.first)); await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first); model.backend = .llamaCPU; model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1; model.settings.outputTokens = 192; model.settings.thinking = false
        try await downloads.save(model); await chat.load(model); XCTAssertNil(chat.error); XCTAssertTrue(chat.supportsTools)
        guard chat.error == nil, chat.supportsTools else { return }
        chat.draft = "What is 2 + 2? Reply with the number only."; await chat.send()
        let chatDeadline = ProcessInfo.processInfo.systemUptime + 120
        while chat.busy { guard ProcessInfo.processInfo.systemUptime < chatDeadline else { throw URLError(.timedOut) }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(chat.error); XCTAssertEqual(chat.current?.messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines), "4")
        let original = try XCTUnwrap(chat.current)
        let storedChatBefore = try Data(contentsOf: conversationFile)
        let durableBefore = try await chat.store.conversation(original.id)
        chat.scriptEnabled = true
        let watch = try await watches.store.start(task: "Use run_script to calculate 48273 * 1179. After the tool returns, report the numerical result only.", everyMinutes: 1, at: Date().addingTimeInterval(-61))
        let ran = await watches.runBackground(UUID()); let savedValue = await watches.store.watch(watch.id); let saved = try XCTUnwrap(savedValue)
        finding = saved.lastSummary ?? ""; chatUnchanged = chat.current == original
        XCTAssertTrue(ran); XCTAssertEqual(saved.runs, 1); XCTAssertEqual(saved.history.last?.outcome, .checked); XCTAssertEqual(finding, "56913867")
        XCTAssertNotNil(saved.resultNotice); XCTAssertNil(saved.claim); XCTAssertNil(chat.pendingToolApproval); XCTAssertTrue(chatUnchanged); XCTAssertFalse(chat.busy); XCTAssertEqual(chat.contextUsed, 0)
        XCTAssertNotEqual(runner.lastProcessID, getpid()); XCTAssertNotNil(runner.lastProcessID)
        guard ran, saved.runs == 1, finding == "56913867", saved.resultNotice != nil, chatUnchanged, chat.error == nil else { return }
        let reopened = try WatchStore(file: watchFile); let durableValue = await reopened.watch(watch.id); let durable = try XCTUnwrap(durableValue)
        XCTAssertEqual(durable.lastSummary, finding); XCTAssertEqual(durable.runs, 1); XCTAssertEqual(durable.resultNotice?.id, saved.resultNotice?.id)
        let conversationStore = try ConversationStore(file: conversationFile); let durableChat = try await conversationStore.conversation(original.id); XCTAssertEqual(durableChat, durableBefore)
        XCTAssertEqual(try Data(contentsOf: conversationFile), storedChatBefore)
        actions.append("real-cpu-model-generated-auto-script-watch-persists-finding-and-notice-with-unchanged-chat")
        chat.scriptEnabled = false; chat.draft = "What is 3 + 3? Reply with the number only."; await chat.send()
        let recoveryDeadline = ProcessInfo.processInfo.systemUptime + 120
        while chat.busy { guard ProcessInfo.processInfo.systemUptime < recoveryDeadline else { throw URLError(.timedOut) }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(chat.error); XCTAssertEqual(chat.current?.messages.last?.status, .complete); XCTAssertEqual(chat.current?.messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines), "6")
        actions.append("real-interactive-chat-recovers-after-isolated-watch-context-reset")
        completed = actions.count == 2 && durable.lastSummary == "56913867" && durableChat == durableBefore && chat.error == nil && chat.current?.messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines) == "6"
    }
}
