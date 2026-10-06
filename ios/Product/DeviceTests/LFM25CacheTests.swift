import Foundation
import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    func testNativeLFM25CPUFreshWarmAndFrozenContextControls() async throws { try await exerciseLFM25ArithmeticControls(.llamaCPU) }
    func testNativeLFM25MetalFreshWarmAndFrozenContextControls() async throws { try await exerciseLFM25ArithmeticControls(.llamaMetal) }
    private func exerciseLFM25ArithmeticControls(_ backend: ModelBackend) async throws {
        var model = NativeLFMArtifact.metal(); model.backend = backend
        model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1
        model.settings.contextTokens = 2048; model.settings.outputTokens = 96; model.settings.thinking = false
        let retained = try await retainedLFMDownload(model)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lfm25-arithmetic-controls-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories:true)
        var hashes: [String:String] = [:]
        for file in model.files {
            let input = try file.destination(in:retained.directory), owned = try file.destination(in:root)
            try await Task.detached { try ModelFileTransfer.verify(input,file:file) }.value
            try FileManager.default.linkItem(at:input,to:owned)
            hashes[file.path] = try await Task.detached { try ModelFileTransfer.hash(owned) }.value
            XCTAssertEqual(hashes[file.path],file.sha256)
        }
        let runtime = NativeObservedRuntime(try RuntimeFactory.make(model))
        var probes: [[String:Any]] = [], complete = false
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            runtime.cancel(); UIApplication.shared.isIdleTimerDisabled = idle
            let value: [String:Any] = ["purpose":"native-lfm25-backend-cache-context-controls","completed":complete,"backend":backend.rawValue,
                "artifact":NativeAgentArtifact.evidence(model),"sourceOwnedRoot":retained.root.lastPathComponent,
                "sourceLibrarySHA256":try! ModelFileTransfer.hash(retained.root.appendingPathComponent("models.json")),
                "independentFullFileSHA256":hashes,"probes":probes,"runtimeTrace":runtime.snapshot(),"operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations":["Same independently pinned acquired GGUF and actual product adapters, with direct runtime calls on one iPhone. No new network transfer or controller/gesture/tool acceptance.",
                    "Full frozen history is captured from actual earlier controller input. Recomputed warm-prefix state does not recreate the original retained-cache or Stop execution.",
                    "The no-interrupted-turn case removes the frozen story user message and cancelled assistant C, not a new actual cancellation. No cause, repair, default recommendation, general quality, A2 replication, speed/energy/fit claim."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name="LFM2.5 \(backend.rawValue) arithmetic controls";attachment.lifetime = .keepAlways;add(attachment)
            if complete { try? FileManager.default.removeItem(at:root) }
        }
        try await runtime.load(model:model,directory:root)
        let frozen = try JSONDecoder().decode([[String:String]].self,from:Data(frozenLFMMessages.utf8))
        XCTAssertEqual(frozen.count,18);XCTAssertEqual(frozen.first?["content"],ChatController.systemPrompt)
        let standalone = [try XCTUnwrap(frozen.first),try XCTUnwrap(frozen.last)]
        let noInterruptedTurn = frozen.enumerated().filter { ![13,14].contains($0.offset) }.map(\.element)
        let cases: [(String,[[String:String]],[[String:String]]?)] = [
            ("standalone-fresh",standalone,nil),
            ("standalone-warmed-system",standalone,[try XCTUnwrap(frozen.first)]),
            ("frozen-full-fresh",frozen,nil),
            ("frozen-full-recomputed-warm-prefix",frozen,Array(frozen.dropLast())),
            ("frozen-without-interrupted-turn-fresh",noInterruptedTurn,nil)
        ]
        for (label,messages,warm) in cases {
            await runtime.reset()
            if let warm { try await runtime.warm(messages:warm,settings:model.settings) }
            var result: RuntimeReply?
            for try await event in runtime.stream(messages:messages,settings:model.settings,tools:[]) { if case .reply(let reply) = event { result = reply } }
            let reply = try XCTUnwrap(result)
            XCTAssertFalse(reply.cancelled);XCTAssertTrue(reply.toolCalls.isEmpty);XCTAssertEqual(reply.stopReason,.endOfTurn)
            if warm == nil { XCTAssertEqual(reply.cachedTokens,0) } else { XCTAssertGreaterThan(reply.cachedTokens,0) }
            let answer = reply.content.trimmingCharacters(in:.whitespacesAndNewlines), matches = answer == "4"
            probes.append(["label":label,"messages":messages,"warmMessages":warm as Any? ?? NSNull(),"answer":answer,"matchesExpected":matches,
                "cachedTokens":reply.cachedTokens,"generatedTokens":reply.generatedTokens,"cancelled":reply.cancelled,"stopReason":reply.stopReason.rawValue])
            XCTAssertTrue(matches,"\(backend.rawValue) \(label): expected 4, got \(answer)")
        }
        complete = probes.count == 5 && probes.allSatisfy { $0["matchesExpected"] as? Bool == true }
    }
    func retainedLFMDownload(_ pinned: LocalModel) async throws -> (root:URL,directory:URL) {
        // Read only acquisition-owned roots, never the user's production library.
        let candidates = try FileManager.default.contentsOfDirectory(at:FileManager.default.temporaryDirectory,includingPropertiesForKeys:nil)
            .filter { $0.lastPathComponent.hasPrefix("lfm25-download-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for root in candidates {
            let file = root.appendingPathComponent("models.json")
            guard FileManager.default.fileExists(atPath:file.path),let library = try? ModelLibrary(file:file) else { continue }
            let models = await library.list()
            guard let saved = models.first(where: { $0.repository == pinned.repository && $0.revision == pinned.revision && $0.entryFile == pinned.entryFile && $0.state == .ready }) else { continue }
            let directory = root.appendingPathComponent("Models/"+saved.id.uuidString)
            guard pinned.files.allSatisfy({ (try? ModelFileTransfer.byteCount($0.destination(in:directory))) == $0.bytes }) else { continue }
            return (root,directory)
        }
        throw ModelError.unsupported("The independently pinned retained LFM2.5 acquisition fixture is unavailable.")
    }
    private var frozenLFMMessages: String {
        #"""
        [
          {
            "content": "You are OpenWeights, a helpful assistant running on this device. Answer clearly and accurately.",
            "role": "system"
          },
          {
            "content": "Reply with exactly Cedar.",
            "role": "user"
          },
          {
            "content": "Cedar",
            "role": "assistant"
          },
          {
            "content": "Remember my destination is Kyoto and my budget is 450. Reply briefly.",
            "role": "user"
          },
          {
            "content": "Cedar, let's plan wisely!",
            "role": "assistant"
          },
          {
            "content": "What are my destination and budget? Reply with exactly Kyoto|450.",
            "role": "user"
          },
          {
            "content": "Kyoto|450",
            "role": "assistant"
          },
          {
            "content": "Correction: my destination is Osaka and my budget is 730. Replace the previous values. Reply briefly.",
            "role": "user"
          },
          {
            "content": "Cedar, your destination is Osaka with a budget of 730.",
            "role": "assistant"
          },
          {
            "content": "What are my current destination and budget? Reply with exactly Osaka|730.",
            "role": "user"
          },
          {
            "content": "Cedar, your current destination is Osaka with a budget of 730.",
            "role": "assistant"
          },
          {
            "content": "What are my current destination and budget? Reply with exactly Osaka|730.",
            "role": "user"
          },
          {
            "content": "Cedar, your current destination is Osaka and your budget is 730.",
            "role": "assistant"
          },
          {
            "content": "Write a long detailed travel story about my current destination.",
            "role": "user"
          },
          {
            "content": "C",
            "role": "assistant"
          },
          {
            "content": "What are my current destination and budget? Reply with exactly Osaka|730.",
            "role": "user"
          },
          {
            "content": "Cedar, your current destination is Osaka with a budget of 730. Osaka is a vibrant city known for its rich history, delicious food, and lively atmosphere. You have a budget of 730, which should cover your travel expenses, accommodations, meals, and activities. Enjoy your trip!",
            "role": "assistant"
          },
          {
            "content": "What is 2 + 2? Reply with only the number.",
            "role": "user"
          }
        ]
        """#
    }
}
