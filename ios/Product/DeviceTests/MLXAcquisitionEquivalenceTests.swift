import Foundation
import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    func testNativeMLXAcquisitionMetadataAndSettingsEquivalenceDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-acquisition-equivalence-" + UUID().uuidString)
        let suite = root.lastPathComponent, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var chat: ChatController?, downloads: ModelDownloads?
        var observations: [[String: Any]] = [], completed = false
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            chat?.cancel(); downloads?.cancelAllTransfers()
            UIApplication.shared.isIdleTimerDisabled = idle; defaults.removePersistentDomain(forName: suite)
            let value: [String: Any] = ["purpose": "native-mlx-acquisition-metadata-settings-equivalence-diagnostics", "completed": completed,
                "observations": observations,
                "limitations": ["Diagnostic controls use independently verified cached pinned components through test-owned hard links. No fresh full download or external provider claim.",
                    "Actual product controller, warm/load/stream, store and reopen calls execute unchanged. Diagnostic pass means traces were collected, not that model answers are correct.",
                    "Three ordered controls on one phone/artifact do not establish general quality, precision/kernel cause, measured fit, performance or energy."]]
            let attachment = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "MLX acquisition equivalence diagnostics"; attachment.lifetime = .keepAlways; add(attachment)
            if completed { try? FileManager.default.removeItem(at: root) }
        }
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .mlx })
        let cache = cachedDirectory(artifact: "mlx", revision: try XCTUnwrap(pinned.revision))
        let details = try await HubClient.details(try XCTUnwrap(pinned.repository), revision: try XCTUnwrap(pinned.revision), transport: HubAPITransport(useStoredCredential: false))
        let selected = try await HubClient.mlx(details, useStoredCredential: false)
        let index = try XCTUnwrap(selected.files.first { $0.path == "model.safetensors.index.json" })
        let indexRequest = LocalModel(name: index.path, backend: .mlx, entryFile: index.path, files: [index], repository: selected.repository, revision: selected.revision)
        let indexData = try await HubGGUFRangeSource(model: indexRequest, useStoredCredential: false).read(offset: 0, length: Int(try XCTUnwrap(index.bytes)))
        let independentIndex = ModelFile(path: index.path, bytes: 49731, sha256: "7b294141456f6904936db03c00bca50fb5f6198f652fe8483f9cd2a1018accfb")
        try ModelFileTransfer.verify(indexData, file: independentIndex)
        XCTAssertEqual(Set(selected.files.map(\.path)), Set(pinned.files.map(\.path) + [index.path]))
        for component in pinned.files { try ModelDownloads.verify(component.destination(in: cache), file: component) }
        for stage in ["catalogue-eight-files-import-settings", "catalogue-eight-files-download-settings", "selected-nine-files-download-settings"] {
            var model = stage.hasPrefix("selected") ? selected : pinned
            model.id = UUID(); model.state = .ready
            model.settings.temperature = 0; model.settings.repeatPenalty = 1
            model.settings.topP = stage.hasSuffix("import-settings") ? 0.95 : 1
            model.settings.outputTokens = stage.hasSuffix("import-settings") ? 32 : 96
            let stageRoot = root.appendingPathComponent(stage), library = try ModelLibrary(file: stageRoot.appendingPathComponent("models.json"))
            let manager = ModelDownloads(root: stageRoot.appendingPathComponent("Models"), library: library, sessionIdentifier: suite + "." + stage)
            downloads = manager
            var hashes: [String: String] = [:]
            for component in model.files {
                let owned = try component.destination(in: manager.directory(model))
                try FileManager.default.createDirectory(at: owned.deletingLastPathComponent(), withIntermediateDirectories: true)
                if component.path == index.path { try indexData.write(to: owned) }
                else { try FileManager.default.linkItem(at: component.destination(in: cache), to: owned) }
                try ModelDownloads.verify(owned, file: component)
                hashes[component.path] = try await Task.detached { try ModelFileTransfer.hash(owned) }.value
            }
            try await library.save(model); await manager.restore()
            weak var observed: NativeObservedRuntime?
            let factory: (LocalModel) throws -> any ChatRuntime = { model in
                let value = NativeObservedRuntime(try RuntimeFactory.make(model)); observed = value; return value
            }
            let store = try ConversationStore(file: stageRoot.appendingPathComponent("conversations.json"))
            chat = ChatController(store: store, downloads: manager, defaults: defaults, runtimeFactory: factory)
            await chat?.load(model); XCTAssertNil(chat?.error)
            chat?.draft = "Reply with exactly Cedar."; await chat?.send()
            try await waitUntil(seconds: 90) { chat?.busy == false }; XCTAssertNil(chat?.error)
            let first = try XCTUnwrap(chat?.current?.messages.last?.content)
            let saved = try XCTUnwrap(chat?.current), stored = try await store.conversation(saved.id)
            var expected = saved; expected.updatedAt = stored.updatedAt
            XCTAssertEqual(stored, expected); XCTAssertGreaterThanOrEqual(stored.updatedAt, saved.updatedAt)
            await chat?.open(stored); XCTAssertNil(chat?.error); XCTAssertEqual(chat?.current, stored)
            chat?.draft = "What is 2 + 2? Reply with only the number."; await chat?.send()
            try await waitUntil(seconds: 90) { chat?.busy == false }; XCTAssertNil(chat?.error)
            let second = try XCTUnwrap(chat?.current?.messages.last?.content), trace = try XCTUnwrap(observed).snapshot()
            observations.append(["stage": stage, "artifact": NativeAgentArtifact.evidence(model), "independentFullFileSHA256": hashes,
                "firstAnswer": first, "reopenedAnswer": second,
                "matchesCedarAcceptance": ["Cedar", "Cedar."].contains(first.trimmingCharacters(in: .whitespacesAndNewlines)),
                "matchesArithmeticAcceptance": second.trimmingCharacters(in: .whitespacesAndNewlines) == "4", "runtimeTrace": trace])
            XCTAssertEqual((trace["streams"] as? [[String: Any]])?.count, 2)
            XCTAssertEqual(trace["omittedStreams"] as? Int, 0)
            chat?.cancel(); chat = nil
            try await waitUntil(seconds: 3) { observed == nil }; XCTAssertNil(observed)
            manager.cancelAllTransfers(); downloads = nil
        }
        XCTAssertEqual(observations.count, 3); completed = true
    }
}
