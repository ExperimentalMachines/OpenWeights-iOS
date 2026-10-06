import Foundation
import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    func testNativeMLXPromptTokenEquivalenceDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-prompt-tokens-" + UUID().uuidString)
        let suite = root.lastPathComponent, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var chat: ChatController?, downloads: ModelDownloads?
        var observations: [[String: Any]] = [], collected = false
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            chat?.cancel(); downloads?.cancelAllTransfers()
            UIApplication.shared.isIdleTimerDisabled = idle; defaults.removePersistentDomain(forName: suite)
            let evidence: [String: Any] = ["purpose": "native-mlx-controller-prompt-token-diagnostics", "collectionCompleted": collected,
                "observations": observations,
                "limitations": ["Real controller calls use read-only verified files from retained test-owned download roots, hard-linked into separate owned diagnostic roots. No fresh download claim.",
                    "Tokens are encoded from captured real stream message arrays using the same production tokenizer loader and template context. This is not a hook capturing the private model container's internal input array.",
                    "A passing diagnostic means collection and controller/store checks succeeded, not requested-answer quality. Strict acquisition/import acceptance tests remain unchanged.",
                    "Two pinned artifacts on one phone do not establish general quality, root cause, performance, energy, measured fit or full parity."]]
            let attachment = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "MLX actual-controller prompt token diagnostics"; attachment.lifetime = .keepAlways; add(attachment)
            if collected { try? FileManager.default.removeItem(at: root) }
        }
        var qwen3 = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .mlx })
        qwen3.files.append(ModelFile(path: "model.safetensors.index.json", bytes: 49731,
            sha256: "7b294141456f6904936db03c00bca50fb5f6198f652fe8483f9cd2a1018accfb"))
        for pinned in [qwen3, NativeMLXArtifact.qwen25()] {
            let source = try await retainedMLXDownload(pinned)
            let stageRoot = root.appendingPathComponent(try XCTUnwrap(pinned.family))
            let library = try ModelLibrary(file: stageRoot.appendingPathComponent("models.json"))
            let manager = ModelDownloads(root: stageRoot.appendingPathComponent("Models"), library: library, sessionIdentifier: suite + "." + (pinned.family ?? ""))
            downloads = manager
            var model = pinned; model.id = UUID(); model.state = .ready
            model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1
            model.settings.outputTokens = 96; model.settings.contextTokens = 2048; model.settings.thinking = false
            var hashes: [String: String] = [:]
            for component in model.files {
                let input = try component.destination(in: source.directory), owned = try component.destination(in: manager.directory(model))
                try await Task.detached { try ModelFileTransfer.verify(input, file: component) }.value
                try FileManager.default.createDirectory(at: owned.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.linkItem(at: input, to: owned)
                hashes[component.path] = try await Task.detached { try ModelFileTransfer.hash(owned) }.value
                XCTAssertEqual(hashes[component.path], component.sha256)
            }
            try await library.save(model); await manager.restore()
            weak var observed: NativeObservedRuntime?
            let factory: (LocalModel) throws -> any ChatRuntime = { model in
                let wrapper = NativeObservedRuntime(try RuntimeFactory.make(model)); observed = wrapper; return wrapper
            }
            let store = try ConversationStore(file: stageRoot.appendingPathComponent("conversations.json"))
            chat = ChatController(store: store, downloads: manager, defaults: defaults, runtimeFactory: factory)
            await chat?.load(model); XCTAssertNil(chat?.error)
            chat?.draft = "Reply with exactly Cedar."; await chat?.send()
            try await waitUntil(seconds: 90) { chat?.busy == false }; XCTAssertNil(chat?.error)
            let first = try XCTUnwrap(chat?.current?.messages.last?.content)
            let current = try XCTUnwrap(chat?.current), stored = try await store.conversation(current.id)
            var expected = current; expected.updatedAt = stored.updatedAt
            XCTAssertEqual(stored, expected); XCTAssertGreaterThanOrEqual(stored.updatedAt, current.updatedAt)
            await chat?.open(stored); XCTAssertNil(chat?.error); XCTAssertEqual(chat?.current, stored)
            chat?.draft = "What is 2 + 2? Reply with only the number."; await chat?.send()
            try await waitUntil(seconds: 90) { chat?.busy == false }; XCTAssertNil(chat?.error)
            let second = try XCTUnwrap(chat?.current?.messages.last?.content), trace = try XCTUnwrap(observed).snapshot()
            let streams = try XCTUnwrap(trace["streams"] as? [[String: Any]])
            XCTAssertEqual(streams.count, 2); XCTAssertEqual(trace["omittedStreams"] as? Int, 0)
            let tokenizer = try await ProductTokenizerLoader().load(from: manager.directory(model))
            let context: [String: any Sendable] = ["enable_thinking": false]
            var prompts: [[String: Any]] = []
            for stream in streams {
                XCTAssertEqual(stream["inputTruncated"] as? Bool, false)
                XCTAssertEqual(stream["offeredTools"] as? [String], [])
                let messages = try XCTUnwrap(stream["messages"] as? [[String: String]])
                let ids = try tokenizer.applyChatTemplate(messages: messages.map { $0.mapValues { $0 as any Sendable } }, tools: nil, additionalContext: context)
                let usage = try XCTUnwrap(stream["usage"] as? [String: Any])
                let count = try XCTUnwrap(usage["promptTokens"] as? Int) + (try XCTUnwrap(usage["cachedTokens"] as? Int))
                XCTAssertEqual(ids.count, count)
                prompts.append(["messages": messages, "fullPromptTokenIDs": ids, "renderedPrompt": tokenizer.decode(tokenIds: ids), "actualRuntimeFullPromptCount": count])
            }
            let head: [[String: any Sendable]] = [["role": "system", "content": ChatController.systemPrompt]]
            let headIDs = try tokenizer.applyChatTemplate(messages: head, tools: nil, additionalContext: context)
            let probeIDs = try tokenizer.applyChatTemplate(messages: head + [["role": "user", "content": "OpenWeights warm prefix probe"]], tools: nil, additionalContext: context)
            var shared = 0
            while shared < min(headIDs.count, probeIDs.count), headIDs[shared] == probeIDs[shared] { shared += 1 }
            observations.append(["artifact": NativeAgentArtifact.evidence(model), "sourceFixtureRoot": source.root.lastPathComponent,
                "sourceLibrarySHA256": try ModelFileTransfer.hash(source.root.appendingPathComponent("models.json")),
                "independentFullFileSHA256": hashes, "runtimeTrace": trace, "encodedPrompts": prompts,
                "warmedSystemPrefixTokenIDs": Array(headIDs.prefix(shared)), "firstAnswer": first, "reopenedAnswer": second,
                "matchesCedarAcceptance": ["Cedar", "Cedar."].contains(first.trimmingCharacters(in: .whitespacesAndNewlines)),
                "matchesArithmeticAcceptance": second.trimmingCharacters(in: .whitespacesAndNewlines) == "4"])
            chat?.cancel(); chat = nil
            try await waitUntil(seconds: 3) { observed == nil }; XCTAssertNil(observed)
            manager.cancelAllTransfers(); downloads = nil
        }
        XCTAssertEqual(observations.count, 2); collected = true
    }

    func retainedMLXDownload(_ pinned: LocalModel) async throws -> (root: URL, directory: URL) {
        // Inspect only retained acquisition-test roots, never the production library.
        let candidates = try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("mlx-download-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for candidate in candidates {
            let file = candidate.appendingPathComponent("models.json")
            guard FileManager.default.fileExists(atPath: file.path), let library = try? ModelLibrary(file: file) else { continue }
            let models = await library.list()
            guard let retained = models.first(where: { $0.repository == pinned.repository && $0.revision == pinned.revision && $0.state == .ready }) else { continue }
            let directory = candidate.appendingPathComponent("Models/" + retained.id.uuidString)
            guard pinned.files.allSatisfy({ (try? ModelFileTransfer.byteCount($0.destination(in: directory))) == $0.bytes }) else { continue }
            return (candidate, directory)
        }
        throw ModelError.unsupported("The independently pinned retained MLX acquisition fixture is unavailable.")
    }
}
