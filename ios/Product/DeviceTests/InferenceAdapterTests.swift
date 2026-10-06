import Foundation
import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    func testNativeExecuTorchMLXFactoryStopResetAndRecovery() async throws {
        var model=NativeCompiledArtifact.mlxDelegate()
        model.settings.temperature=0;model.settings.outputTokens=512;model.settings.repeatPenalty=1
        let directory=cachedDirectory(artifact:"executorch-mlx",revision:try XCTUnwrap(model.revision))
        for file in model.files { try ModelDownloads.verify(file.destination(in:directory),file:file) }
        let runtime=try RuntimeFactory.make(model)
        var observations:[[String:Any]]=[]
        let idle=UIApplication.shared.isIdleTimerDisabled;UIApplication.shared.isIdleTimerDisabled=true
        defer {
            runtime.cancel();UIApplication.shared.isIdleTimerDisabled=idle
            let value:[String:Any]=["purpose":"native-executorch-mlx-product-factory-stop-recovery","artifact":NativeAgentArtifact.evidence(model),
                "observations":observations,"conditions":nativeDeviceConditions(),
                "limitations":["Actual RuntimeFactory and Swift adapter with a direct controlled stream consumer. Stop is called on the first consumed token, not a native button gesture.","No tools, external provider, OS lifecycle, performance, energy or general model quality claim. Strict arithmetic remains a separate failing acceptance test."]]
            let attachment=XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name="ExecuTorch MLX product factory controls";attachment.lifetime = .keepAlways;add(attachment)
        }
        try await runtime.load(model:model,directory:directory)
        XCTAssertTrue(runtime is ProductExecuTorchRuntime);XCTAssertTrue(runtime.supportsTools)
        let head=[["role":"system","content":"You are a helpful assistant."]]
        let long=head+[["role":"user","content":"Count from 1 to 200, writing every number separated by commas. Do not skip any numbers."]]
        var pieces:[String]=[],stopped:RuntimeReply?
        for try await event in runtime.stream(messages:long,settings:model.settings) {
            switch event {
            case .token(let piece):pieces.append(piece);if pieces.count == 1 { runtime.cancel() }
            case .reply(let reply):stopped=reply
            }
        }
        let cancelled=try XCTUnwrap(stopped)
        observations.append(["stage":"stop-on-first-consumed-token","pieces":pieces,"content":cancelled.content,
            "cancelled":cancelled.cancelled,"stopReason":cancelled.stopReason.rawValue,"generatedTokens":cancelled.generatedTokens])
        XCTAssertFalse(pieces.isEmpty);XCTAssertTrue(cancelled.cancelled);XCTAssertEqual(cancelled.stopReason,.cancelled)
        model.settings.outputTokens=32
        let recall=head+[["role":"user","content":"My project is Cedar. Reply with only the project name."]]
        func answer(_ stage:String) async throws -> RuntimeReply {
            var text="",result:RuntimeReply?
            for try await event in runtime.stream(messages:recall,settings:model.settings) {
                switch event { case .token(let piece):text += piece;case .reply(let reply):result=reply }
            }
            let reply=try XCTUnwrap(result)
            observations.append(["stage":stage,"content":reply.content,"stream":text,"cachedTokens":reply.cachedTokens,
                "cancelled":reply.cancelled,"stopReason":reply.stopReason.rawValue])
            XCTAssertEqual(text,reply.content);XCTAssertEqual(reply.content,"Cedar");XCTAssertFalse(reply.cancelled)
            return reply
        }
        let recovery=try await answer("recovery-after-Stop");XCTAssertEqual(recovery.cachedTokens,0)
        await runtime.reset()
        let fresh=try await answer("recovery-after-explicit-reset");XCTAssertEqual(fresh.cachedTokens,0)
        let count=try await runtime.promptSize(messages:recall,settings:model.settings,tools:[])
        XCTAssertTrue(count.exact);XCTAssertGreaterThan(count.tokens,0)
        var bad=model.settings;bad.contextTokens=4096
        do { _=try await runtime.promptSize(messages:recall,settings:bad,tools:[]);XCTFail("Wrong export context admitted") } catch {}
        var wrong=model;wrong.family="qwen25"
        XCTAssertThrowsError(try RuntimeFactory.make(wrong))
    }
}
