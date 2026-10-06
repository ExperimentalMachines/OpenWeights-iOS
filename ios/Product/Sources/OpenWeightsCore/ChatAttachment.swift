import Foundation
import CryptoKit
import Darwin

public struct ChatAttachment: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, audio, video }
    public let id: UUID
    public let name: String
    public let mediaType: String
    public let bytes: Int64
    public let sha256: String
    public let kind: Kind
    public var fileName: String { id.uuidString.lowercased() + (kind == .image ? ".jpg" : kind == .audio ? ".wav" : ".video") }
    public init(id: UUID, name: String, mediaType: String, bytes: Int64, sha256: String, kind: Kind) {
        self.id = id; self.name = name; self.mediaType = mediaType; self.bytes = bytes; self.sha256 = sha256; self.kind = kind
    }
}

public struct AttachmentDocumentInfo: Codable, Equatable, Sendable {
    public var name: String
    public var characters: Int
    public var wasTrimmed: Bool
}
public struct StagedAttachmentDocument: Equatable, Sendable {
    public let info: AttachmentDocumentInfo
    public let text: String
    public var prompt: String {
        "Document: " + info.name + "\n\"\"\"\n" + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" +
            (info.wasTrimmed ? "[cut short: the rest did not fit]\n" : "") + "\"\"\"\n\n"
    }
}

public enum AttachmentError: LocalizedError {
    case unavailable, tooLarge(Int64), corrupt, invalidText, emptyDocument
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "The attachment cannot be accessed. Select it again."
        case .tooLarge(let bytes): return "Choose an attachment smaller than " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + "."
        case .corrupt: return "This saved attachment is missing or changed. Remove it or attach a fresh copy."
        case .invalidText: return "Select a UTF-8 text, JSON or XML document."
        case .emptyDocument: return "This document has no readable text in the available context."
        }
    }
}

public actor ChatAttachmentStore {
    public nonisolated let root: URL
    public static let mediaByteLimit: Int64 = 128 * 1024 * 1024
    public static let videoByteLimit: Int64 = 1024 * 1024 * 1024
    public init(root: URL) throws {
        if FileManager.default.fileExists(atPath: root.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw AttachmentError.unavailable }
        } else { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
    }
    public func importFile(_ source: URL, name: String? = nil, mediaType: String, kind: ChatAttachment.Kind,
                           access: WorkspaceAccess = .local) async throws -> ChatAttachment {
        let id = UUID(), limit = kind == .video ? Self.videoByteLimit : Self.mediaByteLimit
        let description = ChatAttachment(id: id, name: Self.displayName(name ?? source.lastPathComponent), mediaType: mediaType,
                                         bytes: 0, sha256: "", kind: kind)
        let target = try ownedURL(description)
        let copied = try await AttachmentFileCopy.copy(source, to: target, limit: limit, access: access)
        return ChatAttachment(id: id, name: description.name, mediaType: mediaType, bytes: copied.bytes, sha256: copied.sha256, kind: kind)
    }
    public func resolve(_ attachment: ChatAttachment) throws -> URL {
        guard attachment.bytes > 0, attachment.bytes <= (attachment.kind == .video ? Self.videoByteLimit : Self.mediaByteLimit),
              GGUFRangePolicy.hex(attachment.sha256, count: 64) else { throw AttachmentError.corrupt }
        let url = try ownedURL(attachment)
        let actual = try AttachmentFileCopy.fingerprint(url, limit: attachment.bytes)
        guard actual.bytes == attachment.bytes, actual.sha256 == attachment.sha256 else { throw AttachmentError.corrupt }
        return url
    }
    public func discard(_ attachments: [ChatAttachment]) throws {
        for attachment in attachments { let url = try ownedURL(attachment); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
    }
    public func prune(keeping ids: Set<UUID>) throws {
        try checkRoot()
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard ["jpg", "wav", "video"].contains(url.pathExtension), let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !ids.contains(id) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
    public nonisolated func displayURL(_ attachment: ChatAttachment) -> URL { root.appendingPathComponent(attachment.fileName) }
    private func ownedURL(_ attachment: ChatAttachment) throws -> URL { try checkRoot(); return displayURL(attachment) }
    private func checkRoot() throws {
        guard (try? FileManager.default.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType) == .typeDirectory else { throw AttachmentError.unavailable }
    }
    public static func displayName(_ name: String) -> String {
        let value = name.filter { !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
        return String(value.prefix(200)).isEmpty ? "Attachment" : String(value.prefix(200))
    }
    public nonisolated static func readDocument(_ source: URL, characterLimit: Int, access: WorkspaceAccess = .local) async throws -> StagedAttachmentDocument {
        let limit = min(1_000_000, max(0, characterLimit))
        guard limit > 0 else { throw AttachmentError.emptyDocument }
        let operation = AttachmentReadOperation()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                let data = try operation.read(source, byteLimit: limit * 4 + 4, access: access)
                let raw = data.0
                var text = String(data: raw, encoding: .utf8)
                // A bounded read can end inside a UTF-8 scalar. Only trim that final fragment.
                if text == nil && data.1 {
                    for count in 1...min(3, raw.count) where text == nil { text = String(data: raw.dropLast(count), encoding: .utf8) }
                }
                guard var text else { throw AttachmentError.invalidText }
                if text.first == "\u{feff}" { text.removeFirst() }
                guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw AttachmentError.invalidText }
                let trimmed = data.1 || text.count > limit
                text = String(text.prefix(limit))
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AttachmentError.emptyDocument }
                return StagedAttachmentDocument(info: AttachmentDocumentInfo(name: displayName(source.lastPathComponent), characters: text.count, wasTrimmed: trimmed), text: text)
            }.value
        } onCancel: { operation.cancel() }
    }
}

public enum AttachmentFileCopy {
    public static func copy(_ source: URL, to target: URL, limit: Int64, access: WorkspaceAccess = .local) async throws -> ImportedModelFile {
        let operation = AttachmentReadOperation()
        return try await withTaskCancellationHandler {
            try await Task.detached { try operation.copy(source, target: target, limit: limit, access: access) }.value
        } onCancel: { operation.cancel() }
    }
    static func fingerprint(_ url: URL, limit: Int64) throws -> ImportedModelFile {
        try AttachmentReadOperation().fingerprint(url, limit: limit)
    }
}

private final class AttachmentReadOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var coordinator: NSFileCoordinator?
    func cancel() { let value = lock.withLock { cancelled = true; return coordinator }; value?.cancel() }
    private func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
    private func access<T>(_ source: URL, mode: WorkspaceAccess, body: (URL) throws -> T) throws -> T {
        try check(); guard source.isFileURL else { throw AttachmentError.unavailable }
        if mode == .securityScoped && !source.startAccessingSecurityScopedResource() { throw AttachmentError.unavailable }
        defer { if mode == .securityScoped { source.stopAccessingSecurityScopedResource() } }
        if mode == .local { return try body(source) }
        let value = NSFileCoordinator(); lock.withLock { coordinator = value }
        defer { lock.withLock { coordinator = nil } }
        var result: Result<T, Error>?, error: NSError?
        value.coordinate(readingItemAt: source, options: [.withoutChanges], error: &error) { coordinatedURL in result = Result { try body(coordinatedURL) } }
        try check(); if let result { return try result.get() }; if let error { throw error }; throw AttachmentError.unavailable
    }
    private func open(_ source: URL) throws -> (Int32, stat) {
        let fd = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw AttachmentError.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { Darwin.close(fd); throw AttachmentError.unavailable }
        return (fd, info)
    }
    private func unchanged(_ fd: Int32, before: stat) throws {
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw AttachmentError.corrupt }
    }
    func copy(_ source: URL, target: URL, limit: Int64, access mode: WorkspaceAccess) throws -> ImportedModelFile {
        try access(source, mode: mode) { url in
            let (fd, before) = try open(url); defer { Darwin.close(fd) }
            guard before.st_size > 0, before.st_size <= limit else { throw AttachmentError.tooLarge(limit) }
            let outputFD = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard outputFD >= 0 else { throw AttachmentError.unavailable }
            var committed = false
            defer { Darwin.close(outputFD); if !committed { try? FileManager.default.removeItem(at: target) } }
            let input = FileHandle(fileDescriptor: fd, closeOnDealloc: false), output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: false)
            var hash = SHA256(), bytes: Int64 = 0
            while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try check(); guard Int64(chunk.count) <= limit - bytes else { throw AttachmentError.tooLarge(limit) }
                try output.write(contentsOf: chunk); hash.update(data: chunk); bytes += Int64(chunk.count)
            }
            try unchanged(fd, before: before); try output.synchronize(); try check()
            guard bytes == before.st_size else { throw AttachmentError.corrupt }
            committed = true
            return ImportedModelFile(bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }
    func fingerprint(_ url: URL, limit: Int64) throws -> ImportedModelFile {
        let (fd, before) = try open(url); defer { Darwin.close(fd) }
        guard before.st_size > 0, before.st_size <= limit else { throw AttachmentError.corrupt }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false); var hash = SHA256(), bytes: Int64 = 0
        while let data = try file.read(upToCount: 256 * 1024), !data.isEmpty {
            guard Int64(data.count) <= limit - bytes else { throw AttachmentError.corrupt }
            hash.update(data: data); bytes += Int64(data.count)
        }
        try unchanged(fd, before: before)
        return ImportedModelFile(bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    func read(_ source: URL, byteLimit: Int, access mode: WorkspaceAccess) throws -> (Data, Bool) {
        try access(source, mode: mode) { url in
            let (fd, before) = try open(url); defer { Darwin.close(fd) }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            var data = Data()
            while data.count < byteLimit, let chunk = try file.read(upToCount: min(64 * 1024, byteLimit - data.count)), !chunk.isEmpty {
                try check(); data.append(chunk)
            }
            try unchanged(fd, before: before); try check()
            return (data, before.st_size > data.count)
        }
    }
}
