import Foundation
import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    func testNativeExecuTorchMLXIsolatedDescriptorInference() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The isolated inference helper requires iOS 26.") }
        let revision = "c1899de289a04d12100db370d81485cdf75e47ca"
        let directory = cachedDirectory(artifact: "executorch-mlx", revision: revision)
        let files: [(String, Int64, String)] = [
            ("model.pte",646_789_248,"9035e10cd708d03c5a3788aa2893f7ccabfa34302eae44c9be1bfe80c7dc5737"),
            ("tokenizer.json",11_422_654,"aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4")]
        var evidence: [String: Any] = ["purpose":"native-executorch-mlx-isolated-descriptor-probe", "completed":false,
            "revision":revision, "runtimeVersion":"1.5.0", "conditions":nativeDeviceConditions(),
            "limitations":["Fixed arithmetic probe using the existing self-contained int4 MLX export. No RuntimeFactory admission, import, streaming, Stop/recovery, product decoding settings, retained-cache/token accounting or Core ML claim.","Read-only descriptors transport the existing checksum-verified device cache. No new weight download or external network call."]]
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Isolated ExecuTorch MLX descriptor probe"; attachment.lifetime = .keepAlways; add(attachment)
        }
        var hashes: [String: String] = [:]
        for (name,size,sha) in files {
            let url = directory.appendingPathComponent(name)
            try await Task.detached { try ModelFileTransfer.verify(url,file:ModelFile(path:name,bytes:size,sha256:sha)) }.value
            hashes[name] = try await Task.detached { try ModelFileTransfer.hash(url) }.value
        }
        evidence["independentFullFileSHA256"] = hashes
        let probe = InferenceHelperProbe()
        do {
            let reply = try await probe.run(model:directory.appendingPathComponent("model.pte"),tokenizer:directory.appendingPathComponent("tokenizer.json"))
            evidence["reply"] = reply
            evidence["acknowledgedHelperProgress"] = probe.progress
            XCTAssertEqual(reply["stage"] as? String,"generated"); XCTAssertEqual(reply["error"] as? String,"")
            XCTAssertEqual(reply["metalAvailable"] as? Bool,true)
            let pid = try XCTUnwrap(reply["processID"] as? Int64)
            XCTAssertGreaterThan(pid,0); XCTAssertNotEqual(pid,Int64(getpid()))
            let output = (reply["text"] as? String ?? "").replacingOccurrences(of:"<|im_end|>",with:"").replacingOccurrences(of:"<|endoftext|>",with:"").trimmingCharacters(in:.whitespacesAndNewlines)
            evidence["strictAnswer"] = output; XCTAssertEqual(output,"4")
            evidence["completed"] = reply["stage"] as? String == "generated" && output == "4" && pid != getpid()
        } catch {
            evidence["hostStage"] = probe.stage; evidence["hostError"] = String(describing:error)
            evidence["acknowledgedHelperProgress"] = probe.progress
            throw error
        }
    }
}
