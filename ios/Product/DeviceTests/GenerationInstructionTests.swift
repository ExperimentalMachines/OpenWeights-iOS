import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    @MainActor func testNativeStandingInstructionsWithoutLengthGuidanceChangeInSameConversation() async throws {
        let pinned = try NativeAgentArtifact.selected()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-standing-only-" + UUID().uuidString)
        let suite = "openweights.standing-only." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        let libraryFile = root.appendingPathComponent("models.json")
        let downloads = ModelDownloads(root:root.appendingPathComponent("Models"),library:try ModelLibrary(file:libraryFile),sessionIdentifier:suite)
        let observed = NativeObservedRuntime(LlamaRuntime(gpuLayers:99))
        let chat = ChatController(store:try ConversationStore(file:root.appendingPathComponent("conversations.json")),downloads:downloads,defaults:defaults,runtimeFactory:{ _ in observed })
        var observations: [[String:Any]] = [], completed = false
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            chat.prepareForInactivity(); downloads.cancelAllTransfers(); UIApplication.shared.isIdleTimerDisabled = idle
            defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root)
            let value: [String:Any] = ["purpose":"native-standing-instruction-only-save-change-in-existing-conversation", "completed":completed,
                "artifact":NativeAgentArtifact.evidence(pinned), "observations":observations, "runtimeTrace":observed.snapshot(),
                "limitations":["Separate control with answer length unset. Does not replace the retained combined-instruction acceptance, which remains failing.",
                    "One pinned greedy GGUF Metal artifact. No positive reasoning-effort effect, UI gesture, answer-length quality or general model-quality claim."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Standing instruction only control"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let source = cachedDirectory(artifact:"gguf",revision:try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source,file:try XCTUnwrap(pinned.files.first)); await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first)
        model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1
        model.settings.thinking = false; model.settings.contextTokens = 4096; model.settings.outputTokens = 128
        model.settings.systemPrompt = "For every user message in this conversation, reply only with the word Cedar."
        model.settings.reasoningEffort = .low
        try await downloads.saveSettings(model); await chat.load(model); XCTAssertNil(chat.error)
        let created = await chat.newConversation(); XCTAssertTrue(created)
        let conversationID = try XCTUnwrap(chat.current?.id)
        @MainActor func finishTurn() async throws -> String {
            let deadline = ProcessInfo.processInfo.systemUptime + 60
            while chat.busy {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTAssertNil(chat.error)
            return try XCTUnwrap(chat.current?.messages.last { $0.role == .assistant }?.content).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        chat.draft = "Confirm that you read the instructions."; await chat.send()
        let first = try await finishTurn()
        observations.append(["stage":"Cedar-standing-only", "answer":first]); XCTAssertTrue(["Cedar","Cedar."].contains(first))
        model.settings.systemPrompt = "For every user message in this conversation, reply only with the word Cobalt."
        model.settings.reasoningEffort = .high
        try await chat.saveModelSettings(model); XCTAssertEqual(chat.current?.id,conversationID)
        chat.draft = "Confirm again."; await chat.send()
        let second = try await finishTurn()
        observations.append(["stage":"Cobalt-standing-only-same-conversation", "answer":second]); XCTAssertTrue(["Cobalt","Cobalt."].contains(second))
        let library = try ModelLibrary(file:libraryFile), reopened = await library.list()
        XCTAssertEqual(reopened.first { $0.id == model.id }?.settings.systemPrompt,model.settings.systemPrompt)
        XCTAssertNil(reopened.first { $0.id == model.id }?.settings.answerLength)
        XCTAssertFalse(chat.supportsReasoningEffort,"The pinned Qwen3 template should ignore effort.")
        completed = true
    }
    @MainActor func testNativeInstructionFailureFrozenPromptReplay() async throws {
        let pinned = try NativeAgentArtifact.selected()
        let directory = cachedDirectory(artifact:"gguf",revision:try XCTUnwrap(pinned.revision))
        try ModelDownloads.verify(directory.appendingPathComponent(pinned.entryFile),file:try XCTUnwrap(pinned.files.first))
        var model = pinned
        model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1
        model.settings.thinking = false; model.settings.contextTokens = 4096; model.settings.outputTokens = 128
        model.settings.answerLength = .brief; model.settings.reasoningEffort = .low
        model.settings.systemPrompt = "For every user message in this conversation, reply only with the word Cedar."
        let runtime = LlamaRuntime(gpuLayers:99)
        var observations: [[String:Any]] = [], completed = false
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            runtime.cancel(); UIApplication.shared.isIdleTimerDisabled = idle
            let value: [String:Any] = ["purpose":"native-frozen-instruction-failure-fresh-versus-warmed-replay", "completed":completed,
                "artifact":NativeAgentArtifact.evidence(pinned), "observations":observations,
                "limitations":["Diagnostic of the retained failed standing-instruction acceptance. No acceptance requirement is changed.",
                    "Same pinned greedy Metal artifact and frozen first-turn prompt. Two extra controls remove answer-length instructions and effort independently.",
                    "A matching fresh/warmed failure would rule out warming as the necessary cause for this one prompt. It would not prove general cache correctness or model instruction quality."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Frozen instruction prompt replay"; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await runtime.load(model:model,directory:directory)
        var answers: [String] = []
        for stage in ["frozen-fresh","frozen-warmed","without-answer-length","without-effort"] {
            await runtime.reset()
            var settings = model.settings
            if stage == "without-answer-length" { settings.answerLength = nil }
            if stage == "without-effort" { settings.reasoningEffort = nil }
            // Freeze pre-precedence prompt bytes. Later fixes must not rewrite this control.
            let frozenHead = [ChatController.systemPrompt,settings.answerLength?.instruction,settings.systemPrompt].compactMap { $0 }.joined(separator:"\n\n")
            let messages = [["role":"system","content":frozenHead],
                ["role":"user","content":"Confirm that you read the instructions."]]
            let count = try await runtime.promptSize(messages:messages,settings:settings,tools:[])
            if stage == "frozen-warmed" { try await runtime.warm(messages:[messages[0]],settings:settings) }
            var reply: RuntimeReply?
            for try await event in runtime.stream(messages:messages,settings:settings) { if case .reply(let value) = event { reply = value } }
            let result = try XCTUnwrap(reply)
            observations.append(["stage":stage, "messages":messages, "reasoningEffort":settings.reasoningEffort?.wireValue ?? "",
                "answer":result.content, "cachedTokens":result.cachedTokens, "generatedTokens":result.generatedTokens,
                "promptTokens":count.tokens, "promptCountExact":count.exact, "cancelled":result.cancelled])
            XCTAssertFalse(result.cancelled); XCTAssertFalse(result.content.isEmpty)
            if stage == "frozen-fresh" { XCTAssertEqual(result.cachedTokens,0); answers.append(result.content) }
            if stage == "frozen-warmed" { XCTAssertGreaterThan(result.cachedTokens,0); answers.append(result.content) }
        }
        XCTAssertEqual(answers.count,2); XCTAssertEqual(answers.first,answers.last,"Warming changed the frozen greedy answer.")
        completed = true
    }
    @MainActor func testNativeStandingInstructionsChangeReopenAndReset() async throws {
        let pinned = try NativeAgentArtifact.selected()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-instructions-" + UUID().uuidString)
        let suite = "openweights.instructions." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        let libraryFile = root.appendingPathComponent("models.json"), conversationFile = root.appendingPathComponent("conversations.json")
        let downloads = ModelDownloads(root:root.appendingPathComponent("Models"),library:try ModelLibrary(file:libraryFile),sessionIdentifier:suite)
        let observed = NativeObservedRuntime(LlamaRuntime(gpuLayers:99))
        let chat = ChatController(store:try ConversationStore(file:conversationFile),downloads:downloads,defaults:defaults,runtimeFactory:{ _ in observed })
        var completed = false, observations: [[String:Any]] = []
        defer {
            chat.prepareForInactivity(); downloads.cancelAllTransfers()
            UIApplication.shared.isIdleTimerDisabled = idle; defaults.removePersistentDomain(forName:suite)
            try? FileManager.default.removeItem(at:root)
            let value: [String:Any] = ["purpose":"native-standing-instructions-change-reopen-reset-and-template-capability", "completed":completed,
                "observations":observations, "runtimeTrace":observed.snapshot(), "artifact":NativeAgentArtifact.evidence(pinned),
                "operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
                "acceptance":"Neutral first turn must reply Cedar or Cedar. Changed system instruction in the same conversation must reply Cobalt or Cobalt.",
                "limitations":["One real pinned greedy GGUF Metal artifact. Does not measure answer-length distribution, model quality, speed or positive reasoning-effort effect.",
                    "Actual controllers and storage are used. Reset changes are saved programmatically, not through a user gesture on Reset defaults.",
                    "No tools, notifications, other runtime inference or OS background task are requested. Tool approval remains covered by separate canonical controls."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Native instruction settings"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let source = cachedDirectory(artifact:"gguf",revision:try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source,file:try XCTUnwrap(pinned.files.first)); await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first)
        model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1
        model.settings.thinking = false; model.settings.contextTokens = 4096; model.settings.outputTokens = 128
        model.settings.answerLength = .brief; model.settings.reasoningEffort = .low
        model.settings.systemPrompt = "For every user message in this conversation, reply only with the word Cedar."
        model.settings.toolPrompt = "This tool-only text must not be sent without tools."
        try await downloads.saveSettings(model); await chat.load(model); XCTAssertNil(chat.error)
        let created = await chat.newConversation(); XCTAssertTrue(created)
        let conversation = try XCTUnwrap(chat.current)
        let conversationID = conversation.id
        @MainActor func finishTurn() async throws -> String {
            let deadline = ProcessInfo.processInfo.systemUptime + 60
            while chat.busy {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTAssertNil(chat.error)
            return try XCTUnwrap(chat.current?.messages.last { $0.role == .assistant }?.content).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        chat.draft = "Confirm that you read the instructions."; await chat.send()
        let first = try await finishTurn()
        observations.append(["stage":"first-saved-instruction", "answer":first, "supportsReasoningEffort":chat.supportsReasoningEffort])
        XCTAssertTrue(["Cedar","Cedar."].contains(first),"The model did not follow the standing instruction.")
        model.settings.systemPrompt = "For every user message in this conversation, reply only with the word Cobalt."
        model.settings.reasoningEffort = .high; model.settings.answerLength = .thorough
        try await chat.saveModelSettings(model)
        XCTAssertEqual(chat.current?.id,conversationID)
        chat.draft = "Confirm again."; await chat.send()
        let second = try await finishTurn()
        observations.append(["stage":"changed-instruction-same-conversation", "answer":second, "conversationID":conversationID.uuidString])
        XCTAssertTrue(["Cobalt","Cobalt."].contains(second),"The changed standing instruction was not followed in the same conversation.")
        let reopened = try ModelLibrary(file:libraryFile), models = await reopened.list()
        let saved = try XCTUnwrap(models.first { $0.id == model.id })
        XCTAssertEqual(saved.settings.systemPrompt,model.settings.systemPrompt)
        XCTAssertEqual(saved.settings.reasoningEffort,.high); XCTAssertEqual(saved.settings.answerLength,.thorough)
        let history = try ConversationStore(file:conversationFile), stored = await history.list()
        XCTAssertEqual(stored.first { $0.id == conversationID }?.messages,chat.current?.messages)
        let trace = observed.snapshot(), streams = try XCTUnwrap(trace["streams"] as? [[String:Any]])
        let preparations = try XCTUnwrap(trace["preparations"] as? [[String:Any]])
        XCTAssertEqual(streams.count,2)
        for (index,settings) in [(0,streams[0]),(1,streams[1])] {
            let messages = try XCTUnwrap(settings["messages"] as? [[String:String]])
            let head = try XCTUnwrap(messages.first?["content"])
            XCTAssertFalse(head.contains(model.settings.toolPrompt!))
            let effort = index == 0 ? "low" : "high"
            XCTAssertEqual(settings["reasoningEffort"] as? String,effort)
            for kind in ["count","warm"] {
                XCTAssertTrue(preparations.contains { ($0["kind"] as? String) == kind && ($0["systemHead"] as? String) == head && ($0["reasoningEffort"] as? String) == effort })
            }
        }
        var reset = saved; reset.settings = ModelSettings()
        try await chat.saveModelSettings(reset)
        let resetLibrary = try ModelLibrary(file:libraryFile), afterReset = await resetLibrary.list()
        XCTAssertEqual(afterReset.first { $0.id == reset.id }?.settings,ModelSettings())
        XCTAssertEqual(chat.loadedModel?.settings,ModelSettings())
        let resetTrace = observed.snapshot(), resetPreparations = try XCTUnwrap(resetTrace["preparations"] as? [[String:Any]])
        XCTAssertTrue(resetPreparations.contains { ($0["kind"] as? String) == "warm" && ($0["systemHead"] as? String) == ChatController.systemPrompt && ($0["reasoningEffort"] as? String) == "" })
        observations.append(["stage":"reopen-and-reset", "storedTurns":stored.first { $0.id == conversationID }?.messages.count ?? 0,
            "resetRestoresLegacyPromptHead":true, "resetSettingsEqualDefaults":true])
        completed = true
    }
}
