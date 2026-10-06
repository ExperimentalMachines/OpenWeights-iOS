import Foundation

public enum CompiledHubArtifact {
    public static func configPath(for entry: String) throws -> String {
        try ModelFile.validatePath(entry)
        guard entry.hasSuffix(".pte") else { throw ModelError.unsupported("Select a compiled .pte export.") }
        let parent = (entry as NSString).deletingLastPathComponent
        return parent.isEmpty ? "config.json" : parent + "/config.json"
    }

    public static func select(repository: String, revision: String, entry: String,
                              files: [ModelFile], configData: Data) throws -> LocalModel {
        let configPath = try configPath(for: entry)
        func unique(_ path: String) throws -> ModelFile {
            let matches = files.filter { $0.path == path }
            guard matches.count == 1, var file = matches.first, let bytes = file.bytes, bytes > 0,
                  file.sha256 != nil || file.gitBlobSHA1 != nil,
                  file.sha256.map({ GGUFRangePolicy.hex($0, count: 64) }) ?? true,
                  file.gitBlobSHA1.map({ GGUFRangePolicy.hex($0, count: 40) }) ?? true else {
                throw ModelError.unsupported("The compiled export needs a unique size and published checksum for \(path).")
            }
            // Rebuild URLs from the pin rather than accepting caller-supplied routes.
            file.url = try GGUFRangePolicy.pinnedURL(repository: repository, revision: revision, path: path)
            file.sha256 = file.sha256?.lowercased(); file.gitBlobSHA1 = file.gitBlobSHA1?.lowercased()
            return file
        }
        let config = try unique(configPath)
        guard configData.count <= 1_048_576 else { throw ModelError.unsupported("Compiled export metadata exceeds its 1 MiB limit.") }
        try ModelFileTransfer.verify(configData, file: config)
        let metadata: Metadata
        do { metadata = try JSONDecoder().decode(Metadata.self, from: configData) }
        catch { throw ModelError.unsupported("The compiled export metadata is incomplete or invalid.") }
        guard metadata.runtime == "executorch", metadata.runtime_version == "1.4.0", metadata.backend == "xnnpack",
              metadata.tokenizer == "tokenizer.json", let family = CompiledModelFamily.from(sourceModel: metadata.source_model) else {
            throw ModelError.unsupported("This adapter supports Qwen3, Qwen2.5 Instruct, SmolLM2 Instruct and Llama 3.2 Instruct XNNPACK exports for ExecuTorch 1.4.0 with top-level tokenizer.json.")
        }
        let matches = metadata.variants.filter { $0.file == (entry as NSString).lastPathComponent }
        guard matches.count == 1, let variant = matches.first, variant.context == 2048,
              variant.size_bytes > 0, GGUFRangePolicy.hex(variant.sha256, count: 64) else {
            throw ModelError.unsupported("Select a declared 2,048-token variant with its weight size and SHA-256.")
        }
        let weights = try unique(entry)
        guard weights.bytes == variant.size_bytes, weights.sha256 == variant.sha256.lowercased() else {
            throw ModelError.unsupported("The selected weights disagree with the pinned export metadata.")
        }
        let parent = (entry as NSString).deletingLastPathComponent
        let external = files.filter { $0.path.hasSuffix(".ptd") && ($0.path as NSString).deletingLastPathComponent == parent }
        guard external.isEmpty else { throw ModelError.unsupported("External .ptd weights are not supported by this runner yet. Select a self-contained export.") }
        let tokenizer = try unique("tokenizer.json")
        return LocalModel(name: (entry as NSString).lastPathComponent, backend: .xnnpack, entryFile: entry,
            files: [config, tokenizer, weights], repository: repository, revision: revision, family: family.rawValue)
    }

    private struct Metadata: Decodable {
        var runtime: String; var runtime_version: String; var backend: String
        var tokenizer: String; var source_model: String; var variants: [Variant]
    }
    private struct Variant: Decodable {
        var file: String; var context: Int; var size_bytes: Int64; var sha256: String
    }
}
