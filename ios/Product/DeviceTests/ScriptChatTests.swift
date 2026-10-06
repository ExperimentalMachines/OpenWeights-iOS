import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

// Scripted model replies isolate controller policy. The helper and XPC are real.
final class NativeScriptChatFixtureRuntime: ChatRuntime, @unchecked Sendable {
    let supportsTools = true
    private let lock = NSLock()
    private var arguments = #"{"source":"30+1"}"#
    func setArguments(_ value: String) { lock.withLock { arguments = value } }
    func load(model: LocalModel, directory: URL) async throws {}
    func cancel() {}
    func reset() async {}
    func warm(messages: [[String: String]], settings: ModelSettings) async throws {}
    func warm(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws {}
    func promptSize(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws -> RuntimePromptSize { RuntimePromptSize(tokens: 40, exact: true) }
    func stream(messages: [[String: String]], settings: ModelSettings) -> AsyncThrowingStream<RuntimeEvent, Error> { stream(messages: messages, settings: settings, tools: []) }
    func stream(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) -> AsyncThrowingStream<RuntimeEvent, Error> {
        let args = lock.withLock { arguments }
        let calls = messages.last?["role"] == "user" && !(messages.last?["content"]?.hasPrefix("Finish the check using the available results.") ?? false) ? [RuntimeToolCall(id: UUID().uuidString, name: "run_script", arguments: args)] : []
        let content = calls.isEmpty ? messages.last(where: { $0["role"] == "tool" })?["content"] ?? messages.last?["content"] ?? "" : ""
        let raw = calls.isEmpty ? content : "<tool_call>{\"name\":\"run_script\",\"arguments\":\(args)}</tool_call>"
        return AsyncThrowingStream { stream in
            stream.yield(.token(raw))
            stream.yield(.reply(RuntimeReply(content: content, generatedTokens: 1, cachedTokens: 0, contextUsed: 40, contextSize: settings.contextTokens, firstTextMilliseconds: 0, tokensPerSecond: 0, cancelled: false, toolCalls: calls, stopReason: .endOfTurn)))
            stream.finish()
        }
    }
}

@MainActor private func scriptChatWait(seconds: Double = 10, until condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}
private func scriptChatAttach(_ evidence: [String: Any], to test: XCTestCase) {
    if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.lifetime = .keepAlways; test.add(attachment)
    }
}

@MainActor extension ProductTests {
    func testNativeScriptChatApprovalPrivateInputsPersistenceAndStopRecovery() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The isolated script helper requires iOS 26.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("script-chat-" + UUID().uuidString)
        let suite = "openweights.script-chat." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previousIdle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { defaults.removePersistentDomain(forName: suite); UIApplication.shared.isIdleTimerDisabled = previousIdle; try? FileManager.default.removeItem(at: root) }
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")), sessionIdentifier: suite)
        var model = LocalModel(name: "Controller fixture, no inference", backend: .llamaCPU, entryFile: "fixture.gguf", files: [ModelFile(path: "fixture.gguf")])
        let directory = downloads.directory(model); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(model.entryFile); let data = Data("GGUF controller fixture, not model weights".utf8); try data.write(to: file)
        model.files[0].bytes = Int64(data.count); model.files[0].sha256 = try ModelFileTransfer.hash(file); model.state = .ready; try await downloads.save(model)
        let folder = root.appendingPathComponent("Shared"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"total":30}"#.utf8).write(to: folder.appendingPathComponent("sales.json"))
        let files = WorkspaceController(bookmarkFile: root.appendingPathComponent("workspace.bookmark"), defaults: defaults)
        await files.choose(folder); XCTAssertNil(files.error); files.enabled = []; files.mode = .ask
        let web = WebController(defaults: defaults); web.searchEnabled = false; web.mediaEnabled = false
        let runner = IsolatedScriptRunner(), runtime = NativeScriptChatFixtureRuntime()
        let storeFile = root.appendingPathComponent("conversations.json")
        let chat = ChatController(store: try ConversationStore(file: storeFile), downloads: downloads, files: files, web: web, scriptRunner: runner, defaults: defaults, runtimeFactory: { _ in runtime })
        var actions: [String] = []; var completed = false; var stopSeconds = 0.0; var helperPIDs: [Int32] = []
        defer {
            chat.cancel()
            scriptChatAttach(["purpose": "native-script-chat-controller", "completed": completed, "actionsReached": actions, "hostPID": getpid(), "helperPIDs": helperPIDs, "stopSeconds": stopSeconds, "error": chat.error ?? "", "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations": ["Scripted model replies test controller policy with the real isolated helper. No inference or touch navigation in this test. Files are in an app-owned chosen folder, not an external provider."]], to: self)
        }
        XCTAssertTrue(chat.scriptsAvailable); XCTAssertFalse(chat.scriptEnabled)
        chat.scriptEnabled = true; XCTAssertTrue(defaults.bool(forKey: "tools.scripts.enabled"))
        await chat.load(model); XCTAssertNil(chat.error)
        runtime.setArguments(#"{"source":"const fs=require('fs'); JSON.parse(await fs.promises.readFile('sales.json')).total+1","files":["sales.json"]}"#)
        chat.draft = "Calculate the file total"; await chat.send()
        try await scriptChatWait { chat.pendingToolApproval != nil || !chat.busy }
        let approval = try XCTUnwrap(chat.pendingToolApproval)
        XCTAssertEqual(approval.displayedCall.name, "run_script"); XCTAssertNil(runner.lastProcessID)
        XCTAssertTrue(chat.pendingToolApprovalContext?.contains("separate sandboxed process") == true)
        chat.answerToolApproval(approved: true, ticketID: approval.ticketID)
        try await scriptChatWait { !chat.busy }
        XCTAssertNil(chat.error)
        let message = try XCTUnwrap(chat.current?.messages.first { $0.toolName == "run_script" })
        XCTAssertEqual(message.content, "31"); XCTAssertEqual(message.status, .complete)
        XCTAssertEqual(message.toolPrivateDataRead, true); XCTAssertEqual(message.toolUntrustedText, true)
        let pid = try XCTUnwrap(runner.lastProcessID); XCTAssertNotEqual(pid, getpid()); helperPIDs.append(pid)
        let search = AgentToolCall(id: "search", name: "web_search", argumentsJSON: #"{"query":"Cedar"}"#)
        let guarded = await web.requiresApproval(search, mode: .auto); XCTAssertTrue(guarded)
        let reopenedStore = try ConversationStore(file: storeFile)
        let reopened = try await reopenedStore.conversation(try XCTUnwrap(chat.current?.id))
        XCTAssertTrue(reopened.messages.contains { $0.toolName == "run_script" && $0.toolPrivateDataRead == true })
        actions.append("exact-ask-before-helper-launch-private-json-result-persisted-with-network-guard")
        chat.draft = "Decline the next call"; await chat.send(); try await scriptChatWait { chat.pendingToolApproval != nil || !chat.busy }
        XCTAssertNotNil(chat.pendingToolApproval); chat.answerToolApproval(approved: false)
        try await scriptChatWait { !chat.busy }; XCTAssertEqual(runner.lastProcessID, pid)
        XCTAssertTrue(chat.current!.messages.contains { $0.toolName == "run_script" && $0.content.contains("declined") && $0.status == .failed })
        actions.append("decline-does-not-launch-another-helper")
        files.mode = .auto; runtime.setArguments(#"{"source":"while(true){}"}"#)
        chat.draft = "Stop the active script"; await chat.send()
        try await scriptChatWait { runner.lastStage == "waiting-for-reply" || !chat.busy }
        XCTAssertTrue(chat.busy); XCTAssertEqual(runner.lastStage, "waiting-for-reply")
        let start = ProcessInfo.processInfo.systemUptime; chat.cancel()
        try await scriptChatWait { !chat.busy && !runner.hasPendingRequest }; stopSeconds = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(stopSeconds, 1); XCTAssertNil(chat.error)
        actions.append("chat-stop-interrupts-active-helper-without-controller-error")
        runtime.setArguments(#"{"source":"7*8"}"#); chat.draft = "Recover"; await chat.send(); try await scriptChatWait { !chat.busy }
        XCTAssertNil(chat.error); XCTAssertEqual(chat.current?.messages.last?.content, "56")
        helperPIDs.append(try XCTUnwrap(runner.lastProcessID))
        let continuedGuard = await web.requiresApproval(search, mode: .auto); XCTAssertTrue(continuedGuard)
        actions.append("next-script-turn-recovers-and-private-provenance-survives")
        completed = actions.count == 4 && chat.current?.messages.last?.content == "56" && chat.error == nil
    }

    func testNativeModelGeneratedScriptAskRoundTrip() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The isolated script helper requires iOS 26.") }
        let pinned = try NativeAgentArtifact.selected()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("script-model-" + UUID().uuidString)
        let suite = "openweights.script-model." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previousIdle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { defaults.removePersistentDomain(forName: suite); UIApplication.shared.isIdleTimerDisabled = previousIdle; try? FileManager.default.removeItem(at: root) }
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")), sessionIdentifier: suite)
        let files = WorkspaceController(bookmarkFile: root.appendingPathComponent("workspace.bookmark"), defaults: defaults); files.mode = .ask; files.enabled = []
        let observed = NativeObservedRuntime(LlamaRuntime(gpuLayers: 99)), runner = IsolatedScriptRunner()
        let chat = ChatController(store: try ConversationStore(file: root.appendingPathComponent("conversations.json")), downloads: downloads, files: files, scriptRunner: runner, defaults: defaults, runtimeFactory: { _ in observed })
        var completed = false; var displayedArguments = ""
        defer {
            let messages = chat.current?.messages.map { ["role": $0.role.rawValue, "content": $0.content, "status": $0.status.rawValue, "toolName": $0.toolName ?? ""] } ?? []
            chat.cancel()
            scriptChatAttach(["purpose": "native-model-generated-script-chat", "completed": completed, "hostPID": getpid(), "helperPID": runner.lastProcessID ?? 0, "displayedArguments": displayedArguments, "messages": messages, "error": chat.error ?? "", "runtimeTrace": observed.snapshot(), "artifact": NativeAgentArtifact.evidence(pinned), "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations": ["One greedy model-generated multiplication using a cached SHA-verified artifact and controller approval. No general task-quality, touch navigation, external provider or older-iOS claim. Default model choice remains undecided."]], to: self)
        }
        let source = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Models/gguf/" + (try XCTUnwrap(pinned.revision)) + "/" + pinned.entryFile)
        try ModelDownloads.verify(source, file: try XCTUnwrap(pinned.files.first)); await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first); model.settings.temperature = 0; model.settings.repeatPenalty = 1; model.settings.outputTokens = 192; model.settings.thinking = false
        try await downloads.save(model); await chat.load(model); XCTAssertNil(chat.error); XCTAssertTrue(chat.supportsTools)
        guard chat.error == nil, chat.supportsTools else { return }
        chat.scriptEnabled = true; chat.draft = "Use run_script to calculate 48273 * 1179. After the tool returns, reply with the numerical result only."
        await chat.send(); try await scriptChatWait(seconds: 120) { chat.pendingToolApproval != nil || !chat.busy }
        let approval = try XCTUnwrap(chat.pendingToolApproval, chat.error ?? "The model did not request the script tool.")
        XCTAssertEqual(approval.displayedCall.name, "run_script"); XCTAssertNil(runner.lastProcessID)
        displayedArguments = approval.displayedCall.argumentsJSON
        guard approval.displayedCall.name == "run_script", runner.lastProcessID == nil else { return }
        chat.answerToolApproval(approved: true, ticketID: approval.ticketID)
        try await scriptChatWait(seconds: 120) { !chat.busy || chat.pendingToolApproval != nil || chat.pendingUserQuestion != nil }
        XCTAssertFalse(chat.busy); XCTAssertNil(chat.error); XCTAssertNil(chat.pendingToolApproval); XCTAssertNil(chat.pendingUserQuestion)
        let tool = try XCTUnwrap(chat.current?.messages.first { $0.toolName == "run_script" })
        let computed = tool.content.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(tool.status, .complete); XCTAssertEqual(computed, "56913867"); XCTAssertEqual(tool.toolPrivateDataRead, false)
        XCTAssertNotEqual(runner.lastProcessID, getpid())
        let answer = chat.current?.messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertEqual(answer, "56913867")
        completed = !chat.busy && chat.error == nil && tool.status == .complete && computed == "56913867" && answer == "56913867" && runner.lastProcessID != nil && runner.lastProcessID != getpid()
    }
}
