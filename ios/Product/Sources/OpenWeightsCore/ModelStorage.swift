import Foundation

public struct ModelStorageRow: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let ownedBytes: Int64
    public let declaredFileBytes: Int64
    public let incompleteBytes: Int64
    public let metadata: GGUFMetadata?
    public let weights: UsageWeights?
    public let inspectionError: String?
}
public struct ModelStorageSnapshot: Equatable, Sendable {
    public let observedAt: Date
    public let ownedBytes: Int64
    public let unlistedBytes: Int64
    public let rows: [ModelStorageRow]
    public func modelsWithKnownWeights(_ models: [LocalModel]) -> [LocalModel] {
        models.filter { model in
            guard let weights = UsageWeights(model: model) else { return false }
            return rows.contains { $0.id == model.id && $0.weights == weights }
        }
    }
}
public actor LocalGGUFByteSource: GGUFByteSource {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func read(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, (1...1_048_576).contains(length) else { throw ModelError.invalidPath(url.lastPathComponent) }
        guard try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ModelError.invalidPath(url.lastPathComponent)
        }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset))
        return try file.read(upToCount: length) ?? Data()
    }
}

public actor ModelStorageInspector {
    public init() {}
    public func snapshot(root: URL, models: [LocalModel]) async throws -> ModelStorageSnapshot {
        guard try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ModelError.invalidPath(root.lastPathComponent)
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var scanError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in scanError = error; return false }) else {
            throw ModelError.unsupported("Model storage could not be inspected.")
        }
        var total: Int64 = 0; var sizes: [UUID: Int64] = [:]
        // Foundation enumerates /var through /private/var on Apple platforms.
        // Normalize both sides before attributing an owned file to its model.
        let prefix = root.resolvingSymlinksInPath().path + "/"
        while let file = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, let bytes = values.fileSize, bytes >= 0 else { continue }
            total = GGUFMemoryPreview.add(total, Int64(bytes))
            let path = file.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix) else { throw ModelError.invalidPath(file.lastPathComponent) }
            let relative = path.dropFirst(prefix.count)
            if let first = relative.split(separator: "/").first, let id = UUID(uuidString: String(first)) {
                sizes[id] = GGUFMemoryPreview.add(sizes[id] ?? 0, Int64(bytes))
            }
        }
        if let scanError { throw scanError }
        var rows: [ModelStorageRow] = []
        for model in models {
            try Task.checkCancellation()
            let directory = root.appendingPathComponent(model.id.uuidString, isDirectory: true)
            var final: Int64 = 0
            var presentWeightPaths: Set<String> = []
            for modelFile in model.files {
                if let destination = try? modelFile.destination(in: directory),
                   let values = try? destination.resourceValues(forKeys: keys), values.isRegularFile == true,
                   values.isSymbolicLink != true, let bytes = values.fileSize, bytes >= 0 {
                    final = GGUFMemoryPreview.add(final, Int64(bytes))
                    if modelFile.bytes == Int64(bytes) { presentWeightPaths.insert(modelFile.path) }
                }
            }
            var metadata: GGUFMetadata?; var failure: String?
            if model.state == .ready, model.backend == .llamaCPU || model.backend == .llamaMetal {
                do {
                    let file = try ModelFile(path: model.entryFile).destination(in: directory)
                    metadata = try await GGUFHeaderParser(source: LocalGGUFByteSource(url: file)).parse()
                } catch is CancellationError { throw CancellationError() }
                catch { failure = error.localizedDescription }
            }
            let owned = sizes[model.id] ?? 0
            let weightFiles = UsageWeights.files(model)
            let weights = weightFiles.allSatisfy { presentWeightPaths.contains($0.path) } ? UsageWeights(model: model) : nil
            rows.append(ModelStorageRow(id: model.id, ownedBytes: owned, declaredFileBytes: final,
                incompleteBytes: max(0, owned - final), metadata: metadata, weights: weights, inspectionError: failure))
        }
        let listed = rows.reduce(Int64(0)) { GGUFMemoryPreview.add($0, $1.ownedBytes) }
        return ModelStorageSnapshot(observedAt: Date(), ownedBytes: total, unlistedBytes: max(0, total - listed), rows: rows)
    }
}
