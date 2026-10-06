import XCTest
import UIKit
import SwiftUI
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    @MainActor func testNativeThroughputPredictionAcrossGGUFWeights() async throws {
        let small = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let large = try NativeAgentArtifact.selected()
        XCTAssertNotEqual(small.files.first?.sha256,large.files.first?.sha256)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-speed-estimates-" + UUID().uuidString)
        let ledger = try UsageStore(file:root.appendingPathComponent("usage.json"))
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        var observations: [[String:Any]] = [], completed = false
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle; try? FileManager.default.removeItem(at:root)
            let payload: [String:Any] = ["purpose":"native-GGUF-weight-scaled-throughput-estimates","completed":completed,
                "observations":observations,"operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations":["Four fresh greedy requests across two distinct pinned Qwen3 GGUF artifacts and two backends. One request per artifact/backend, not a replicated speed benchmark or a validated prediction-accuracy range.",
                    "The source measurement predicts the other weight size using inverse bytes. Actual target rates and relative errors are retained without an accuracy acceptance threshold.",
                    "No controlled thermal ordering, energy measurement, memory-fit guarantee, model-quality ranking or runtime-default change."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Measured and predicted GGUF rates"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let messages = [["role":"system","content":"Answer directly."],
                        ["role":"user","content":"List the integers from 1 to 100, separated by commas."]]
        for backend in [ModelBackend.llamaCPU,.llamaMetal] {
            var installed: [LocalModel] = [], measured: [UsageRecord] = []
            for original in [small,large] {
                var model = original; model.backend = backend; model.state = .ready
                model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1
                model.settings.thinking = false; model.settings.outputTokens = 48
                let directory = cachedDirectory(artifact:"gguf",revision:try XCTUnwrap(model.revision))
                for file in model.files { try ModelDownloads.verify(file.destination(in:directory),file:file) }
                let runtime = try RuntimeFactory.make(model); try await runtime.load(model:model,directory:directory)
                await runtime.reset(); var result: RuntimeReply?
                for try await event in runtime.stream(messages:messages,settings:model.settings) { if case .reply(let reply) = event { result = reply } }
                let reply = try XCTUnwrap(result), usage = try XCTUnwrap(reply.usage), weights = try XCTUnwrap(UsageWeights(model:model))
                XCTAssertFalse(reply.cancelled); XCTAssertFalse(reply.content.isEmpty); XCTAssertEqual(usage.cachedTokens,0)
                XCTAssertEqual(usage.prefillIncludesCompute,true)
                XCTAssertGreaterThan(try XCTUnwrap(usage.decodeTokens),0); XCTAssertGreaterThan(try XCTUnwrap(usage.decodeMilliseconds),0)
                let record = UsageRecord(modelID:model.id,modelName:model.name,backend:backend,measurements:usage,weights:weights)
                try await ledger.record(record); installed.append(model); measured.append(record)
                runtime.cancel(); await runtime.reset()
            }
            let source = ThroughputEstimates(records:[measured[0]],installed:installed,backend:backend)
            let target = ThroughputEstimates(records:[measured[1]],installed:installed,backend:backend)
            let decode = try XCTUnwrap(source.decode), prefill = try XCTUnwrap(source.prefill)
            let actualDecode = try XCTUnwrap(target.decode), actualPrefill = try XCTUnwrap(target.prefill)
            let predictedDecode = try XCTUnwrap(decode.predict(weightBytes:actualDecode.weights.bytes,backend:backend))
            let predictedPrefill = try XCTUnwrap(prefill.predict(weightBytes:actualPrefill.weights.bytes,backend:backend))
            XCTAssertEqual(predictedDecode,decode.measuredTokensPerSecond*(Double(decode.weights.bytes)/Double(actualDecode.weights.bytes)))
            XCTAssertNil(decode.predict(weightBytes:actualDecode.weights.bytes,backend:backend == .llamaCPU ? .llamaMetal : .llamaCPU))
            observations.append(["backend":backend.rawValue,"sourceArtifact":NativeAgentArtifact.evidence(installed[0]),
                "targetArtifact":NativeAgentArtifact.evidence(installed[1]),"sourceWeightBytes":decode.weights.bytes,"targetWeightBytes":actualDecode.weights.bytes,
                "sourceDecodeTokens":decode.tokens,"sourceDecodeMilliseconds":decode.milliseconds,"sourceDecodeTokensPerSecond":decode.measuredTokensPerSecond,
                "sourcePrefillTokens":prefill.tokens,"sourcePrefillMilliseconds":prefill.milliseconds,"sourcePrefillTokensPerSecond":prefill.measuredTokensPerSecond,
                "targetDecodeTokens":actualDecode.tokens,"targetDecodeMilliseconds":actualDecode.milliseconds,"targetDecodeTokensPerSecond":actualDecode.measuredTokensPerSecond,
                "targetPrefillTokens":actualPrefill.tokens,"targetPrefillMilliseconds":actualPrefill.milliseconds,"targetPrefillTokensPerSecond":actualPrefill.measuredTokensPerSecond,
                "predictedTargetDecodeTokensPerSecond":predictedDecode,"predictedTargetPrefillTokensPerSecond":predictedPrefill,
                "decodeRelativeError":(predictedDecode/actualDecode.measuredTokensPerSecond)-1,
                "prefillRelativeError":(predictedPrefill/actualPrefill.measuredTokensPerSecond)-1])
            if backend == .llamaCPU {
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
                defer { window.isHidden = true; previous?.makeKeyAndVisible() }
                for style in [UIUserInterfaceStyle.light,.dark] {
                    window.overrideUserInterfaceStyle = style
                    window.rootViewController = UIHostingController(rootView: NavigationStack {
                        List { Section(installed[1].name) {
                            ThroughputEstimateView(estimates:source,weightBytes:actualDecode.weights.bytes,backend:backend)
                        } }.scrollContentBackground(.hidden).background(OWTheme.canvas).navigationTitle("Speed estimate")
                    }.font(OWTheme.interface()).tint(OWTheme.text).foregroundStyle(OWTheme.text)
                        .preferredColorScheme(style == .light ? .light : .dark))
                    window.makeKeyAndVisible(); try await Task.sleep(nanoseconds:1_000_000_000)
                    let image = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
                    let attachment = XCTAttachment(image:image); attachment.name = "GGUF speed estimate " + (style == .light ? "light" : "dark")
                    attachment.lifetime = .keepAlways; add(attachment)
                }
            }
        }
        let reopen = try UsageStore(file:root.appendingPathComponent("usage.json")), rows = await ledger.list(), durable = await reopen.list()
        XCTAssertEqual(durable,rows); XCTAssertEqual(rows.count,4); completed = observations.count == 2 && durable == rows
    }
}
