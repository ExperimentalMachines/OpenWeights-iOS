import Foundation
import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    func testNativeMLXMemoryToolApprovalReadDeclineStopAndRecovery() async throws {
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .mlx })
        try await exerciseMLXMemoryTools(pinned: pinned, cached: cachedDirectory(artifact: "mlx", revision: try XCTUnwrap(pinned.revision)))
    }
    func testNativeQwen25MLXMemoryToolApprovalReadDeclineStopAndRecovery() async throws {
        let pinned = NativeMLXArtifact.qwen25()
        let retained = try await retainedMLXDownload(pinned)
        try await exerciseMLXMemoryTools(pinned: pinned, cached: retained.directory)
    }
    private func exerciseMLXMemoryTools(pinned: LocalModel, cached: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-mlx-tools-" + UUID().uuidString)
        let suite = root.lastPathComponent, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let memoryFile = root.appendingPathComponent("memory.json"), conversationsFile = root.appendingPathComponent("conversations.json")
        let memory = MemoryController(store: try MemoryStore(file: memoryFile), defaults: defaults)
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")), sessionIdentifier: suite)
        var model = pinned
        let directory = downloads.directory(model)
        for file in model.files {
            let source = try file.destination(in: cached), owned = try file.destination(in: directory)
            try ModelDownloads.verify(source, file: file)
            try FileManager.default.createDirectory(at: owned.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.linkItem(at: source, to: owned)
        }
        model.state = .ready; model.settings.temperature = 0; model.settings.repeatPenalty = 1
        model.settings.outputTokens = 128; model.settings.contextTokens = 4096; model.settings.thinking = false
        try await downloads.save(model)
        let observed = NativeObservedRuntime(ProductMLXRuntime())
        let chat = ChatController(store: try ConversationStore(file: conversationsFile), downloads: downloads, memory: memory, defaults: defaults, runtimeFactory: { _ in observed })
        var completed = false, actions: [String] = [], approvals: [[String: String]] = [], checks: [String: Any] = [:]
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            chat.cancel(); downloads.cancelAllTransfers(); defaults.removePersistentDomain(forName: suite)
            UIApplication.shared.isIdleTimerDisabled = idle
            if completed { try? FileManager.default.removeItem(at: root) }
            let data: [String: Any] = ["purpose": "native-mlx-real-model-memory-tools", "completed": completed, "actions": actions, "approvals": approvals,
                "runtimeTrace": observed.snapshot(), "controllerError": chat.error ?? "", "artifact": NativeAgentArtifact.evidence(model), "checks": checks,
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations": ["Real pinned declared-family MLX inference with actual product memory tools and controller-driven exact approvals. No picker/menu/touch or general model quality claim.",
                    "Ready model fixture hard-links verified cached files. Persistence reopens actor stores in the same process, not OS process death. No other MLX family, provider, energy or performance claim."]]
            let a = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            a.name = "native-mlx-tools.json"; a.lifetime = .keepAlways; add(a)
        }
        await chat.load(model); XCTAssertNil(chat.error); XCTAssertTrue(chat.supportsTools)
        guard chat.error == nil, chat.supportsTools else { return }
        memory.writeEnabled = true
        chat.draft = "Remember this lasting fact: My project is Cedar. Use save_memory with that exact fact."; await chat.send()
        try await waitUntil(seconds: 120) { chat.pendingToolApproval != nil || !chat.busy }
        let save = try XCTUnwrap(chat.pendingToolApproval, chat.error ?? "No save approval was requested.")
        XCTAssertEqual(save.displayedCall.name, "save_memory")
        let before = await memory.store.list(); XCTAssertTrue(before.isEmpty)
        guard save.displayedCall.name == "save_memory", before.isEmpty else { return }
        approvals.append(["name": save.displayedCall.name, "arguments": save.displayedCall.argumentsJSON, "decision": "approve"])
        chat.answerToolApproval(approved: true, ticketID: save.ticketID)
        try await waitUntil(seconds: 120) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertFalse(chat.busy); XCTAssertNil(chat.error)
        let savedFacts = await memory.store.list()
        let exactFact = ["My project is Cedar.", "My project is Cedar"].contains(savedFacts.first?.text ?? "")
        checks["savedFact"] = savedFacts.first?.text ?? ""; checks["matchesSavedFact"] = exactFact
        XCTAssertEqual(savedFacts.count, 1); XCTAssertTrue(exactFact)
        guard !chat.busy, chat.error == nil, savedFacts.count == 1, exactFact else { return }
        actions.append("model-generated-tagged-save-stays-uncommitted-before-exact-approval-and-then-persists")
        let savedConversation = try XCTUnwrap(chat.current)
        let savedCalls = savedConversation.messages.filter { $0.role == .assistant && $0.toolCalls?.isEmpty == false }
        XCTAssertTrue(savedCalls.contains { $0.promptContent?.contains("<tool_call>") == true })
        XCTAssertTrue(savedConversation.messages.contains { $0.role == .tool && $0.toolName == "save_memory" && $0.status == .complete })
        let reopened = try await ConversationStore(file: conversationsFile).conversation(savedConversation.id)
        XCTAssertEqual(reopened.messages, savedConversation.messages)
        let durableFacts = await (try MemoryStore(file: memoryFile)).list(); XCTAssertEqual(durableFacts, savedFacts)
        actions.append("raw-call-tool-result-and-saved-fact-survive-store-reopen")
        memory.writeEnabled = false; memory.readEnabled = true
        await chat.newConversation(); chat.draft = "Use read_memory to find my saved project. Reply with only the project name."; await chat.send()
        try await waitUntil(seconds: 120) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertFalse(chat.busy); XCTAssertNil(chat.error); XCTAssertNil(chat.pendingToolApproval)
        let readCalled = chat.current?.messages.contains { $0.role == .tool && $0.toolName == "read_memory" && $0.status == .complete } == true
        XCTAssertTrue(readCalled)
        let readAnswer = chat.current?.messages.last { $0.role == .assistant }?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let exactReadAnswer = ["Cedar", "Cedar."].contains(readAnswer)
        checks["readToolCalled"] = readCalled; checks["readAnswer"] = readAnswer; checks["matchesReadAnswer"] = exactReadAnswer
        XCTAssertTrue(exactReadAnswer)
        // A failed answer assertion must not hide independent approval/Stop
        // controls. Continue only after this request has structurally finished.
        guard !chat.busy, chat.error == nil, chat.pendingToolApproval == nil else { return }
        if readCalled { actions.append("new-chat-model-generated-read-and-follow-up-answer-consume-persisted-tool-result") }
        memory.readEnabled = false; memory.writeEnabled = true
        for stop in [false, true] {
            await chat.newConversation(); chat.draft = "Remember this lasting fact: My project is Maple. Use save_memory with that exact fact."; await chat.send()
            try await waitUntil(seconds: 120) { chat.pendingToolApproval != nil || !chat.busy }
            let pending = try XCTUnwrap(chat.pendingToolApproval); XCTAssertEqual(pending.displayedCall.name, "save_memory")
            approvals.append(["name": pending.displayedCall.name, "arguments": pending.displayedCall.argumentsJSON, "decision": stop ? "stop" : "decline"])
            if stop { chat.cancel() } else { chat.answerToolApproval(approved: false, ticketID: pending.ticketID) }
            try await waitUntil(seconds: 120) { !chat.busy || chat.pendingToolApproval != nil }
            XCTAssertFalse(chat.busy); XCTAssertNil(chat.pendingToolApproval)
            let facts = await memory.store.list(); XCTAssertEqual(facts, savedFacts)
            guard !chat.busy, chat.pendingToolApproval == nil, facts == savedFacts else { return }
            actions.append(stop ? "stop-at-exact-approval-performs-no-write" : "declined-exact-call-performs-no-write")
        }
        memory.writeEnabled = false; memory.readEnabled = false
        await chat.newConversation(); chat.draft = "What is 2 + 2? Reply with only the number."; await chat.send()
        try await waitUntil(seconds: 120) { !chat.busy }
        let recovery = chat.current?.messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        checks["recoveryAnswer"] = recovery; checks["matchesRecoveryAnswer"] = recovery == "4"
        XCTAssertNil(chat.error); XCTAssertEqual(recovery, "4")
        guard chat.error == nil, recovery == "4" else { return }
        actions.append("tool-free-exact-arithmetic-answer-recovers-after-stopped-approval")
        completed = readCalled && exactReadAnswer
    }
    func testNativeMLXFreshAndWarmedRecoveryPromptControls() async throws {
        var model = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .mlx })
        model.settings.temperature = 0; model.settings.repeatPenalty = 1; model.settings.outputTokens = 128
        model.settings.contextTokens = 4096; model.settings.thinking = false
        let directory = cachedDirectory(artifact: "mlx", revision: try XCTUnwrap(model.revision))
        for file in model.files { try ModelDownloads.verify(file.destination(in: directory), file: file) }
        let observed = NativeObservedRuntime(ProductMLXRuntime()); var completed = false, results: [[String: Any]] = []
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            observed.cancel(); UIApplication.shared.isIdleTimerDisabled = idle
            let data: [String: Any] = ["purpose": "native-mlx-fresh-warmed-recovery-prompt-controls", "completed": completed,
                "observations": results, "runtimeTrace": observed.snapshot(), "artifact": NativeAgentArtifact.evidence(model),
                "limitations": ["Same real pinned artifact, messages and settings as the post-Stop recovery fixture. Isolated fresh/warmed calls compare cache behavior, not general model quality or all Stop races.", "The original exact-Cedar request remains an instruction-compliance probe. Capturing its refusal is not a successful exact-Cedar answer. The separate arithmetic probe requires exactly 4."]]
            let a = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            a.name = "native-mlx-recovery-controls.json"; a.lifetime = .keepAlways; add(a)
        }
        try await observed.load(model: model, directory: directory)
        let head = [["role": "system", "content": ChatController.systemPrompt]]
        for prompt in ["Reply with exactly Cedar.", "What is 2 + 2? Reply with only the number."] {
            let messages = head + [["role": "user", "content": prompt]]
            await observed.reset(); var fresh: RuntimeReply?
            for try await event in observed.stream(messages: messages, settings: model.settings) { if case .reply(let reply) = event { fresh = reply } }
            let first = try XCTUnwrap(fresh); XCTAssertFalse(first.cancelled); XCTAssertEqual(first.cachedTokens, 0)
            await observed.reset(); try await observed.warm(messages: head, settings: model.settings); var warmed: RuntimeReply?
            for try await event in observed.stream(messages: messages, settings: model.settings) { if case .reply(let reply) = event { warmed = reply } }
            let second = try XCTUnwrap(warmed); XCTAssertFalse(second.cancelled); XCTAssertGreaterThan(second.cachedTokens, 0)
            XCTAssertEqual(first.content, second.content)
            if prompt.hasPrefix("What") { XCTAssertEqual(first.content.trimmingCharacters(in: .whitespacesAndNewlines), "4") }
            results.append(["prompt": prompt, "fresh": first.content, "warmed": second.content, "freshCachedTokens": first.cachedTokens,
                "warmCachedTokens": second.cachedTokens, "exactCedar": first.content.trimmingCharacters(in: .whitespacesAndNewlines) == "Cedar"])
        }
        completed = true
    }

}
