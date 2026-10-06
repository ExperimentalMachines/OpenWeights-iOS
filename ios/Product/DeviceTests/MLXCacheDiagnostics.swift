import Foundation
import XCTest
import UIKit
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    func testNativeMLXIdenticalTokenCacheLogits() async throws {
        var model = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .mlx })
        model.settings.temperature = 0; model.settings.repeatPenalty = 1
        model.settings.contextTokens = 4096; model.settings.outputTokens = 128; model.settings.thinking = false
        let directory = cachedDirectory(artifact: "mlx", revision: try XCTUnwrap(model.revision))
        for file in model.files { try ModelDownloads.verify(file.destination(in: directory), file: file) }
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        var observations: [[String: Any]] = [], completed = false
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle
            let data: [String: Any] = ["purpose": "native-mlx-identical-token-cache-logits", "completed": completed,
                "observations": observations, "artifact": NativeAgentArtifact.evidence(model),
                "limitations": ["Direct pinned MLX model calls isolate prefill partitioning with identical prompt IDs and teacher-forced continuation IDs. They do not change the product or prove general model quality.", "All compared continuation inputs follow the fresh path so logit differences are measured at the same text, rather than after divergent generated text.", "The Float32 control casts floating parameters only and preserves packed integer weights. It is a test-only precision ablation, not a new artifact or production runtime policy. Teacher forcing deliberately continues after EOS to compare a fixed twelve positions."]]
            let attachment = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "native-mlx-cache-logits.json"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let container = try await LLMModelFactory.shared.loadContainer(from: directory, using: ProductTokenizerLoader())
        let systemPrompt = ChatController.systemPrompt
        for precision in ["artifact", "float32-floating-parameters"] {
        if precision != "artifact" {
            await container.perform { context in
                context.model.update(parameters: context.model.parameters().mapValues { $0.dtype.isFloatingPoint ? $0.asType(.float32) : $0 })
                eval(context.model)
            }
        }
        for prompt in ["Reply with exactly Cedar.", "What is 2 + 2? Reply with only the number."] {
            let encoded = try await container.perform { context -> Data in
                let head: [[String: any Sendable]] = [["role": "system", "content": systemPrompt]]
                let messages = head + [["role": "user", "content": prompt]]
                let extra: [String: any Sendable] = ["enable_thinking": false]
                let tokens = try context.tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: extra)
                let full = try context.tokenizer.applyChatTemplate(messages: head, tools: nil, additionalContext: extra)
                let probe = try context.tokenizer.applyChatTemplate(messages: head + [["role": "user", "content": "OpenWeights warm prefix probe"]], tools: nil, additionalContext: extra)
                var shared = 0
                while shared < min(full.count, probe.count), full[shared] == probe[shared] { shared += 1 }
                guard shared > 0, shared < tokens.count, Array(full.prefix(shared)) == Array(tokens.prefix(shared)) else { throw ModelError.unsupported("Warm prefix differs from actual prompt IDs.") }
                let parameters = GenerateParameters(maxTokens: 128, temperature: 0, repetitionPenalty: 1, prefillStepSize: 512)
                let fresh = context.model.newCache(parameters: parameters)
                let warmed = context.model.newCache(parameters: parameters)
                let serial = context.model.newCache(parameters: parameters)
                var logitsDtype = ""
                func feed(_ ids: [Int], _ cache: [KVCache]) throws -> [Float] {
                    let output = context.model(LMInput.Text(tokens: MLXArray(ids))[text: .newAxis], cache: cache, state: nil)
                    eval(output.logits, cache.flatMap { $0.state })
                    guard output.state == nil else { throw ModelError.unsupported("Diagnostic requires cache-only decoder state.") }
                    logitsDtype = String(describing: output.logits.dtype)
                    let values = output.logits[0, -1, 0...].asArray(Float.self)
                    guard !values.isEmpty, values.allSatisfy(\.isFinite) else { throw ModelError.unsupported("Nonfinite logits.") }
                    return values
                }
                _ = try feed(Array(tokens.prefix(shared)), warmed)
                for id in tokens.prefix(shared) { _ = try feed([id], serial) }
                let prefixOffsets = warmed.map(\.offset)
                var values = [try feed(tokens, fresh), try feed(Array(tokens.dropFirst(shared)), warmed), try feed(Array(tokens.dropFirst(shared)), serial)]
                var steps: [[String: Any]] = [], forced: [Int] = []
                func ranking(_ values: [Float]) -> [[String: Any]] {
                    values.indices.sorted { values[$0] > values[$1] }.prefix(8).map { id in
                        ["id": id, "score": values[id], "text": context.tokenizer.decode(tokenIds: [id])]
                    }
                }
                for step in 0..<12 {
                    let reference = values[0]
                    let selected = reference.indices.max { reference[$0] < reference[$1] }!
                    forced.append(selected)
                    var comparisons: [[String: Any]] = []
                    for path in 1..<values.count {
                        let differences = zip(reference, values[path]).map { abs(Double($0) - Double($1)) }
                        let chosen = values[path].indices.max { values[path][$0] < values[path][$1] }!
                        comparisons.append(["path": path == 1 ? "batched-warm-prefix" : "one-token-warm-prefix",
                            "maximumAbsoluteDifference": differences.max()!,
                            "rmsDifference": sqrt(differences.reduce(0) { $0 + $1 * $1 } / Double(differences.count)),
                            "argmaxMatchesFresh": chosen == selected, "ranking": ranking(values[path])])
                    }
                    steps.append(["step": step, "freshRanking": ranking(reference), "forcedNextID": selected,
                        "comparisons": comparisons, "offsets": [fresh.map(\.offset), warmed.map(\.offset), serial.map(\.offset)]])
                    if step < 11 { values = try [fresh, warmed, serial].map { try feed([selected], $0) } }
                }
                let dtypeCounts = Dictionary(grouping: context.model.parameters().flattened(), by: { String(describing: $0.1.dtype) }).mapValues { $0.count }
                let result: [String: Any] = ["precision": precision, "logitsDtype": logitsDtype, "parameterDtypeCounts": dtypeCounts,
                    "prompt": prompt, "promptIDs": tokens, "renderedPrompt": context.tokenizer.decode(tokenIds: tokens),
                    "sharedPrefixIDs": Array(tokens.prefix(shared)), "sharedPrefixCount": shared,
                    "prefixCacheOffsets": prefixOffsets, "teacherForcedIDs": forced,
                    "teacherForcedText": context.tokenizer.decode(tokenIds: forced), "steps": steps]
                return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            }
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            observations.append(result)
            XCTAssertEqual(result["sharedPrefixCount"] as? Int, 24)
            XCTAssertEqual((result["steps"] as? [[String: Any]])?.count, 12)
        }
        }
        completed = true
    }
}
