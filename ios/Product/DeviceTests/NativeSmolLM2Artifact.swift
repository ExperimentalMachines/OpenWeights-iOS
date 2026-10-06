import Foundation
import OpenWeightsCore
@testable import OpenWeights

@MainActor enum NativeSmolLM2Artifact {
    static func selected() -> LocalModel {
        let repo = "experimentalmachines/SmolLM2-135M-Instruct-ExecuTorch", revision = "720399c83ad6ebabcd8e966165c41f6fe63e2c3d"
        let specs: [(String, Int64, String)] = [
            ("xnnpack/SmolLM2-135M-Instruct-8da4w-gptq-2k.pte", 106018048, "2fd862ef2370b718c2240e9d29e36cf723d16ce8f2fe758a0e06133d8306b38b"),
            ("tokenizer.json", 2104556, "9ca9acddb6525a194ec8ac7a87f24fbba7232a9a15ffa1af0c1224fcd888e47c"),
            ("xnnpack/config.json", 3953, "772b2735e89bdcf72650f21dbdcb5943f8794aae4820488dd6b876aab70418e3")
        ]
        return LocalModel(name:"SmolLM2 135M Instruct compiled family control",backend:.xnnpack,entryFile:specs[0].0,
            files:specs.map { path,bytes,hash in ModelFile(path:path,bytes:bytes,sha256:hash,
                url:URL(string:"https://huggingface.co/\(repo)/resolve/\(revision)/\(path)")!) },
            repository:repo,revision:revision,family:"smollm2")
    }
}
