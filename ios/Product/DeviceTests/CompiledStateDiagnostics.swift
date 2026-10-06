import Foundation
import CryptoKit
import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    func testNativeCompiledFreshWarmResetArithmeticDiagnosis() async throws {
        let model = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .xnnpack })
        let directory = cachedDirectory(artifact: "executorch", revision: try XCTUnwrap(model.revision))
        for file in model.files { try ModelDownloads.verify(file.destination(in: directory), file: file) }
        var settings = model.settings
        settings.temperature = 0; settings.repeatPenalty = 1; settings.outputTokens = 96; settings.thinking = false
        let head = [["role": "system", "content": ChatController.systemPrompt]]
        let messages = head + [["role": "user", "content": "What is 2 + 2? Reply with only the number."]]
        let prompt = try CompiledQwen3Prompt.render(messages, thinking: false)
        let warm = try CompiledQwen3Prompt.render(head, thinking: false)
        let future = try CompiledQwen3Prompt.render(head + [["role": "user", "content": "OpenWeights warm prefix probe"]], thinking: false)
        let tools = [AgentToolDefinition(name: "read_memory", description: "Read the user's saved project fact.", parametersJSON: "{\"type\":\"object\",\"properties\":{}}")]
        let toolPrompt = try CompiledQwen3Prompt.render(head + [["role": "user", "content": "Call read_memory with no arguments."]], tools: tools, thinking: false)
        var observations: [[String: Any]] = [], completed = false
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle
            let value: [String: Any] = ["purpose": "native-compiled-fresh-warm-reset-arithmetic-diagnosis", "completed": completed,
                "artifact": NativeAgentArtifact.evidence(model), "expectedArithmeticAnswer": "4", "renderedPrompt": prompt,
                "renderedPromptSHA256": SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined(),
                "settings": ["temperature": settings.temperature, "outputTokens": settings.outputTokens, "contextTokens": settings.contextTokens, "thinking": settings.thinking],
                "observations": observations,
                "limitations": ["Diagnostic acceptance checks observation completeness, exact content forwarding, reset/warm counters and native termination. It does not accept incorrect arithmetic as product success. Original strict exact-4 failures remain retained.",
                    "Two independently loaded runner trials within the same app process use one pinned artifact and one short arithmetic prompt. No logits, new OS process, general cache correctness, runtime-only comparison, performance or energy claim."]]
            let a = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            a.name = "compiled-fresh-warm-reset-diagnosis.json"; a.lifetime = .keepAlways; add(a)
        }
        let tokenizer = try OWExecuTorchTokenizer(path: directory.appendingPathComponent("tokenizer.json").path)
        let promptCount = try tokenizer.countPrompt(prompt).intValue
        XCTAssertEqual(promptCount, 49)
        for trial in 0..<2 {
            let runner = try OWExecuTorchRunner(modelPath: try ModelFile(path: model.entryFile).destination(in: directory).path,
                tokenizerPath: directory.appendingPathComponent("tokenizer.json").path)
            try runner.load()
            func generate(_ input: String, stage: String, cap: Int = 96) throws -> [String: Any] {
                runner.beginOperation()
                var pieces = ""
                let result = try runner.generatePrompt(input, outputLimit: cap, temperature: 0, contextLimit: 2048) { pieces += $0 }
                let content = try XCTUnwrap(result["content"] as? String)
                XCTAssertEqual(content, pieces)
                observations.append(["trial": trial, "stage": stage, "path": "actual-native-runner", "inputIsExactArithmeticPrompt": input == prompt,
                    "matchesExpectedArithmetic": input == prompt && content == "4", "result": result])
                return result
            }
            func assertArithmeticState(_ result: [String: Any], cached: Int) throws {
                XCTAssertEqual((result["promptTokens"] as? NSNumber)?.intValue, promptCount)
                XCTAssertEqual((result["cachedTokens"] as? NSNumber)?.intValue, cached)
                XCTAssertEqual((result["stopReason"] as? NSNumber)?.intValue, 0)
                XCTAssertEqual((result["cancelled"] as? NSNumber)?.boolValue, false)
                let ids = try XCTUnwrap(result["sampledTokenIDs"] as? [NSNumber])
                XCTAssertEqual(ids.last?.intValue, 151645)
            }
            let fresh = try generate(prompt, stage: "newly-loaded-no-prior-prefill-or-generation")
            try assertArithmeticState(fresh, cached: 0)
            runner.reset(); runner.beginOperation()
            let warmed = try runner.warmPrompt(warm, futurePrompt: future, contextLimit: 2048).intValue
            XCTAssertEqual(warmed, 24)
            observations.append(["trial": trial, "stage": "warm-system-prefix-after-reset", "path": "actual-native-runner", "warmTokens": warmed])
            let retained = try generate(prompt, stage: "after-warmed-system-prefix")
            try assertArithmeticState(retained, cached: warmed)
            runner.reset()
            let reset = try generate(prompt, stage: "after-explicit-reset")
            try assertArithmeticState(reset, cached: 0)
            _ = try generate(toolPrompt, stage: "different-tool-prompt-before-arithmetic")
            let capped = try generate(toolPrompt, stage: "capped-tool-prompt-before-arithmetic", cap: 1)
            XCTAssertEqual((capped["stopReason"] as? NSNumber)?.intValue, 1)
            let mismatch = try generate(prompt, stage: "arithmetic-after-tool-prefix-mismatch")
            try assertArithmeticState(mismatch, cached: 0)
            runner.reset()
            let final = try generate(prompt, stage: "explicit-reset-after-tool-generation")
            try assertArithmeticState(final, cached: 0)

            // A separate product adapter checks that forwarding does not lose or
            // alter the direct native answer. It has no earlier conversation.
            let product = NativeObservedRuntime(ProductExecuTorchRuntime())
            try await product.load(model: model, directory: directory)
            var reply: RuntimeReply?
            for try await event in product.stream(messages: messages, settings: settings, tools: []) {
                if case .reply(let value) = event { reply = value }
            }
            let value = try XCTUnwrap(reply)
            XCTAssertEqual(value.cachedTokens, 0); XCTAssertEqual(value.stopReason, .endOfTurn); XCTAssertFalse(value.cancelled)
            XCTAssertEqual(value.content, fresh["content"] as? String)
            XCTAssertTrue(value.toolCalls.isEmpty)
            observations.append(["trial": trial, "stage": "separately-loaded-product-adapter-without-prior-tools", "path": "actual-product-adapter",
                "matchesExpectedArithmetic": value.content == "4", "runtimeTrace": product.snapshot()])
            product.cancel()
        }
        XCTAssertEqual(observations.count, 18)
        completed = observations.count == 18
    }
}
