import XCTest
import UIKit
import MLX
import MLXLMCommon
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    func testNativeMLXOwnedLogitsIndependentFilters() throws {
        let logits: [Float] = [4,3,1,0]
        let input = MLXArray(logits).reshaped([1,4])
        var observations: [[String:Any]] = [], completed = false
        defer {
            let value: [String:Any] = ["purpose":"native-mlx-owned-logits-independent-top-k-min-p-controls", "completed":completed,
                "logits":logits, "observations":observations, "drawsPerConfiguration":128,
                "limitations":["Actual MLXLMCommon GenerateParameters samplers with owned logits, not model inference or a speed/quality benchmark.",
                    "Sampler private random states are time-seeded. Exact unfiltered counts are observations, not a reproducible-seed or distribution-estimation claim.",
                    "Top P stays 1. Top K and Min P are varied independently. Expected allowed sets derive from exp(logit - maximum logit)."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Owned MLX sampler logits"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let cases: [(String,Int,Float,Set<Int>,Bool)] = [
            ("unfiltered",0,0,[0,1,2,3],false), ("top-k-one",1,0,[0],false),
            ("min-p-half",0,0.5,[0],false), ("min-p-one-fifth",0,0.2,[0,1],false),
            ("min-p-one-tied-maxima",0,1,[0,1],true)]
        for (stage,topK,minP,allowed,tied) in cases {
            let actualInput = tied ? MLXArray([Float(4),4,1,0]).reshaped([1,4]) : input
            let sampler = GenerateParameters(temperature:1,topP:1,topK:topK,minP:minP).sampler()
            var counts = [Int](repeating:0,count:4)
            for _ in 0..<128 {
                let token = sampler.sample(logits:actualInput).item(Int.self)
                XCTAssertTrue(allowed.contains(token),"A token outside the independently derived filter set was sampled.")
                guard counts.indices.contains(token) else { throw ModelError.unsupported("Sampler produced an invalid owned token.") }
                counts[token] += 1
            }
            observations.append(["stage":stage, "temperature":1, "topP":1, "topK":topK, "minP":minP,
                "allowedTokenIDs":allowed.sorted(), "observedCounts":counts, "tiedMaximumInput":tied])
            if stage == "unfiltered" { XCTAssertGreaterThan(counts[1]+counts[2]+counts[3],0,"Unfiltered control did not witness any non-maximum token.") }
            if stage == "min-p-one-fifth" { XCTAssertGreaterThan(counts[1],0,"The allowed second token was not witnessed.") }
            if tied { XCTAssertGreaterThan(counts[0],0); XCTAssertGreaterThan(counts[1],0) }
        }
        completed = true
    }

    @MainActor func testNativeExplicitMLXAndGGUFMinPControls() async throws {
        let messages = [["role":"system","content":"Answer clearly and briefly."],
            ["role":"user","content":"Name a fruit. Reply with only one fruit name."]]
        let models = try HubClient.pinnedCatalogue()
        let gguf = try XCTUnwrap(models.first { $0.backend == .llamaMetal })
        let mlx = try XCTUnwrap(models.first { $0.backend == .mlx })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-sampling-" + UUID().uuidString)
        let libraryFile = root.appendingPathComponent("models.json")
        let library = try ModelLibrary(file:libraryFile)
        var observations: [[String:Any]] = [], completed = false
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle; try? FileManager.default.removeItem(at:root)
            let value: [String:Any] = ["purpose":"native-explicit-MLX-and-GGUF-independent-min-p-model-controls", "completed":completed,
                "messages":messages, "observations":observations, "artifacts":[NativeAgentArtifact.evidence(gguf),NativeAgentArtifact.evidence(mlx)],
                "operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations":["One pinned GGUF Q4_K_M artifact on CPU/Metal and one distinct pinned MLX 4-bit artifact. No cross-artifact quality or runtime ranking.",
                    "Greedy, Top K 1 and Min P 1 use reset caches, fixed prompts and independent disabled filters. Exact-text equality is not asserted because tied maxima allow different valid choices. Separate owned/logit controls score filter validity.",
                    "Twelve unfiltered requests per backend are a variation witness, not a seeded distribution estimate. Actual internal sampler RNG states remain runtime defaults.",
                    "Preferences are persisted/reopened in an owned ModelLibrary and passed to real adapters using verified cached weights. No settings UI, download or model-switch gesture claim."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Explicit native model sampler controls"; attachment.lifetime = .keepAlways; add(attachment)
        }
        for backend in [ModelBackend.llamaCPU,.llamaMetal,.mlx] {
            var model = backend == .mlx ? mlx : gguf; model.id = UUID(); model.backend = backend
            model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1
            model.settings.topK = 0; model.settings.minP = 0; model.settings.thinking = false
            model.settings.outputTokens = 16
            let directory = cachedDirectory(artifact:backend == .mlx ? "mlx" : "gguf",revision:try XCTUnwrap(model.revision))
            for file in model.files { try ModelDownloads.verify(file.destination(in:directory),file:file) }
            try await library.save(model)
            let runtime = try RuntimeFactory.make(model); try await runtime.load(model:model,directory:directory)
            @MainActor func reply(_ settings: ModelSettings, warm: Bool = false) async throws -> RuntimeReply {
                await runtime.reset()
                var profile = model; profile.settings = settings; try await library.saveSettings(profile)
                let reopened = try ModelLibrary(file:libraryFile), saved = await reopened.list()
                let persisted = try XCTUnwrap(saved.first { $0.id == model.id }?.settings)
                XCTAssertEqual(persisted,settings)
                let count = try await runtime.promptSize(messages:messages,settings:persisted,tools:[])
                XCTAssertTrue(count.exact); XCTAssertLessThanOrEqual(count.tokens+persisted.outputTokens,persisted.contextTokens)
                if warm { try await runtime.warm(messages:[messages[0]],settings:persisted) }
                var result: RuntimeReply?
                for try await event in runtime.stream(messages:messages,settings:persisted) { if case .reply(let value) = event { result = value } }
                let value = try XCTUnwrap(result); XCTAssertFalse(value.cancelled); XCTAssertFalse(value.content.isEmpty)
                if warm { XCTAssertGreaterThan(value.cachedTokens,0) } else { XCTAssertEqual(value.cachedTokens,0) }
                return value
            }
            let greedy = try await reply(model.settings)
            var topK = model.settings; topK.temperature = 1; topK.topK = 1
            let topKReply = try await reply(topK)
            var minP = model.settings; minP.temperature = 1; minP.minP = 1
            let minPReply = try await reply(minP)
            var unfiltered = model.settings; unfiltered.temperature = 1
            var samples: [String] = []
            for _ in 0..<12 { samples.append(try await reply(unfiltered).content) }
            XCTAssertTrue(samples.contains { $0 != greedy.content },"Unfiltered model control did not witness a reply different from greedy.")
            observations.append(["backend":backend.rawValue, "greedy":greedy.content, "topKOne":topKReply.content,
                "minPOne":minPReply.content, "unfiltered":samples, "temperatureForFiltersAndUnfiltered":1,
                "topP":1, "repeatPenalty":1, "outputLimit":16, "otherFiltersDisabled":true])
            if backend == .mlx {
                let warmed = try await reply(minP,warm:true)
                observations.append(["backend":backend.rawValue, "stage":"explicit-min-p-one-warmed", "answer":warmed.content,
                    "cachedTokens":warmed.cachedTokens, "topK":0, "minP":1, "temperature":1])
            }
        }
        completed = true
    }
}
