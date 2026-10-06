import Foundation
import OpenWeightsCore
@testable import OpenWeights

@MainActor enum NativeCompiledArtifact {
    static func selected() throws -> LocalModel {
        switch ProcessInfo.processInfo.environment["OW_COMPILED_ARTIFACT"] ?? "baseline" {
        case "baseline":
            guard let model = try HubClient.pinnedCatalogue().first(where: { $0.backend == .xnnpack }) else {
                throw ModelError.unsupported("The baseline compiled artifact is missing.")
            }
            return model
        case "qwen3-1.7b-8da4w-gptq-2k":
            let repo = "experimentalmachines/Qwen3-1.7B-ExecuTorch"
            let revision = "09a7ee948647508b82c29f1ce73dadcf2a73cbec"
            let specs: [(String, Int64, String)] = [
                ("xnnpack/Qwen3-1.7B-8da4w-gptq-2k.pte", 1284898560, "6842952665c40ab01bf6cc920fec6df3db9f04912700d618165466e4c95118a8"),
                ("tokenizer.json", 11422654, "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
                ("xnnpack/config.json", 4030, "f7684602a52f0ae39e127c65860d7a5416c4443367f4bd36ea63789c63f4d3d5")
            ]
            return LocalModel(name: "Qwen3 1.7B GPTQ 2k compiled tool control", backend: .xnnpack, entryFile: specs[0].0,
                files: specs.map { path, bytes, hash in
                    ModelFile(path: path, bytes: bytes, sha256: hash, url: URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(path)")!)
                }, repository: repo, revision: revision, family: "qwen3")
        case "qwen25-1.5b-8da4w-2k": return qwen25()
        default: throw ModelError.unsupported("Unknown native compiled test artifact. No silent substitution was made.")
        }
    }
    static func mlxDelegate() -> LocalModel {
        let specs: [(String, Int64, String)] = [
            ("model.pte",646789248,"9035e10cd708d03c5a3788aa2893f7ccabfa34302eae44c9be1bfe80c7dc5737"),
            ("tokenizer.json",11422654,"aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            ("export-provenance.json",1563,"f992ecc3d1a9bc750df76c57fa32146cde850d6359cc2f51f1cf63bcc4b18e6c")]
        return LocalModel(name:"Qwen3 0.6B ExecuTorch MLX local export",backend:.executorchMLX,entryFile:"model.pte",
            files:specs.map { ModelFile(path:$0.0,bytes:$0.1,sha256:$0.2) },
            revision:"c1899de289a04d12100db370d81485cdf75e47ca",family:"qwen3")
    }
    static func qwen25() -> LocalModel {
        let repo = "experimentalmachines/Qwen2.5-1.5B-Instruct-ExecuTorch", revision = "0a912670f4bf6039d0192cc420960039bff0d402"
        let specs: [(String, Int64, String)] = [
            ("xnnpack/Qwen2.5-1.5B-Instruct-8da4w-2k.pte", 1107613952, "be2c11bbe75269f03a95b0407f6bcb976b7282daf259f522850281e614f711dd"),
            ("tokenizer.json", 7031645, "c0382117ea329cdf097041132f6d735924b697924d6f6fc3945713e96ce87539"),
            ("xnnpack/config.json", 3171, "f1744c476bbcabb3ff3647db6143a2a4138ae2f902b35ae9d0df06f43f7aca23")
        ]
        return LocalModel(name: "Qwen2.5 1.5B Instruct compiled family control", backend: .xnnpack, entryFile: specs[0].0,
            files: specs.map { path, bytes, hash in ModelFile(path: path, bytes: bytes, sha256: hash,
                url: URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(path)")!) }, repository: repo, revision: revision, family: "qwen25")
    }
}
