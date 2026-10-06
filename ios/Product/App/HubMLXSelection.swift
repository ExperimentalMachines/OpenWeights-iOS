import Foundation
import OpenWeightsCore

extension HubClient {
    static func mlx(_ details: HubDetails, useStoredCredential: Bool = true,
                    readMetadata: (@Sendable (LocalModel) async throws -> Data)? = nil) async throws -> LocalModel {
        let declared = details.library_name == "mlx" || details.tags?.contains("mlx") == true
        guard declared else { throw ModelError.unsupported("This repository does not declare an MLX artifact.") }
        let files = details.siblings.map { sibling in
            ModelFile(path: sibling.rfilename, bytes: sibling.lfs?.size ?? sibling.size,
                sha256: sibling.lfs?.sha256?.lowercased(),
                gitBlobSHA1: sibling.lfs == nil ? sibling.blobId?.lowercased() : nil)
        }
        let metadata = try MLXHubArtifact.metadataFiles(repository: details.id, revision: details.sha, files: files)
        var loaded: [String: Data] = [:]
        for file in metadata {
            try Task.checkCancellation()
            let request = LocalModel(name: file.path, backend: .mlx, entryFile: file.path,
                files: [file], repository: details.id, revision: details.sha)
            let data: Data
            if let readMetadata { data = try await readMetadata(request) }
            else { data = try await HubGGUFRangeSource(model: request, useStoredCredential: useStoredCredential).read(offset: 0, length: Int(file.bytes!)) }
            try Task.checkCancellation()
            loaded[file.path] = data
        }
        return try MLXHubArtifact.select(repository: details.id, revision: details.sha, declaredMLX: declared,
            files: files, configData: loaded["config.json"]!, indexData: loaded["model.safetensors.index.json"])
    }
}
