import XCTest
import Foundation
import UIKit
import OpenWeightsCore
@testable import OpenWeights

private final class NativeWeakModelRuntime {
    weak var value: NativeObservedRuntime?
    init(_ value: NativeObservedRuntime) { self.value = value }
}

extension ProductTests {
    func testNativeConversationAcrossGGUFMLXAndCompiledModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-model-switch-" + UUID().uuidString)
        let suite = root.lastPathComponent, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let libraryFile = root.appendingPathComponent("models.json"), conversationFile = root.appendingPathComponent("chats.json")
        let library = try ModelLibrary(file: libraryFile)
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: library, sessionIdentifier: suite)
        var chat: ChatController?, completed = false, observations: [[String: Any]] = [], boxes: [NativeWeakModelRuntime] = []
        var artifacts: [[String: Any]] = [], actions: [String] = []
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            chat?.cancel(); downloads.cancelAllTransfers(); defaults.removePersistentDomain(forName: suite)
            UIApplication.shared.isIdleTimerDisabled = idle; try? FileManager.default.removeItem(at: root)
            let data: [String: Any] = ["purpose": "native-conversation-three-adapter-model-switch-reopen-remove", "completed": completed,
                "actions": actions, "observations": observations, "artifacts": artifacts,
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations": ["Real pinned Qwen3 GGUF/MLX/XNNPACK adapters through actual product controllers. Ready-model fixtures hard-link verified cached files into isolated library paths. This test does not exercise acquisition, external providers or picker gestures.",
                    "Reopening recreates controllers and actor stores in the same host process. Weak wrapper release does not measure process footprint or GPU allocation reclamation. No OS termination, performance, energy or general family/quality claim."]]
            let attachment = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "native-model-switch.json"; attachment.lifetime = .keepAlways; add(attachment)
        }
        var models: [LocalModel] = []
        for backend in [ModelBackend.llamaMetal, .mlx, .xnnpack] {
            var model = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == backend })
            let cached = cachedDirectory(artifact: backend == .mlx ? "mlx" : backend == .xnnpack ? "executorch" : "gguf", revision: try XCTUnwrap(model.revision))
            model.state = .ready; model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1
            model.settings.outputTokens = 48; model.settings.thinking = false
            for file in model.files {
                let original = try file.destination(in: cached), owned = try file.destination(in: downloads.directory(model))
                try ModelDownloads.verify(original, file: file)
                try FileManager.default.createDirectory(at: owned.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.linkItem(at: original, to: owned)
                try ModelDownloads.verify(owned, file: file)
            }
            try await library.save(model); models.append(model); artifacts.append(NativeAgentArtifact.evidence(model))
        }
        await downloads.restore(); XCTAssertEqual(downloads.models.count, 3)
        let factory: (LocalModel) throws -> any ChatRuntime = { model in
            let observed = NativeObservedRuntime(try RuntimeFactory.make(model)); boxes.append(NativeWeakModelRuntime(observed)); return observed
        }
        chat = ChatController(store: try ConversationStore(file: conversationFile), downloads: downloads, defaults: defaults, runtimeFactory: factory)
        func runTurn(_ prompt: String, expected: [String]) async throws {
            let value = try XCTUnwrap(chat)
            value.draft = prompt; await value.send(); try await waitUntil(seconds: 120) { !value.busy && !value.loading }
            XCTAssertNil(value.error)
            let answer = try XCTUnwrap(value.current?.messages.last { $0.role == .assistant }?.content)
            XCTAssertTrue(expected.allSatisfy { answer.localizedCaseInsensitiveContains($0) }, answer)
            guard value.error == nil, expected.allSatisfy({ answer.localizedCaseInsensitiveContains($0) }) else {
                throw ModelError.unsupported("Switched-model factual acceptance failed: " + answer)
            }
        }
        var conversationID: UUID?
        for (position, modelIndex) in [0, 1, 2, 0].enumerated() {
            let previous = boxes.last, before = chat?.current?.messages
            await chat?.load(models[modelIndex]); XCTAssertNil(chat?.error); XCTAssertEqual(chat?.loadedModel?.id, models[modelIndex].id)
            if let previous { try await waitUntil(seconds: 3) { previous.value == nil } }
            if let before { XCTAssertEqual(chat?.current?.messages, before); XCTAssertEqual(chat?.current?.id, conversationID) }
            if position == 0 {
                try await runTurn("Remember these project facts: Cedar is in Porto with budget 620 and vegetarian food. Confirm briefly.", expected: ["Cedar", "Porto", "620", "vegetarian"])
                conversationID = chat?.current?.id
            } else if position == 1 {
                try await runTurn("Correction: Cedar is now in Osaka with budget 730. Keep vegetarian. State the current project, city, budget and diet in one short sentence.", expected: ["Cedar", "Osaka", "730", "vegetarian"])
            } else {
                try await runTurn("State the current project, city, budget and diet in one short sentence.", expected: ["Cedar", "Osaka", "730", "vegetarian"])
            }
            let saved = try await ConversationStore(file: conversationFile).conversation(try XCTUnwrap(conversationID))
            XCTAssertEqual(saved.messages, chat?.current?.messages); XCTAssertEqual(saved.modelID, models[modelIndex].id)
            observations.append(["phase": position, "backend": models[modelIndex].backend.rawValue,
                "conversationID": saved.id.uuidString, "modelID": models[modelIndex].id.uuidString, "messageCount": saved.messages.count,
                "runtimeTrace": boxes.last?.value?.snapshot() ?? [:]])
        }
        actions.append("one-durable-conversation-GGUF-MLX-XNNPACK-GGUF-keeps-corrected-facts-and-releases-previous-wrappers")
        let saved = try XCTUnwrap(chat?.current), previous = boxes.last
        chat?.cancel(); chat = nil
        if let previous { try await waitUntil(seconds: 3) { previous.value == nil } }
        let reopenedDownloads = ModelDownloads(root: downloads.root, library: try ModelLibrary(file: libraryFile), sessionIdentifier: suite + ".reopen")
        await reopenedDownloads.restore()
        chat = ChatController(store: try ConversationStore(file: conversationFile), downloads: reopenedDownloads, defaults: defaults, runtimeFactory: factory)
        await chat?.restore(); XCTAssertNil(chat?.error); XCTAssertEqual(chat?.current?.messages, saved.messages)
        await chat?.open(saved); XCTAssertNil(chat?.error); XCTAssertEqual(chat?.loadedModel?.id, models[0].id)
        try await runTurn("State the current project, city, budget and diet in one short sentence.", expected: ["Cedar", "Osaka", "730", "vegetarian"])
        actions.append("controller-library-store-reopen-auto-loads-stored-model-and-preserves-corrected-history")
        let beforeRemoval = try XCTUnwrap(chat?.current)
        try await reopenedDownloads.remove(models[1]); XCTAssertFalse(FileManager.default.fileExists(atPath: reopenedDownloads.directory(models[1]).path))
        XCTAssertEqual(chat?.loadedModel?.id, models[0].id); XCTAssertEqual(chat?.current, beforeRemoval)
        let remaining = await (try ModelLibrary(file: libraryFile)).list(); XCTAssertEqual(Set(remaining.map(\.id)), Set([models[0].id, models[2].id]))
        try await runTurn("State the current project, city, budget and diet in one short sentence.", expected: ["Cedar", "Osaka", "730", "vegetarian"])
        observations.append(["phase": "reopen-and-remove-unloaded-MLX", "runtimeTrace": boxes.last?.value?.snapshot() ?? [:]])
        actions.append("remove-unloaded-model-preserves-active-model-transcript-and-next-real-reply")
        completed = true
    }
}
