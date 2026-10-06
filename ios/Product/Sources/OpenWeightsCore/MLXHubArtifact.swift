import Foundation

// Metadata selection declares an artifact contract, not model loading or fit.
public enum MLXHubArtifact {
    private static let companions = ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "added_tokens.json", "vocab.json", "merges.txt", "chat_template.jinja", "generation_config.json"]
    private static func pinned(_ path: String, repository: String, revision: String, files: [ModelFile]) throws -> ModelFile {
        try ModelFile.validatePath(path)
        let matches = files.filter { $0.path == path }
        guard matches.count == 1, var file = matches.first, let bytes = file.bytes, bytes > 0,
              file.sha256 != nil || file.gitBlobSHA1 != nil,
              file.sha256.map({ GGUFRangePolicy.hex($0, count: 64) }) ?? true,
              file.gitBlobSHA1.map({ GGUFRangePolicy.hex($0, count: 40) }) ?? true else {
            throw ModelError.unsupported("The MLX folder needs a unique size and published checksum for \(path).")
        }
        file.url = try GGUFRangePolicy.pinnedURL(repository: repository, revision: revision, path: path)
        file.sha256 = file.sha256?.lowercased(); file.gitBlobSHA1 = file.gitBlobSHA1?.lowercased()
        return file
    }
    public static func metadataFiles(repository: String, revision: String, files: [ModelFile]) throws -> [ModelFile] {
        var paths = ["config.json"]
        if files.contains(where: { $0.path == "model.safetensors.index.json" }) { paths.append("model.safetensors.index.json") }
        return try paths.map { path in
            let file = try pinned(path, repository: repository, revision: revision, files: files)
            guard file.bytes! <= 1_048_576 else { throw ModelError.unsupported("MLX selection metadata must be at most 1 MiB per file.") }
            return file
        }
    }
    public static func select(repository: String, revision: String, declaredMLX: Bool, files: [ModelFile],
                              configData: Data, indexData: Data? = nil) throws -> LocalModel {
        guard declaredMLX else { throw ModelError.unsupported("This repository does not declare an MLX artifact. Import a verified MLX folder instead.") }
        let metadata = try metadataFiles(repository: repository, revision: revision, files: files)
        let config = metadata[0]
        guard configData.count <= 1_048_576 else { throw ModelError.corrupt(config.path) }
        try ModelFileTransfer.verify(configData, file: config)
        guard let object = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let family = object["model_type"] as? String, !family.isEmpty,
              family == family.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ModelError.unsupported("The MLX config must declare model_type.")
        }
        var paths = ["config.json"] + companions.filter { path in files.contains { $0.path == path } }
        guard paths.contains("tokenizer.json"), paths.contains("tokenizer_config.json") else {
            throw ModelError.unsupported("The MLX folder needs matching tokenizer.json and tokenizer_config.json.")
        }
        let weights: [String]
        if metadata.count == 2 {
            let index = metadata[1]
            guard let indexData, indexData.count <= 1_048_576 else { throw ModelError.corrupt(index.path) }
            try ModelFileTransfer.verify(indexData, file: index)
            guard let object = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
                  let map = object["weight_map"] as? [String: String], !map.isEmpty,
                  map.keys.allSatisfy({ !$0.isEmpty }) else { throw ModelError.corrupt(index.path) }
            weights = Array(Set(map.values)).sorted(); paths.append(index.path)
            guard weights.allSatisfy({ $0.hasSuffix(".safetensors") }) else { throw ModelError.corrupt(index.path) }
        } else {
            guard indexData == nil else { throw ModelError.unsupported("Index data has no matching pinned repository file.") }
            weights = ["model.safetensors"]
        }
        // Copy only the selected tensors so unrelated adapters cannot overwrite
        // model parameters when the runtime enumerates owned safetensors files.
        paths += weights
        let selected = try Array(Set(paths)).sorted().map { try pinned($0, repository: repository, revision: revision, files: files) }
        var total: Int64 = 0
        for file in selected {
            let sum = total.addingReportingOverflow(file.bytes!)
            guard !sum.overflow else { throw ModelError.unsupported("The MLX folder's declared size exceeds the supported range.") }
            total = sum.partialValue
        }
        return LocalModel(name: (repository as NSString).lastPathComponent, backend: .mlx, entryFile: "config.json",
            files: selected, repository: repository, revision: revision, family: family)
    }
}
