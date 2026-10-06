import Foundation
import OpenWeightsCore

@MainActor enum NativeLFMArtifact {
    static func metal() -> LocalModel {
        let repository = "LiquidAI/LFM2.5-1.2B-Instruct-GGUF"
        let revision = "8ed288026e23958ad9dfa92d53ed773a8eee7125"
        let file = "LFM2.5-1.2B-Instruct-Q4_K_M.gguf"
        return LocalModel(name: "LFM2.5 1.2B Q4_K_M native shortlist acceptance", backend: .llamaMetal, entryFile: file,
            files: [ModelFile(path: file, bytes: 730895168, sha256: "b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5",
                url: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file)")!)],
            repository: repository, revision: revision, family: "lfm2")
    }
}
