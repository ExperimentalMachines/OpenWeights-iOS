import XCTest
import UIKit
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon
import OpenWeightsCore
@testable import OpenWeights

private final class SamplingLogitTrace: LogitSampler {
    let underlying: any LogitSampler
    let tokenizer: any MLXLMCommon.Tokenizer
    var records: [[String:Any]] = []
    var checkedSampleCount = 0
    init(_ underlying: any LogitSampler, tokenizer: any MLXLMCommon.Tokenizer) { self.underlying = underlying; self.tokenizer = tokenizer }
    func sample(logits: MLXArray) -> MLXArray {
        let selected = underlying.sample(logits:logits)
        let chosen = selected.item(Int.self)
        // Min P 1 allows every maximum, including ties. Score token eligibility
        // against raw logits rather than imposing argmax's tie-breaking text.
        let raw = logits.reshaped([-1])
        XCTAssertEqual(raw[chosen].item(Float.self),raw.max().item(Float.self),"The selected token was below the maximum in a greedy/Min P 1 control.")
        checkedSampleCount += 1
        if records.count < 8 {
            let flat = logits.reshaped([-1])
            let ordered = argSort(-flat)[0..<8].asArray(Int32.self)
            let normalized = logSoftmax(flat.dtype == .bfloat16 ? flat.asType(.float32) : flat)
            let maxLogit = flat.max().item(Float.self), maxLogprob = normalized.max().item(Float.self)
            let rawTies = sum((flat .== MLXArray(maxLogit)).asType(.int32)).item(Int.self)
            let minPTies = sum((normalized .>= MLXArray(maxLogprob)).asType(.int32)).item(Int.self)
            let candidates: [[String:Any]] = ordered.map { raw in
                let id = Int(raw)
                return ["id":id, "text":tokenizer.decode(tokenIds:[id]), "logit":flat[id].item(Float.self),
                    "logprob":normalized[id].item(Float.self)]
            }
            records.append(["step":records.count, "selectedID":chosen, "selectedText":tokenizer.decode(tokenIds:[chosen]),
                "dtype":String(describing:flat.dtype), "maximumLogitCount":rawTies, "minPOneEligibleCount":minPTies,
                "topCandidates":candidates])
        }
        return selected
    }
}

extension ProductTests {
    @MainActor func testNativeMLXFrozenFruitPromptPartitionAndSamplerDiagnostics() async throws {
        var model = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .mlx })
        model.settings.temperature = 0; model.settings.topP = 1; model.settings.topK = 0; model.settings.minP = 0
        model.settings.repeatPenalty = 1; model.settings.thinking = false; model.settings.outputTokens = 16
        let directory = cachedDirectory(artifact:"mlx",revision:try XCTUnwrap(model.revision))
        for file in model.files { try ModelDownloads.verify(file.destination(in:directory),file:file) }
        let messages: [[String:any Sendable]] = [["role":"system","content":"Answer clearly and briefly."],
            ["role":"user","content":"Name a fruit. Reply with only one fruit name."]]
        var observations: [[String:Any]] = [], completed = false
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle
            let value: [String:Any] = ["purpose":"native-frozen-MLX-fruit-prompt-prefill-partition-and-logit-diagnostics", "completed":completed,
                "artifact":NativeAgentArtifact.evidence(model), "observations":observations,
                "limitations":["Test-only public MLX model/sampler APIs replay the exact retained fruit prompt. Production code and the failing original acceptance are unchanged.",
                    "First eight sampled positions retain eight top candidates and maximum tie counts. This is not a full vocabulary dump, quality benchmark or general numerical-error bound.",
                    "The warm partition reproduces the product's stable-prefix calculation and direct model forward. Direct API observations do not by themselves establish production cache corruption or its absence."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "MLX prefill and sampler diagnostics"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let container = try await LLMModelFactory.shared.loadContainer(from:directory,using:ProductTokenizerLoader())
        let values = try await container.perform { context -> [[String:Any]] in
            let template: [String:any Sendable] = ["enable_thinking":false]
            let full = try context.tokenizer.applyChatTemplate(messages:messages,tools:nil,additionalContext:template)
            let head = try context.tokenizer.applyChatTemplate(messages:[messages[0]],tools:nil,additionalContext:template)
            let probed = try context.tokenizer.applyChatTemplate(messages:[messages[0],["role":"user","content":"OpenWeights warm prefix probe"]],tools:nil,additionalContext:template)
            var shared = 0
            while shared < min(head.count,probed.count), head[shared] == probed[shared] { shared += 1 }
            XCTAssertGreaterThan(shared,0); XCTAssertEqual(Array(full.prefix(shared)),Array(head.prefix(shared)))
            var results: [[String:Any]] = []
            for stage in ["fresh-greedy","warmed-greedy","fresh-min-p-one","warmed-min-p-one"] {
                let warmed = stage.hasPrefix("warmed"), minP = stage.contains("min-p")
                let parameters = GenerateParameters(maxTokens:16,temperature:minP ? 1 : 0,topP:1,topK:0,minP:minP ? 1 : 0,repetitionPenalty:1,prefillStepSize:512)
                let cache = context.model.newCache(parameters:parameters)
                if warmed {
                    let input = LMInput.Text(tokens:MLXArray(Array(head.prefix(shared))))
                    let result = context.model(input[text:.newAxis],cache:cache,state:nil)
                    eval(result.logits,cache.flatMap { $0.state }); XCTAssertNil(result.state)
                }
                let offset = cache.first?.offset ?? 0
                XCTAssertEqual(offset,warmed ? shared : 0)
                let input = LMInput(tokens:MLXArray(Array(full.dropFirst(offset))))
                let sampler = SamplingLogitTrace(parameters.sampler(),tokenizer:context.tokenizer)
                let iterator = try TokenIterator(input:input,model:context.model,cache:cache,processor:parameters.processor(),sampler:sampler,prefillStepSize:512,maxTokens:16)
                var tokens: [Int] = []
                let info = MLXLMCommon.generate(input:input,context:context,iterator:iterator) { token in tokens.append(token); return .more }
                let answer = context.tokenizer.decode(tokenIds:tokens)
                results.append(["stage":stage, "fullPromptTokenIDs":full, "warmedPrefixTokenIDs":warmed ? Array(head.prefix(shared)) : [],
                    "initialCacheOffset":offset, "answer":answer, "generatedTokenIDs":tokens,
                    "generationTokenCount":info.generationTokenCount, "sampledLogits":sampler.records, "maximumEligibilityCheckedSamples":sampler.checkedSampleCount])
                XCTAssertFalse(answer.isEmpty)
            }
            return results
        }
        observations = values; completed = true
    }
}
