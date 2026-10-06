import Foundation
import OpenWeightsCore
@testable import OpenWeights

/// Test-only artifact selection. Historical acceptance stays on its original model by default.
@MainActor enum NativeAgentArtifact {
    static func selected() throws -> LocalModel {
        switch ProcessInfo.processInfo.environment["OW_AGENT_ARTIFACT"] ?? "baseline" {
        case "baseline":
            guard let model = try HubClient.pinnedCatalogue().first(where: { $0.backend == .llamaMetal }) else {
                throw ModelError.unsupported("The baseline GGUF artifact is missing.")
            }
            return model
        case "qwen3-1.7b-q4-k-m":
            let repo = "unsloth/Qwen3-1.7B-GGUF"
            let revision = "d7f544eead698dbd1f15126ef60b45a1e1933222"
            let path = "Qwen3-1.7B-Q4_K_M.gguf"
            return LocalModel(name: "Qwen3 1.7B Q4_K_M agent control", backend: .llamaMetal, entryFile: path,
                files: [ModelFile(path: path, bytes: 1107409472,
                    sha256: "b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897",
                    url: URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(path)")!)],
                repository: repo, revision: revision, family: "qwen3")
        default:
            throw ModelError.unsupported("Unknown native agent test artifact. No silent substitution was made.")
        }
    }
    static func evidence(_ model: LocalModel) -> [String: Any] {
        ["name": model.name, "repository": model.repository ?? "", "revision": model.revision ?? "",
         "backend": model.backend.rawValue, "entryFile": model.entryFile,
         "files": model.files.map { ["path": $0.path, "bytes": $0.bytes ?? -1, "sha256": $0.sha256 ?? ""] as [String: Any] }]
    }
}
