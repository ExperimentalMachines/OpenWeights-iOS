import CryptoKit
import Darwin
import Foundation

public struct ImportedModelFile: Equatable, Sendable {
    public let bytes: Int64
    public let sha256: String
}

public enum ModelImport {
    public static func copyGGUF(from source: URL, to destination: URL,
                                access: WorkspaceAccess = .local) async throws -> ImportedModelFile {
        let operation = ModelImportOperation()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try operation.copy(source: source, destination: destination, access: access)
            }.value
        } onCancel: { operation.cancel() }
    }
}

private final class ModelImportOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var coordinator: NSFileCoordinator?

    func cancel() {
        let active = lock.withLock { cancelled = true; return coordinator }
        active?.cancel()
    }
    private func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
    func copy(source: URL, destination: URL, access: WorkspaceAccess) throws -> ImportedModelFile {
        try check()
        guard source.isFileURL, destination.isFileURL, source.pathExtension.lowercased() == "gguf" else {
            throw ModelError.unsupported("Select a regular GGUF file.")
        }
        if access == .securityScoped && !source.startAccessingSecurityScopedResource() {
            throw ModelError.unsupported("Access to this model file expired. Select it again in Files.")
        }
        defer { if access == .securityScoped { source.stopAccessingSecurityScopedResource() } }
        // Refuse a leaf link before a provider is asked to coordinate its target.
        guard try FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType == .typeRegular else {
            throw ModelError.unsupported("Import a regular GGUF file. Links and folders cannot be owned model copies.")
        }
        if access == .local { return try copyFile(source, destination: destination) }
        let active = NSFileCoordinator(filePresenter: nil)
        try lock.withLock {
            if cancelled { throw CancellationError() }
            coordinator = active
        }
        defer { lock.withLock { coordinator = nil } }
        var outcome: Result<ImportedModelFile, Error>?
        var error: NSError?
        active.coordinate(readingItemAt: source, options: [], error: &error) { coordinated in
            outcome = Result { try self.check(); return try self.copyFile(coordinated, destination: destination) }
        }
        if let outcome { return try outcome.get() }
        try check()
        if let error { throw error }
        throw ModelError.unsupported("The file provider could not make this model available. Select it again.")
    }
    private func copyFile(_ source: URL, destination: URL) throws -> ImportedModelFile {
        try check()
        // The descriptor stays on the inspected file if its path is replaced during copying.
        let inputFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard inputFD >= 0 else { throw posix("The selected model cannot be opened.") }
        defer { Darwin.close(inputFD) }
        var before = stat()
        guard fstat(inputFD, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 4 else {
            throw ModelError.corrupt(source.lastPathComponent)
        }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: false)
        guard let first = try input.read(upToCount: 1024 * 1024), first.starts(with: Data("GGUF".utf8)) else {
            throw ModelError.corrupt(source.lastPathComponent)
        }
        try check()
        let outputFD = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard outputFD >= 0 else { throw posix("The owned model copy cannot be created.") }
        var committed = false
        defer {
            Darwin.close(outputFD)
            if !committed { try? FileManager.default.removeItem(at: destination) }
        }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: false)
        var hash = SHA256()
        var copied: Int64 = 0
        var chunk = first
        while !chunk.isEmpty {
            try check()
            guard Int64(chunk.count) <= before.st_size - copied else {
                throw ModelError.unsupported("The source model grew during import. Select it again after it finishes changing.")
            }
            try output.write(contentsOf: chunk)
            hash.update(data: chunk)
            copied += Int64(chunk.count)
            chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
        }
        var after = stat()
        guard fstat(inputFD, &after) == 0, copied == before.st_size, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            throw ModelError.unsupported("The source model changed during import. Select it again after it finishes changing.")
        }
        try output.synchronize()
        try check()
        committed = true
        return ImportedModelFile(bytes: copied, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private func posix(_ message: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
