import Foundation
import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    func testNativeCompiledToolCountWarmWithdrawalAndAdmission() async throws {
        var model = try NativeCompiledArtifact.selected()
        model.settings.temperature = 0; model.settings.repeatPenalty = 1; model.settings.outputTokens = 96; model.settings.thinking = false
        let directory = cachedDirectory(artifact: "executorch", revision: try XCTUnwrap(model.revision))
        for file in model.files { try ModelDownloads.verify(file.destination(in: directory), file: file) }
        let runtime = ProductExecuTorchRuntime(), observed = NativeObservedRuntime(runtime)
        var completed = false, counts: [String: Int] = [:]
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            observed.cancel(); UIApplication.shared.isIdleTimerDisabled = idle
            let value: [String: Any] = ["purpose": "native-compiled-tools-count-warm-withdrawal-admission", "completed": completed,
                "counts": counts, "runtimeTrace": observed.snapshot(), "artifact": NativeAgentArtifact.evidence(model),
                "limitations": ["Actual supported Qwen compiled XNNPACK adapter, native tokenizer and the explicitly selected pinned artifact. Isolated calls do not exercise touch, other compiled families or general tool reliability."]]
            let a = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            a.name = "native-compiled-tool-contract.json"; a.lifetime = .keepAlways; add(a)
        }
        XCTAssertFalse(observed.supportsTools); try await observed.load(model: model, directory: directory); XCTAssertTrue(observed.supportsTools)
        let tools = [AgentToolDefinition(name: "read_memory", description: "Read the user's saved project fact.", parametersJSON: "{\"type\":\"object\",\"properties\":{}}")]
        let head = [["role": "system", "content": ChatController.systemPrompt]]
        let messages = head + [["role": "user", "content": "Call read_memory with no arguments."]]
        let size = try await observed.promptSize(messages: messages, settings: model.settings, tools: tools)
        let plain = try await observed.promptSize(messages: messages, settings: model.settings, tools: [])
        let counter = try OWExecuTorchTokenizer(path: directory.appendingPathComponent("tokenizer.json").path)
        XCTAssertTrue(size.exact); XCTAssertGreaterThan(size.tokens, plain.tokens)
        let family = try XCTUnwrap(CompiledModelFamily(rawValue: model.family ?? ""))
        XCTAssertEqual(size.tokens, try counter.countPrompt(family.render(messages, tools: tools, thinking: false)).intValue)
        counts = ["withTools": size.tokens, "withoutTools": plain.tokens]
        try await observed.warm(messages: head, settings: model.settings, tools: tools)
        var call: RuntimeReply?
        for try await event in observed.stream(messages: messages, settings: model.settings, tools: tools) { if case .reply(let reply) = event { call = reply } }
        let reply = try XCTUnwrap(call); XCTAssertFalse(reply.cancelled); XCTAssertEqual(reply.stopReason, .endOfTurn)
        XCTAssertEqual(reply.toolCalls.map(\.name), ["read_memory"]); XCTAssertGreaterThan(reply.cachedTokens, 0)
        XCTAssertTrue(reply.promptContent?.contains("read_memory") == true)
        guard reply.toolCalls.map(\.name) == ["read_memory"] else { return }
        var cappedSettings = model.settings; cappedSettings.outputTokens = 1
        var capped: RuntimeReply?
        for try await event in observed.stream(messages: messages, settings: cappedSettings, tools: tools) { if case .reply(let value) = event { capped = value } }
        let partial = try XCTUnwrap(capped)
        XCTAssertEqual(partial.stopReason, .maxTokens); XCTAssertTrue(partial.toolCalls.isEmpty); XCTAssertFalse(partial.cancelled)
        let recovery = head + [["role": "user", "content": "What is 2 + 2? Reply with only the number."]]
        var recovered: RuntimeReply?
        for try await event in observed.stream(messages: recovery, settings: model.settings, tools: []) { if case .reply(let value) = event { recovered = value } }
        let fresh = try XCTUnwrap(recovered)
        XCTAssertEqual(fresh.cachedTokens, 0); XCTAssertTrue(fresh.toolCalls.isEmpty); XCTAssertFalse(fresh.cancelled)
        XCTAssertEqual(fresh.content.trimmingCharacters(in: .whitespacesAndNewlines), "4")
        let overflow = head + [["role": "user", "content": String(repeating: " a", count: 2048)]]
        var emitted = 0, refused = false
        do { for try await _ in observed.stream(messages: overflow, settings: model.settings, tools: tools) { emitted += 1 } }
        catch { refused = true }
        XCTAssertTrue(refused); XCTAssertEqual(emitted, 0)
        completed = reply.toolCalls.map(\.name) == ["read_memory"] && reply.cachedTokens > 0 && fresh.cachedTokens == 0 && partial.stopReason == .maxTokens && partial.toolCalls.isEmpty
            && fresh.content.trimmingCharacters(in: .whitespacesAndNewlines) == "4" && refused && emitted == 0
    }
    func testNativeCompiledMemoryToolApprovalReadDeclineStopAndRecovery() async throws {
        try await nativeCompiledMemoryToolFlow(model:NativeCompiledArtifact.selected(),cacheArtifact:"executorch")
    }
    func testNativeExecuTorchMLXMemoryToolApprovalReadDeclineStopAndRecovery() async throws {
        try await nativeCompiledMemoryToolFlow(model:NativeCompiledArtifact.mlxDelegate(),cacheArtifact:"executorch-mlx")
    }
    private func nativeCompiledMemoryToolFlow(model selected:LocalModel,cacheArtifact:String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-compiled-tools-" + UUID().uuidString)
        let suite = root.lastPathComponent, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let memoryFile = root.appendingPathComponent("memory.json"), conversationsFile = root.appendingPathComponent("conversations.json")
        let memory = MemoryController(store: try MemoryStore(file: memoryFile), defaults: defaults)
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")), sessionIdentifier: suite)
        var model = selected
        let directory = downloads.directory(model), cached = cachedDirectory(artifact: cacheArtifact, revision: try XCTUnwrap(model.revision))
        for file in model.files {
            let source = try file.destination(in: cached), owned = try file.destination(in: directory)
            try ModelDownloads.verify(source, file: file)
            try FileManager.default.createDirectory(at: owned.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.linkItem(at: source, to: owned)
        }
        model.state = .ready; model.settings.temperature = 0; model.settings.repeatPenalty = 1
        model.settings.outputTokens = 128; model.settings.contextTokens = 2048; model.settings.thinking = false
        try await downloads.save(model)
        let observed = NativeObservedRuntime(try RuntimeFactory.make(model))
        let chat = ChatController(store: try ConversationStore(file: conversationsFile), downloads: downloads, memory: memory, defaults: defaults, runtimeFactory: { _ in observed })
        var completed = false, actions: [String] = [], approvals: [[String: String]] = []
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            chat.cancel(); downloads.cancelAllTransfers(); defaults.removePersistentDomain(forName: suite)
            UIApplication.shared.isIdleTimerDisabled = idle; try? FileManager.default.removeItem(at: root)
            let data: [String: Any] = ["purpose": "native-compiled-real-model-memory-tools", "completed": completed, "actions": actions, "approvals": approvals,
                "runtimeTrace": observed.snapshot(), "controllerError": chat.error ?? "", "artifact": NativeAgentArtifact.evidence(model),
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations": ["Real explicitly selected pinned Qwen inference through its declared compiled backend with actual product memory tools and controller-driven exact approvals. No picker/menu/touch or general model quality claim.",
                    "Ready model fixture hard-links verified cached files. Persistence reopens actor stores in the same process, not OS process death. No other compiled family, provider, energy or performance claim."]]
            let a = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            a.name = "native-compiled-tools.json"; a.lifetime = .keepAlways; add(a)
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
        if let extra = chat.pendingToolApproval {
            XCTAssertEqual(extra.displayedCall.name, "update_memory")
            let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(extra.displayedCall.argumentsJSON.utf8)) as? [String: String])
            XCTAssertEqual(arguments["old"], "My project is Cedar."); XCTAssertEqual(arguments["new"], "My project is Cedar.")
            guard extra.displayedCall.name == "update_memory", arguments["old"] == "My project is Cedar.", arguments["new"] == "My project is Cedar." else { return }
            let beforeDecline = await memory.store.list()
            approvals.append(["name": extra.displayedCall.name, "arguments": extra.displayedCall.argumentsJSON, "decision": "decline-redundant-update"])
            chat.answerToolApproval(approved: false, ticketID: extra.ticketID)
            try await waitUntil(seconds: 120) { !chat.busy || chat.pendingToolApproval != nil }
            let afterDecline = await memory.store.list(); XCTAssertEqual(afterDecline, beforeDecline)
            actions.append("redundant-model-generated-no-op-update-is-declined-without-changing-the-approved-fact")
        }
        XCTAssertFalse(chat.busy); XCTAssertNil(chat.error)
        let savedFacts = await memory.store.list(); XCTAssertEqual(savedFacts.count, 1); XCTAssertTrue(savedFacts.first?.text.contains("Cedar") == true)
        guard !chat.busy, chat.error == nil, savedFacts.count == 1, savedFacts.first?.text.contains("Cedar") == true else { return }
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
        await chat.newConversation(); chat.draft = "Use read_memory to find my saved project. Reply with its name."; await chat.send()
        try await waitUntil(seconds: 120) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertFalse(chat.busy); XCTAssertNil(chat.error); XCTAssertNil(chat.pendingToolApproval)
        XCTAssertTrue(chat.current?.messages.contains { $0.role == .tool && $0.toolName == "read_memory" && $0.status == .complete } == true)
        XCTAssertTrue(chat.current?.messages.last { $0.role == .assistant }?.content.contains("Cedar") == true)
        guard !chat.busy, chat.error == nil, chat.current?.messages.last?.content.contains("Cedar") == true else { return }
        actions.append("new-chat-model-generated-read-and-follow-up-answer-consume-persisted-tool-result")
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
        XCTAssertNil(chat.error); XCTAssertEqual(chat.current?.messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines), "4")
        guard chat.error == nil, chat.current?.messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines) == "4" else { return }
        actions.append("tool-free-exact-arithmetic-answer-recovers-after-stopped-approval")
        completed = true
    }
}
