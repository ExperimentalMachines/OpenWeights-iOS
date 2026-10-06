import CryptoKit
import Darwin
import Foundation

public enum ModelFolderFormat: String, CaseIterable, Sendable { case mlx, xnnpack, executorchMLX }
public struct ImportedModelFolder: Sendable {
    public let entryFile: String
    public let family: String
    public let files: [ModelFile]
}

public enum ModelFolderImport {
    public static func copy(from source: URL, to destination: URL, format: ModelFolderFormat,
                            access: WorkspaceAccess = .local) async throws -> ImportedModelFolder {
        let operation = FolderImportOperation()
        return try await withTaskCancellationHandler {
            try await Task.detached { try operation.copy(source, destination: destination, format: format, access: access) }.value
        } onCancel: { operation.cancel() }
    }
}

private final class FolderImportOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var coordinators: [NSFileCoordinator] = []
    private struct Plan: Equatable {
        var entry: String
        var family: String
        var paths: [String]
        var declaredWeights: ModelFile?
    }
    func cancel() {
        let active = lock.withLock { cancelled = true; return coordinators }
        active.forEach { $0.cancel() }
    }
    private func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
    private func coordinate<T>(_ url: URL, enabled: Bool, body: (URL) throws -> T) throws -> T {
        try check()
        if !enabled { return try body(url) }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        try lock.withLock { if cancelled { throw CancellationError() }; coordinators.append(coordinator) }
        defer { lock.withLock { coordinators.removeAll { $0 === coordinator } } }
        var result: Result<T, Error>?, error: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &error) { coordinated in
            result = Result { try self.check(); return try body(coordinated) }
        }
        if let result { return try result.get() }
        try check()
        if let error { throw error }
        throw ModelError.unsupported("The model folder could not be coordinated. Select it again in Files.")
    }
    func copy(_ source: URL, destination: URL, format: ModelFolderFormat, access: WorkspaceAccess) throws -> ImportedModelFolder {
        try check()
        guard source.isFileURL, destination.isFileURL else { throw ModelError.invalidPath(source.lastPathComponent) }
        if access == .securityScoped && !source.startAccessingSecurityScopedResource() {
            throw ModelError.unsupported("Access to this model folder expired. Select it again in Files.")
        }
        defer { if access == .securityScoped { source.stopAccessingSecurityScopedResource() } }
        guard try FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw ModelError.unsupported("Select a model folder. Folder links cannot be imported.")
        }
        return try coordinate(source, enabled: access != .local) { rootURL in
            let root = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw self.failure("The selected model folder cannot be opened.") }
            defer { Darwin.close(root) }
            let paths = try self.list(root)
            let plan = try self.plan(root, paths: paths, format: format)
            try self.check()
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A pre-existing destination belongs to its owner, including on a failed import.
            guard mkdir(destination.path, mode_t(0o700)) == 0 else { throw self.failure("The owned model folder could not be created.") }
            var committed = false
            defer { if !committed { try? FileManager.default.removeItem(at: destination) } }
            var files: [ModelFile] = []
            for path in plan.paths {
                try self.check()
                let target = try ModelFile(path: path).destination(in: destination)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let sourceURL = rootURL.appendingPathComponent(path)
                let imported = try self.coordinate(sourceURL, enabled: access != .local) { coordinated in
                    guard coordinated.resolvingSymlinksInPath().path == sourceURL.resolvingSymlinksInPath().path else {
                        throw ModelError.unsupported("A model file moved during import. Select its current folder again.")
                    }
                    let current = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard current >= 0 else { throw self.failure("The selected model folder moved during import.") }
                    defer { Darwin.close(current) }
                    var heldInfo = stat(), currentInfo = stat()
                    guard fstat(root, &heldInfo) == 0, fstat(current, &currentInfo) == 0,
                          heldInfo.st_dev == currentInfo.st_dev, heldInfo.st_ino == currentInfo.st_ino else {
                        throw ModelError.unsupported("The selected model folder changed. Select it again before importing.")
                    }
                    // Every component is opened from the held root, so a changed parent
                    // path cannot redirect the copy outside the selected model folder.
                    let input = try self.open(root, path: path)
                    defer { Darwin.close(input) }
                    return try self.copyFile(input, to: target)
                }
                files.append(ModelFile(path: path, bytes: imported.bytes, sha256: imported.sha256))
            }
            try self.check()
            let owned = Darwin.open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard owned >= 0 else { throw self.failure("The owned model folder cannot be verified.") }
            defer { Darwin.close(owned) }
            guard try self.plan(owned, paths: plan.paths, format: format) == plan else {
                throw ModelError.unsupported("Model metadata changed during import. Retry after the source finishes changing.")
            }
            if let declared = plan.declaredWeights {
                guard let actual = files.first(where: { $0.path == declared.path }), actual.bytes == declared.bytes,
                      actual.sha256 == declared.sha256 else { throw ModelError.corrupt(declared.path) }
            }
            committed = true
            return ImportedModelFolder(entryFile: plan.entry, family: plan.family, files: files)
        }
    }
    private func list(_ root: Int32) throws -> [String] {
        var result: [String] = [], visits = 0
        func walk(_ parent: Int32, prefix: String, depth: Int) throws {
            guard depth <= 12 else { throw ModelError.unsupported("The model folder is nested too deeply. Select the model's own folder.") }
            let fd = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { throw failure("The model folder cannot be listed.") }
            guard let stream = fdopendir(fd) else { Darwin.close(fd); throw failure("The model folder cannot be listed.") }
            defer { closedir(stream) }
            errno = 0
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
                if name.hasPrefix(".") { errno = 0; continue }
                visits += 1; try check()
                guard visits <= 4096 else { throw ModelError.unsupported("Select the model's own folder with fewer than 4,096 visible entries.") }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                try ModelFile.validatePath(path)
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("A model file changed while listing the folder.") }
                if info.st_mode & S_IFMT == S_IFDIR {
                    let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw failure("A model subfolder cannot be opened without following links.") }
                    defer { Darwin.close(child) }
                    try walk(child, prefix: path, depth: depth + 1)
                } else if info.st_mode & S_IFMT == S_IFREG { result.append(path) }
                // Links and special files cannot supply a required model component.
                errno = 0
            }
            guard errno == 0 else { throw failure("The model folder listing was interrupted.") }
        }
        try walk(root, prefix: "", depth: 0)
        return result.sorted()
    }
    private func open(_ root: Int32, path: String) throws -> Int32 {
        try ModelFile.validatePath(path)
        let parts = path.split(separator: "/").map(String.init)
        var parent = dup(root); guard parent >= 0 else { throw failure("The model folder cannot be opened.") }
        defer { Darwin.close(parent) }
        for name in parts.dropLast() {
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw ModelError.invalidPath(path) }
            Darwin.close(parent); parent = child
        }
        let fd = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ModelError.invalidPath(path) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { Darwin.close(fd); throw ModelError.corrupt(path) }
        return fd
    }
    private func object(_ root: Int32, path: String) throws -> [String: Any] {
        let fd = try open(root, path: path); defer { Darwin.close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_size <= 2 * 1024 * 1024 else { throw ModelError.corrupt(path) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try file.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 2 * 1024 * 1024, let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ModelError.corrupt(path) }
        return result
    }
    private func plan(_ root: Int32, paths: [String], format: ModelFolderFormat) throws -> Plan {
        let available = Set(paths)
        let companions = ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "added_tokens.json", "vocab.json", "merges.txt", "chat_template.jinja", "generation_config.json"]
        guard available.contains("tokenizer.json") else { throw ModelError.unsupported("The model folder must contain its matching tokenizer.json at the top level.") }
        switch format {
        case .mlx:
            let config = try object(root, path: "config.json")
            guard let family = config["model_type"] as? String, !family.isEmpty, available.contains("tokenizer_config.json") else {
                throw ModelError.unsupported("An MLX folder needs config.json with model_type and the matching tokenizer configuration.")
            }
            var weights = paths.filter { $0.hasSuffix(".safetensors") }
            var selected = ["config.json"] + companions.filter { available.contains($0) }
            if available.contains("model.safetensors.index.json") {
                let index = try object(root, path: "model.safetensors.index.json")
                guard let map = index["weight_map"] as? [String: String], !map.isEmpty else { throw ModelError.corrupt("model.safetensors.index.json") }
                weights = Array(Set(map.values)).sorted(); selected.append("model.safetensors.index.json")
            }
            guard !weights.isEmpty, weights.allSatisfy({ $0.hasSuffix(".safetensors") && available.contains($0) }) else {
                throw ModelError.unsupported("The MLX folder is missing its safetensors weights or an indexed shard.")
            }
            for path in weights { try ModelFile.validatePath(path) }
            return Plan(entry: "config.json", family: family, paths: Array(Set(selected + weights)).sorted())
        case .executorchMLX:
            guard available.contains("export-provenance.json"), available.contains("model.pte") else {
                throw ModelError.unsupported("This compiled MLX folder requires model.pte, export-provenance.json and top-level tokenizer.json.")
            }
            let provenance = try object(root,path:"export-provenance.json")
            guard let versions = provenance["versions"] as? [String: Any], versions["executorch"] as? String == "1.5.0",
                  let source = provenance["sourceRepo"] as? String, CompiledModelFamily.from(sourceModel:source) == .qwen3,
                  let revision = provenance["sourceRevision"] as? String, GGUFRangePolicy.hex(revision,count:40),
                  let hash = provenance["artifactSHA256"] as? String, GGUFRangePolicy.hex(hash,count:64),
                  let configuration = provenance["exportConfiguration"] as? [String: Any],
                  let backend = configuration["backend"] as? [String: Any],
                  let mlx = backend["mlx"] as? [String: Any], mlx["enabled"] as? Bool == true,
                  let export = configuration["export"] as? [String: Any],
                  (export["max_context_length"] as? NSNumber) == NSNumber(value:2048),
                  (export["max_seq_length"] as? NSNumber) == NSNumber(value:2048),
                  let model = configuration["model"] as? [String: Any], model["enable_dynamic_shape"] as? Bool == true,
                  model["use_kv_cache"] as? Bool == true,
                  paths.filter({ $0.hasSuffix(".pte") }).count == 1,
                  !paths.contains(where: { $0.hasSuffix(".ptd") }) else {
                throw ModelError.unsupported("This adapter requires a self-contained Qwen3 ExecuTorch 1.5 MLX export with dynamic 2,048-token prefill, KV cache and its declared weight SHA-256.")
            }
            let modelFD = try open(root,path:"model.pte")
            defer { Darwin.close(modelFD) }
            var modelInfo = stat()
            guard fstat(modelFD,&modelInfo) == 0, modelInfo.st_size > 0 else { throw ModelError.corrupt("model.pte") }
            return Plan(entry:"model.pte",family:CompiledModelFamily.qwen3.rawValue,
                paths:["model.pte","tokenizer.json","export-provenance.json"],
                declaredWeights:ModelFile(path:"model.pte",bytes:modelInfo.st_size,sha256:hash.lowercased()))
        case .xnnpack:
            var candidates: [Plan] = []
            for entry in paths where entry.hasSuffix(".pte") {
                let parent = (entry as NSString).deletingLastPathComponent
                let configPath = parent.isEmpty ? "config.json" : parent + "/config.json"
                guard available.contains(configPath) else { continue }
                let config = try object(root, path: configPath)
                guard config["runtime"] as? String == "executorch", config["backend"] as? String == "xnnpack",
                      let source = config["source_model"] as? String, let family = CompiledModelFamily.from(sourceModel: source),
                      let variants = config["variants"] as? [[String: Any]],
                      let variant = variants.first(where: { $0["file"] as? String == (entry as NSString).lastPathComponent }),
                      (variant["context"] as? NSNumber)?.intValue == 2048,
                      let bytes = (variant["size_bytes"] as? NSNumber)?.int64Value, bytes > 0,
                      let hash = variant["sha256"] as? String, GGUFRangePolicy.hex(hash, count: 64) else { continue }
                let external = paths.filter { $0.hasSuffix(".ptd") && ($0 as NSString).deletingLastPathComponent == parent }
                let selected = Array(Set([entry, configPath] + companions.filter { available.contains($0) } + external)).sorted()
                candidates.append(Plan(entry: entry, family: family.rawValue, paths: selected,
                    declaredWeights: ModelFile(path: entry, bytes: bytes, sha256: hash.lowercased())))
            }
            guard candidates.count == 1 else {
                throw ModelError.unsupported("Select a folder with one Qwen3, Qwen2.5 Instruct, SmolLM2 Instruct or Llama 3.2 Instruct XNNPACK 2,048-token export, its config.json export facts, and top-level tokenizer.json. Other compiled families and backends are not supported by this adapter yet.")
            }
            return candidates[0]
        }
    }
    private func copyFile(_ input: Int32, to destination: URL) throws -> ImportedModelFile {
        var before = stat(); guard fstat(input, &before) == 0 else { throw failure("The model file cannot be inspected.") }
        let output = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard output >= 0 else { throw failure("The owned model file cannot be created.") }
        defer { Darwin.close(output) }
        let reader = FileHandle(fileDescriptor: input, closeOnDealloc: false), writer = FileHandle(fileDescriptor: output, closeOnDealloc: false)
        var hash = SHA256(), bytes: Int64 = 0
        while true {
            try check()
            let data = try reader.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            guard Int64(data.count) <= before.st_size - bytes else { throw ModelError.unsupported("A model file grew during import. Retry after it finishes changing.") }
            try writer.write(contentsOf: data); hash.update(data: data); bytes += Int64(data.count)
        }
        var after = stat()
        guard fstat(input, &after) == 0, bytes == before.st_size, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            throw ModelError.unsupported("A model file changed during import. Retry after it finishes changing.")
        }
        try writer.synchronize(); try check()
        return ImportedModelFile(bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private func failure(_ message: String) -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message]) }
}
