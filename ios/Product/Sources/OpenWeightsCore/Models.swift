import Foundation

public enum ModelBackend: String, Codable, CaseIterable, Sendable {
    case llamaMetal, llamaCPU, mlx, xnnpack, executorchMLX
    public var label: String {
        switch self {
        case .llamaMetal: return "llama.cpp Metal"
        case .llamaCPU: return "llama.cpp CPU"
        case .mlx: return "MLX Metal"
        case .xnnpack: return "ExecuTorch XNNPACK"
        case .executorchMLX: return "ExecuTorch MLX (experimental)"
        }
    }
}

public struct ModelSettings: Codable, Equatable, Sendable {
    public var contextTokens = 2048
    public var outputTokens = 512
    public var threads = 4
    public var temperature: Double = 0.7
    public var topP: Double = 0.95
    // Older installs used each adapter's defaults for these filters. Keep those
    // defaults until a person selects a value rather than changing existing chats.
    public var topK: Int? = nil
    public var minP: Double? = nil
    public var repeatPenalty: Double = 1.1
    public var thinking = false
    public var reasoningEffort: ReasoningEffort? = nil
    public var answerLength: AnswerLength? = nil
    public var systemPrompt: String? = nil
    public var toolPrompt: String? = nil
    public init() {}

    public func validate(for backend: ModelBackend) throws {
        guard (128...Int(Int32.max)).contains(contextTokens), outputTokens > 0, outputTokens < contextTokens else {
            throw ModelError.unsupported("The context must hold at least 128 tokens and the output limit must leave room for the prompt.")
        }
        guard (1...128).contains(threads) else { throw ModelError.unsupported("CPU threads must be between 1 and 128.") }
        guard temperature.isFinite, temperature >= 0, temperature <= Double(Float.greatestFiniteMagnitude),
              topP.isFinite, (0...1).contains(topP), repeatPenalty.isFinite, repeatPenalty > 0,
              Float(repeatPenalty) > 0,
              repeatPenalty <= Double(Float.greatestFiniteMagnitude),
              topK.map({ (0...Int(Int32.max)).contains($0) }) ?? true,
              minP.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
            throw ModelError.unsupported("Sampling values must be finite. Temperature cannot be negative, Top K cannot be negative, Top P and Min P must be between 0 and 1, and repeat penalty must be positive.")
        }
        if (backend == .xnnpack || backend == .executorchMLX) && contextTokens != 2048 {
            throw ModelError.unsupported("This compiled export has a fixed 2,048-token context. Select 2,048 in model settings.")
        }
    }

    public func sharingGeneration(from shared: ModelSettings) -> ModelSettings {
        var result = shared
        result.contextTokens = contextTokens
        result.threads = threads
        return result
    }
}

public struct ModelFile: Codable, Equatable, Sendable {
    public var path: String
    public var bytes: Int64?
    public var sha256: String?
    public var gitBlobSHA1: String?
    public var url: URL?
    public init(path: String, bytes: Int64? = nil, sha256: String? = nil, url: URL? = nil, gitBlobSHA1: String? = nil) {
        self.path = path; self.bytes = bytes; self.sha256 = sha256; self.url = url; self.gitBlobSHA1 = gitBlobSHA1
    }

    public func destination(in directory: URL) throws -> URL {
        try Self.validatePath(path)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        // Foundation may leave a symlink unresolved when the final file does not yet exist.
        // Owned model paths never need symlinks, so inspect each existing component directly.
        var current = directory
        for component in components {
            current.appendPathComponent(String(component))
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw ModelError.invalidPath(path) }
        }
        return directory.appendingPathComponent(path)
    }

    public static func validatePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ModelError.invalidPath(path)
        }
    }
}

public struct LocalModel: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case downloading, paused, ready, failed }
    public var id: UUID
    public var name: String
    public var repository: String?
    public var revision: String?
    public var backend: ModelBackend
    public var entryFile: String
    public var family: String?
    public var files: [ModelFile]
    public var state: State
    public var settings: ModelSettings
    public var failure: String?
    public var installedAt: Date
    public init(id: UUID = UUID(), name: String, backend: ModelBackend, entryFile: String,
                files: [ModelFile], repository: String? = nil, revision: String? = nil, family: String? = nil) {
        self.id = id; self.name = name; self.backend = backend; self.entryFile = entryFile
        self.files = files; self.repository = repository; self.revision = revision; self.family = family
        self.state = .downloading; self.settings = ModelSettings(); self.installedAt = Date()
    }
}

public enum ModelError: LocalizedError {
    case invalidPath(String), unsupported(String), corrupt(String)
    public var errorDescription: String? {
        switch self {
        case .invalidPath(let value): return "Unsafe model file path: \(value)"
        case .unsupported(let reason): return reason
        case .corrupt(let file): return "Model verification failed for \(file). Retry the download."
        }
    }
}

public actor ModelLibrary {
    private struct Snapshot: Codable { var version = 1; var models: [LocalModel]; var sharedGeneration: ModelSettings? = nil }
    private let file: URL
    private var models: [LocalModel]
    private var sharedGeneration: ModelSettings?
    public init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
            guard snapshot.version == 1 else { throw StoreError.unsupportedVersion(snapshot.version) }
            models = snapshot.models
            sharedGeneration = snapshot.sharedGeneration
        } else { models = []; sharedGeneration = nil }
    }
    public func list() -> [LocalModel] {
        models.map { model in
            var effective = model
            if let sharedGeneration { effective.settings = model.settings.sharingGeneration(from: sharedGeneration) }
            return effective
        }.sorted { $0.installedAt > $1.installedAt }
    }
    public func save(_ model: LocalModel) throws {
        var next = models.filter { $0.id != model.id }; next.append(model)
        try commit(next, shared: sharedGeneration)
    }
    public func saveSettings(_ model: LocalModel) throws {
        try model.settings.validate(for: model.backend)
        guard var updated = models.first(where: { $0.id == model.id }) else {
            throw ModelError.unsupported("This model is no longer in the library.")
        }
        updated.settings = model.settings; updated.backend = model.backend
        var next = models.filter { $0.id != model.id }; next.append(updated)
        // Download state changes must never overwrite shared preferences. Only an
        // explicit settings save starts or changes the shared generation record.
        var shared = model.settings
        shared.contextTokens = ModelSettings().contextTokens; shared.threads = ModelSettings().threads
        try commit(next, shared: shared)
    }
    public func delete(_ id: UUID) throws { try commit(models.filter { $0.id != id }, shared: sharedGeneration) }
    private func commit(_ next: [LocalModel], shared: ModelSettings?) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Snapshot(models: next, sharedGeneration: shared)).write(to: file, options: .atomic)
        models = next; sharedGeneration = shared
    }
}
