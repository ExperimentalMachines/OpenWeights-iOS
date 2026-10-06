import Foundation
import XCTest
import UIKit
import OpenWeightsCore
import OWInferenceProbe
@testable import OpenWeights

extension ProductTests {
    func testNativeExecuTorchMLXPrivateFrameworkInference() async throws {
        let revision = "c1899de289a04d12100db370d81485cdf75e47ca"
        let directory = cachedDirectory(artifact: "executorch-mlx", revision: revision)
        let files: [(String, Int64, String)] = [
            ("model.pte",646_789_248,"9035e10cd708d03c5a3788aa2893f7ccabfa34302eae44c9be1bfe80c7dc5737"),
            ("tokenizer.json",11_422_654,"aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4")]
        var evidence: [String: Any] = ["purpose":"native-executorch-mlx-private-framework-probe", "completed":false,
            "revision":revision, "runtimeVersion":"1.5.0", "conditions":nativeDeviceConditions(),
            "processID":getpid(), "limitations":[
                "Fixed arithmetic probe, no RuntimeFactory admission, import, streaming, Stop/recovery, product decoding settings, retained-cache/token accounting, tools or Core ML claim.",
                "Private ET/MLX symbols share the app process, without a separate security or crash boundary. Existing script isolation remains independent.",
                "Existing checksum-verified cache, no new weight download. Phase samples are diagnostics, not benchmark timings."]]
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Private-framework ExecuTorch MLX descriptor probe"; attachment.lifetime = .keepAlways; add(attachment)
        }
        var hashes: [String: String] = [:]
        for (name,size,sha) in files {
            let url = directory.appendingPathComponent(name)
            try await Task.detached { try ModelFileTransfer.verify(url,file:ModelFile(path:name,bytes:size,sha256:sha)) }.value
            hashes[name] = try await Task.detached { try ModelFileTransfer.hash(url) }.value
        }
        evidence["independentFullFileSHA256"] = hashes
        let model = open(directory.appendingPathComponent("model.pte").path,O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        let tokenizer = open(directory.appendingPathComponent("tokenizer.json").path,O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        defer { if model >= 0 { close(model) }; if tokenizer >= 0 { close(tokenizer) } }
        XCTAssertGreaterThanOrEqual(model,0); XCTAssertGreaterThanOrEqual(tokenizer,0)
        guard model >= 0, tokenizer >= 0 else { throw CocoaError(.fileReadNoPermission) }
        var phases: [[String: Any]] = []
        let reply = OWRunMLXDescriptorProbeWithProgress(model,tokenizer) { stage,footprint in
            phases.append(["stage":stage,"footprintBytes":footprint,
                "availableMemoryBytes":OWDescriptorAvailableMemory(),
                "observedAtUTC":ISO8601DateFormatter().string(from:Date())])
        }
        evidence["reply"] = reply; evidence["phases"] = phases
        XCTAssertEqual(reply["stage"] as? String,"generated"); XCTAssertEqual(reply["error"] as? String,"")
        XCTAssertEqual(phases.first?["stage"] as? String,"native-entered")
        XCTAssertEqual(phases.last?["stage"] as? String,"generation-returned")
        let canonical = OWRunMLXCanonicalPathProbe(directory.appendingPathComponent("model.pte").path,directory.appendingPathComponent("tokenizer.json").path)
        evidence["canonicalPathReply"] = canonical
        XCTAssertEqual(canonical["stage"] as? String,"generated"); XCTAssertEqual(canonical["error"] as? String,"")
        XCTAssertEqual(canonical["text"] as? String,reply["text"] as? String)
        let output = (reply["text"] as? String ?? "").replacingOccurrences(of:"<|im_end|>",with:"").replacingOccurrences(of:"<|endoftext|>",with:"").trimmingCharacters(in:.whitespacesAndNewlines)
        evidence["strictAnswer"] = output; XCTAssertEqual(output,"4")
        let descriptorsOpen = fcntl(model,F_GETFL) & O_ACCMODE == O_RDONLY && fcntl(tokenizer,F_GETFL) & O_ACCMODE == O_RDONLY
        evidence["callerDescriptorsRemainReadOnly"] = descriptorsOpen; XCTAssertTrue(descriptorsOpen)
        evidence["completed"] = reply["stage"] as? String == "generated" && output == "4" && descriptorsOpen
    }
}
