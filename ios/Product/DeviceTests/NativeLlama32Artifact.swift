import Foundation
import OpenWeightsCore
@testable import OpenWeights

@MainActor enum NativeLlama32Artifact {
    static func selected() -> LocalModel {
        let repo = "experimentalmachines/Llama-3.2-1B-Instruct-ExecuTorch", revision = "0b5d9cf6ae23d83d754e34c219bd97dcafc834cf"
        let specs: [(String, Int64, String)] = [
            ("xnnpack/Llama-3.2-1B-Instruct-8da4w-gptq-2k.pte", 959972864, "f82c34bc8698fa020f8e57c400e2730106bd473694d6eae1eac1e2cfbfc73188"),
            ("tokenizer.json", 9085657, "79e3e522635f3171300913bb421464a87de6222182a0570b9b2ccba2a964b2b4"),
            ("xnnpack/config.json", 4185, "27d0cb9b8f1592aa6bbae45a194e75c04ad5a158b81fedcff0fe9f6b06613805")
        ]
        return LocalModel(name:"Llama 3.2 1B Instruct compiled family control",backend:.xnnpack,entryFile:specs[0].0,
            files:specs.map { path,bytes,hash in ModelFile(path:path,bytes:bytes,sha256:hash,
                url:URL(string:"https://huggingface.co/\(repo)/resolve/\(revision)/\(path)")!) },
            repository:repo,revision:revision,family:"llama32")
    }
}
