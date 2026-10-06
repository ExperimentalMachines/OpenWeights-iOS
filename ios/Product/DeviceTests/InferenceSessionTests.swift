import Foundation
import XCTest
import UIKit
import OpenWeightsCore
import OWInferenceProbe
@testable import OpenWeights

extension ProductTests {
    private func verifiedMLXDelegateDirectory() async throws -> URL {
        let directory = cachedDirectory(artifact:"executorch-mlx",revision:"c1899de289a04d12100db370d81485cdf75e47ca")
        let files = [
            ModelFile(path:"model.pte",bytes:646_789_248,sha256:"9035e10cd708d03c5a3788aa2893f7ccabfa34302eae44c9be1bfe80c7dc5737"),
            ModelFile(path:"tokenizer.json",bytes:11_422_654,sha256:"aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4")]
        for file in files { try await Task.detached { try ModelFileTransfer.verify(file.destination(in:directory),file:file) }.value }
        return directory
    }

    private func mlxDelegateSession(_ directory: URL) throws -> OWMLXSession {
        let value = try OWMLXSession(modelPath:directory.appendingPathComponent("model.pte").path,tokenizerPath:directory.appendingPathComponent("tokenizer.json").path)
        try value.load()
        return value
    }

    func testNativeExecuTorchMLXSessionStreamingCacheWarmAndReset() async throws {
        let directory = try await verifiedMLXDelegateDirectory()
        var observations: [[String: Any]] = []
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle
            let evidence: [String: Any] = ["purpose":"native-executorch-mlx-session-cache-controls","runtimeVersion":"1.5.0",
                "revision":"c1899de289a04d12100db370d81485cdf75e47ca","conditions":nativeDeviceConditions(),"observations":observations,
                "limitations":["Actual native session, not RuntimeFactory routing, product import/backend settings or tools. Same-process reopen only.","Content equality/cache lifecycle checks do not accept incorrect model answers. The strict framework arithmetic test remains separate.","No performance/energy/peak-memory/A2 replication claim."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "ExecuTorch MLX session cache controls"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let session = try mlxDelegateSession(directory)
        func generate(_ input: String, stage: String, cap: Int = 32) throws -> [String: Any] {
            session.beginOperation(); var pieces: [String] = []
            let result = try session.generatePrompt(input,outputLimit:cap,temperature:0,contextLimit:2048) { pieces.append($0) }
            observations.append(["stage":stage,"prompt":input,"result":result,"publishedPieces":pieces])
            XCTAssertEqual(result["content"] as? String,pieces.joined())
            XCTAssertFalse(pieces.isEmpty)
            XCTAssertEqual((result["cancelled"] as? NSNumber)?.boolValue,false)
            XCTAssertEqual((result["promptTokens"] as? NSNumber)?.intValue,try session.countPrompt(input).intValue)
            return result
        }
        let head = [["role":"system","content":"You are a helpful assistant."]]
        let firstMessages = head + [["role":"user","content":"My project is Cedar. Reply with only the project name."]]
        let firstPrompt = try CompiledQwen3Prompt.render(firstMessages,thinking:false)
        let first = try generate(firstPrompt,stage:"fresh-first-turn")
        XCTAssertEqual((first["cachedTokens"] as? NSNumber)?.intValue,0)
        let firstText = try XCTUnwrap(first["content"] as? String)
        XCTAssertEqual(firstText,"Cedar")
        let history = firstMessages + [["role":"assistant","content":"<think>\n\n</think>\n\n" + firstText]]
        let secondMessages = history + [["role":"user","content":"What is my project? Reply with only the project name."]]
        let secondPrompt = try CompiledQwen3Prompt.render(secondMessages,thinking:false)
        let retained = try generate(secondPrompt,stage:"retained-second-turn")
        XCTAssertEqual(retained["content"] as? String,"Cedar")
        let firstTokens = try session.tokenIDs(forPrompt:firstPrompt)
        let sampled = try XCTUnwrap(first["sampledTokenIDs"] as? [NSNumber])
        let committed = firstTokens + sampled.dropLast()
        let nextTokens = try session.tokenIDs(forPrompt:secondPrompt)
        XCTAssertTrue(nextTokens.starts(with:committed))
        XCTAssertEqual((retained["cachedTokens"] as? NSNumber)?.intValue,committed.count)
        session.reset()
        let freshSecond = try generate(secondPrompt,stage:"same-history-after-explicit-reset")
        XCTAssertEqual((freshSecond["cachedTokens"] as? NSNumber)?.intValue,0)
        XCTAssertEqual(freshSecond["content"] as? String,retained["content"] as? String)
        XCTAssertEqual(freshSecond["content"] as? String,"Cedar")
        session.reset(); session.beginOperation()
        let prefix = try CompiledQwen3Prompt.render(history,thinking:false)
        let warmed = try session.warmPrompt(prefix,futurePrompt:secondPrompt,contextLimit:2048).intValue
        observations.append(["stage":"warm-history-common-prefix","warmTokens":warmed])
        XCTAssertGreaterThan(warmed,0)
        let afterWarm = try generate(secondPrompt,stage:"same-history-after-warming")
        XCTAssertEqual((afterWarm["cachedTokens"] as? NSNumber)?.intValue,warmed)
        XCTAssertEqual(afterWarm["content"] as? String,freshSecond["content"] as? String)
        XCTAssertEqual(afterWarm["content"] as? String,"Cedar")
        session.reset()
        let arithmetic = try CompiledQwen3Prompt.render(head + [["role":"user","content":"What is 2 + 2? Reply with only the number."]],thinking:false)
        let mismatch = try generate(arithmetic,stage:"different-prefix-after-reset")
        XCTAssertEqual((mismatch["cachedTokens"] as? NSNumber)?.intValue,0)
        let capped = try generate(arithmetic,stage:"one-token-cap",cap:1)
        XCTAssertEqual((capped["generatedTokens"] as? NSNumber)?.intValue,1)
        XCTAssertEqual((capped["stopReason"] as? NSNumber)?.intValue,1)
        session.reset(); session.beginOperation()
        XCTAssertThrowsError(try session.generatePrompt(arithmetic,outputLimit:32,temperature:0,contextLimit:4096) { _ in })
        XCTAssertThrowsError(try session.generatePrompt(arithmetic,outputLimit:32,temperature:.nan,contextLimit:2048) { _ in })
        XCTAssertEqual(observations.count,7)
    }

    func testNativeExecuTorchMLXSessionCrossThreadStopAndRecovery() async throws {
        let directory = try await verifiedMLXDelegateDirectory()
        var observations: [[String: Any]] = []
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle
            let evidence: [String: Any] = ["purpose":"native-executorch-mlx-session-stop-controls","runtimeVersion":"1.5.0","observations":observations,
                "conditions":nativeDeviceConditions(),"limitations":["Cross-thread stop is synchronized from the first published-piece callback, not a native Stop gesture or OS background test.","Recovery comparison preserves actual content and does not accept wrong arithmetic as quality success."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "ExecuTorch MLX session Stop controls"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let session = try mlxDelegateSession(directory)
        let prompt = try CompiledQwen3Prompt.render([["role":"system","content":"You are a helpful assistant."],
            ["role":"user","content":"What is 2 + 2? Reply with only the number."]],thinking:false)
        session.beginOperation()
        let baseline = try session.generatePrompt(prompt,outputLimit:32,temperature:0,contextLimit:2048) { _ in }
        observations.append(["stage":"fresh-baseline","result":baseline]); session.reset()
        session.beginOperation(); var stoppedPieces: [String] = []
        let stopped = try session.generatePrompt(prompt,outputLimit:32,temperature:0,contextLimit:2048) { piece in
            stoppedPieces.append(piece)
            DispatchQueue.global(qos:.userInitiated).sync { session.stop() }
        }
        observations.append(["stage":"cross-thread-stop-on-published-piece","result":stopped,"publishedPieces":stoppedPieces])
        XCTAssertEqual(stoppedPieces.count,1)
        XCTAssertEqual((stopped["cancelled"] as? NSNumber)?.boolValue,true)
        XCTAssertEqual((stopped["stopReason"] as? NSNumber)?.intValue,3)
        session.beginOperation()
        let recovery = try session.generatePrompt(prompt,outputLimit:32,temperature:0,contextLimit:2048) { _ in }
        observations.append(["stage":"after-stop-recovery","result":recovery])
        XCTAssertEqual((recovery["cachedTokens"] as? NSNumber)?.intValue,0)
        XCTAssertEqual(recovery["content"] as? String,baseline["content"] as? String)
        XCTAssertEqual((recovery["cancelled"] as? NSNumber)?.boolValue,false)
        session.beginOperation(); session.stop()
        XCTAssertThrowsError(try session.generatePrompt(prompt,outputLimit:32,temperature:0,contextLimit:2048) { _ in })
        observations.append(["stage":"stop-before-generation-refused"])
        session.beginOperation()
        let final = try session.generatePrompt(prompt,outputLimit:32,temperature:0,contextLimit:2048) { _ in }
        observations.append(["stage":"after-pre-generation-stop-recovery","result":final])
        XCTAssertEqual((final["cachedTokens"] as? NSNumber)?.intValue,0)
        XCTAssertEqual(final["content"] as? String,baseline["content"] as? String)
        XCTAssertEqual(observations.count,5)
    }
}
