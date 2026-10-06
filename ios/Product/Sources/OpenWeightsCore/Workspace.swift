import Foundation
import Darwin

public struct WorkspaceWindow: Equatable, Sendable {
    public let text: String
    public let nextOffset: Int?
}

public struct WorkspaceSearch: Equatable, Sendable {
    public let paths: [String]
    public let partial: Bool
}

public enum WorkspaceAccess: Sendable {
    case local, coordinated, securityScoped
}

public enum WorkspaceError: LocalizedError {
    case unavailable, invalidPath, notText, invalidOffset, exists, tooLong, interrupted, cancelled
    case operation(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Choose a shared folder under Tools before using file tools."
        case .invalidPath: return "Use an ordinary relative path inside the shared folder."
        case .notText: return "This is not a readable UTF-8 text file. Ask the user to attach media instead."
        case .invalidOffset: return "The text offset must be a whole number starting at zero."
        case .exists: return "That path already exists. Replacing it requires the replace flag."
        case .tooLong: return "Keep each file write at or below 2,000 UTF-16 characters."
        case .interrupted: return "The file operation exceeded its time limit."
        case .cancelled: return "The file operation was stopped. Inspect the folder before retrying a change that had already started."
        case .operation(let message): return message
        }
    }
}

// A held directory descriptor keeps every walk rooted in the selected folder even
// if its pathname is renamed. Each descendant is opened without following links.
// External grants are opened for each operation and released when it ends.
public actor Workspace {
    private var root: Int32?
    private let rootURL: URL
    private let access: WorkspaceAccess
    private nonisolated let control = WorkspaceOperationControl()
    private var accessDepth = 0
    private var coordinatedPaths: Set<String> = []
    private let writable: Bool
    private var created: [String: Identity] = [:]
    private struct Identity: Equatable { let device: dev_t; let inode: ino_t }

    public init(root: URL, writable: Bool = true, access: WorkspaceAccess = .local) throws {
        guard root.isFileURL else { throw WorkspaceError.invalidPath }
        let opened = try Self.coordinate(root, access: access, writing: false) { url in
            let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw WorkspaceError.operation("The selected folder cannot be opened. Choose it again.") }
            return (descriptor, faccessat(descriptor, ".", W_OK, 0) == 0)
        }
        self.root = opened.0; self.rootURL = root; self.access = access
        self.writable = writable && opened.1
    }
    deinit { if let root { Darwin.close(root) } }
    public var isReady: Bool { root != nil }
    public var acceptsWrites: Bool { root != nil && writable }
    public func revoke() { if let root { Darwin.close(root) }; root = nil; created.removeAll() }
    public func clearSessionArtifacts() { created.removeAll() }
    public nonisolated func cancel() { control.cancel() }
    public func prepareTurn() { control.reset() }

    public static func segments(_ path: String) throws -> [String] {
        guard !path.isEmpty, path.utf16.count <= 1024, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains(":"), !path.contains("\0") else { throw WorkspaceError.invalidPath }
        let names = path.components(separatedBy: "/")
        guard names.count <= 12, names.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
        }) else { throw WorkspaceError.invalidPath }
        return names
    }
    public func isSessionOwned(_ path: String) -> Bool {
        (try? withAccess(writing: false) {
            guard let prior = created[path] else { return false }
            return try withItem(path) { prior == (try identity(path)) }
        }) ?? false
    }
    public func exists(_ path: String) throws -> Bool {
        try withAccess(writing: false) { try withItem(path) { try existsImpl(path) } }
    }
    public func canvasEntry(_ path: String) throws -> String {
        try withAccess(writing: false, cancellable: false) {
            try withItem(path, cancellable: false) {
                let (parent, name) = try parent(path)
                defer { Darwin.close(parent) }
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("Save the file before showing it.") }
                if info.st_mode & S_IFMT == S_IFDIR { return try canvasEntry(path + "/index.html") }
                guard info.st_mode & S_IFMT == S_IFREG else { throw WorkspaceError.invalidPath }
                return path
            }
        }
    }
    // Canvas assets include images and fonts. The descriptor walk is shared with
    // file tools, but this reader cannot decode binary data as a text tool reply.
    public func readCanvas(_ path: String) throws -> Data {
        try withAccess(writing: false, cancellable: false) {
            try withItem(path, cancellable: false) {
                let (parent, name) = try parent(path)
                defer { Darwin.close(parent) }
                let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard file >= 0 else { throw failure("The preview file cannot be opened.") }
                defer { Darwin.close(file) }
                var info = stat()
                guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_size <= 8 * 1024 * 1024 else { throw WorkspaceError.operation("Preview assets must be regular files no larger than 8 MiB.") }
                var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
                let deadline = ProcessInfo.processInfo.systemUptime + 6
                while true {
                    if Task.isCancelled { throw WorkspaceError.cancelled }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw WorkspaceError.interrupted }
                    let count = Darwin.read(file, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0 else { throw failure("The preview file could not be read.") }
                    if count == 0 { return result }
                    guard result.count + count <= 8 * 1024 * 1024 else { throw WorkspaceError.operation("Preview asset exceeded 8 MiB while being read.") }
                    result.append(contentsOf: buffer.prefix(count))
                }
            }
        }
    }
    private func existsImpl(_ path: String) throws -> Bool {
        let (parent, name) = try parent(path)
        defer { Darwin.close(parent) }
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw failure("The path cannot be inspected.")
    }
    public func read(_ path: String, offset: Int = 0, limit: Int = 4000) throws -> WorkspaceWindow {
        try withAccess(writing: false) { try withItem(path) { try readImpl(path, offset: offset, limit: limit) } }
    }
    public func readScriptInput(_ path: String, maximum: Int) throws -> String {
        guard maximum == 16 * 1024 || maximum == 20 * 1024 else { throw WorkspaceError.invalidOffset }
        return try withAccess(writing: false) {
            try withItem(path) {
                let window = try readImpl(path, offset: 0, limit: maximum, scriptInput: true)
                if maximum == 16 * 1024, window.nextOffset != nil {
                    throw WorkspaceError.operation("The saved program exceeds 16,384 UTF-16 characters. Shorten it before running.")
                }
                return window.text
            }
        }
    }
    private func readImpl(_ path: String, offset: Int, limit: Int, scriptInput: Bool = false) throws -> WorkspaceWindow {
        guard offset >= 0, limit >= 2, limit <= (scriptInput ? 20 * 1024 : 4000) else { throw WorkspaceError.invalidOffset }
        let (parent, name) = try parent(path)
        defer { Darwin.close(parent) }
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw failure("The file cannot be opened without following a symbolic link.") }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw WorkspaceError.notText }
        if Int64(offset) > info.st_size { return WorkspaceWindow(text: "", nextOffset: nil) }
        var bytes = FileBytes(file: file, deadline: ProcessInfo.processInfo.systemUptime + 6, control: control)
        var decoder = Unicode.UTF8()
        var skipped = 0, units: [UInt16] = []
        decode: while units.count <= limit {
            switch decoder.decode(&bytes) {
            case .scalarValue(let scalar):
                guard scalar.value != 0 else { throw WorkspaceError.notText }
                for unit in String(scalar).utf16 {
                    if skipped < offset { skipped += 1 }
                    else {
                        if units.isEmpty && (0xDC00...0xDFFF).contains(unit) {
                            throw WorkspaceError.operation("The offset falls inside a Unicode character. Use offset \(offset - 1).")
                        }
                        units.append(unit)
                    }
                }
            case .emptyInput: break decode
            case .error: throw bytes.error ?? WorkspaceError.notText
            }
        }
        if let error = bytes.error { throw error }
        let more = units.count > limit
        var take = min(limit, units.count)
        // A JSON tool result cannot carry an isolated UTF-16 surrogate faithfully.
        if more && take > 0 && (0xD800...0xDBFF).contains(units[take - 1]) { take -= 1 }
        return WorkspaceWindow(text: String(decoding: units.prefix(take), as: UTF16.self), nextOffset: more ? offset + take : nil)
    }
    public func write(_ path: String, content: String, replace: Bool = false) throws {
        try writeBounded(path, content: content, replace: replace, maximum: 2000)
    }
    public func saveFetchedPage(_ path: String, content: String) throws {
        guard content.utf8.count <= 512 * 1024 else { throw WorkspaceError.operation("The readable page exceeds the 512 KiB save limit.") }
        // A fetch can replace only the same inode this session created, never user notes.
        try writeBounded(path, content: content, replace: false, maximum: 512 * 1024)
    }
    private func writeBounded(_ path: String, content: String, replace: Bool, maximum: Int) throws {
        try withAccess(writing: true) {
            guard writable else { throw WorkspaceError.operation("The shared folder is read-only.") }
            guard content.utf16.count <= maximum else { throw WorkspaceError.tooLong }
            let (directory, _) = try parent(path, create: true)
            Darwin.close(directory)
            try withItem(path, writingOptions: .forReplacing) { try writeImpl(path, content: content, replace: replace, maximum: maximum) }
        }
    }
    private func writeImpl(_ path: String, content: String, replace: Bool, maximum: Int) throws {
        guard writable else { throw WorkspaceError.operation("The shared folder is read-only.") }
        guard content.utf16.count <= maximum else { throw WorkspaceError.tooLong }
        let (parent, name) = try parent(path, create: true)
        defer { Darwin.close(parent) }
        var info = stat()
        let existed = fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0
        let own = isSessionOwned(path)
        if existed {
            guard info.st_mode & S_IFMT == S_IFREG else { throw WorkspaceError.operation("Only regular files may be replaced.") }
            guard replace || own else { throw WorkspaceError.exists }
        } else if errno != ENOENT { throw failure("The destination cannot be inspected.") }
        let staging = ".openweights-\(UUID().uuidString).tmp"
        let file = openat(parent, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw failure("A staged file cannot be created.") }
        defer { Darwin.close(file); unlinkat(parent, staging, 0) }
        try Data(content.utf8).withUnsafeBytes { data in
            var position = 0
            while position < data.count {
                let count = Darwin.write(file, data.baseAddress!.advanced(by: position), data.count - position)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("The staged file could not be written. The previous file was preserved.") }
                position += count
            }
        }
        guard fsync(file) == 0 else { throw failure("The staged file could not be saved. The previous file was preserved.") }
        var staged = stat()
        guard fstat(file, &staged) == 0 else { throw failure("The staged file identity cannot be verified.") }
        try control.check()
        let result = existed && (replace || own)
            ? renameat(parent, staging, parent, name)
            : renameatx_np(parent, staging, parent, name, UInt32(RENAME_EXCL))
        guard result == 0 else { throw failure("The staged file could not be installed. The previous file was preserved.") }
        // An approved replacement of a user's file does not make it agent-owned.
        if !existed || own { created[path] = Identity(device: staged.st_dev, inode: staged.st_ino) }
    }
    public func delete(_ path: String) throws {
        try withAccess(writing: true) { try withItem(path, writingOptions: .forDeleting) { try deleteImpl(path) } }
    }
    private func deleteImpl(_ path: String) throws {
        guard writable else { throw WorkspaceError.operation("The shared folder is read-only.") }
        let (parent, name) = try parent(path)
        defer { Darwin.close(parent) }
        var visits = 0
        do {
            try remove(parent: parent, name: name, depth: 0, visits: &visits, deadline: ProcessInfo.processInfo.systemUptime + 6)
            created = created.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        } catch {
            throw WorkspaceError.operation("Deletion did not finish. Some entries may already have been removed. \(error.localizedDescription)")
        }
    }
    public func find(pattern: String, contains: String? = nil) throws -> WorkspaceSearch {
        try withAccess(writing: false) { try findImpl(pattern: pattern, contains: contains) }
    }
    private func findImpl(pattern: String, contains: String?) throws -> WorkspaceSearch {
        guard let root else { throw WorkspaceError.unavailable }
        guard !pattern.isEmpty else { throw WorkspaceError.operation("Give a file name or pattern such as *.md.") }
        var matches: [String] = [], visits = 0, partial = false
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        try walk(root, prefix: "", depth: 0, pattern: pattern, contains: contains,
                 matches: &matches, visits: &visits, partial: &partial, deadline: deadline)
        return WorkspaceSearch(paths: matches, partial: partial)
    }

    private func withAccess<T>(writing: Bool, cancellable: Bool = true, operation: () throws -> T) throws -> T {
        guard let root else { throw WorkspaceError.unavailable }
        if cancellable { try control.check() }
        if accessDepth > 0 { return try operation() }
        return try Self.coordinate(rootURL, access: access, writing: writing, control: cancellable ? control : nil) { coordinatedURL in
            if cancellable { try control.check() }
            if access != .local {
                let current = Darwin.open(coordinatedURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard current >= 0 else { throw WorkspaceError.unavailable }
                defer { Darwin.close(current) }
                var held = stat(), resolved = stat()
                guard fstat(root, &held) == 0, fstat(current, &resolved) == 0,
                      held.st_dev == resolved.st_dev, held.st_ino == resolved.st_ino else {
                    throw WorkspaceError.operation("The shared folder changed. Choose it again before running tools.")
                }
            }
            accessDepth += 1
            defer { accessDepth -= 1 }
            return try operation()
        }
    }
    private static func coordinate<T>(_ url: URL, access: WorkspaceAccess, writing: Bool,
                                      control: WorkspaceOperationControl? = nil,
                                      writingOptions: NSFileCoordinator.WritingOptions = [],
                                      operation: (URL) throws -> T) throws -> T {
        if access == .local { return try operation(url) }
        if access == .securityScoped && !url.startAccessingSecurityScopedResource() {
            throw WorkspaceError.operation("Access to the shared folder was withdrawn. Choose it again under Tools.")
        }
        defer { if access == .securityScoped { url.stopAccessingSecurityScopedResource() } }
        // Root coordination protects grant identity and root-level namespace changes.
        // Child contents get their own coordination in withItem.
        let coordinator = NSFileCoordinator()
        control?.bind(coordinator)
        defer { control?.unbind(coordinator) }
        try control?.check()
        var error: NSError?, result: Result<T, Error>?
        let accessor: (URL) -> Void = { coordinatedURL in result = Result { try operation(coordinatedURL) } }
        if writing { coordinator.coordinate(writingItemAt: url, options: writingOptions, error: &error, byAccessor: accessor) }
        else { coordinator.coordinate(readingItemAt: url, options: [], error: &error, byAccessor: accessor) }
        if let error { throw error }
        guard let result else { throw WorkspaceError.operation("The shared folder could not be coordinated.") }
        return try result.get()
    }

    private func withItem<T>(_ path: String, cancellable: Bool = true, writingOptions: NSFileCoordinator.WritingOptions? = nil,
                             expectedDescriptor: Int32? = nil, operation: () throws -> T) throws -> T {
        let names = try Self.segments(path)
        if access == .local || coordinatedPaths.contains(path) { return try operation() }
        let (directory, name) = try parent(path)
        defer { Darwin.close(directory) }
        var info = stat()
        let present = fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0
        if present && info.st_mode & S_IFMT == S_IFLNK {
            throw WorkspaceError.operation("File-provider tools cannot follow a symbolic link. Use Files to manage the link itself.")
        }
        if !present && errno != ENOENT { throw failure("The coordinated item cannot be inspected.") }
        let target = names.reduce(rootURL) { $0.appendingPathComponent($1) }
        return try Self.coordinate(target, access: .coordinated, writing: writingOptions != nil,
                                   control: cancellable ? control : nil, writingOptions: writingOptions ?? []) { coordinatedURL in
            if cancellable { try control.check() }
            guard coordinatedURL.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path else {
                throw WorkspaceError.operation("The coordinated file moved. Find its current path before trying again.")
            }
            if let expectedDescriptor {
                var held = stat(), current = stat()
                guard fstat(expectedDescriptor, &held) == 0,
                      fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      held.st_dev == current.st_dev, held.st_ino == current.st_ino else {
                    throw WorkspaceError.operation("The directory changed while it was being listed. Try a fresh search.")
                }
            }
            coordinatedPaths.insert(path)
            defer { coordinatedPaths.remove(path) }
            return try operation()
        }
    }

    private func parent(_ path: String, create: Bool = false) throws -> (Int32, String) {
        guard let root else { throw WorkspaceError.unavailable }
        let names = try Self.segments(path)
        var descriptor = dup(root)
        guard descriptor >= 0 else { throw failure("The shared folder cannot be accessed.") }
        do {
            for (index, name) in names.dropLast().enumerated() {
                if create {
                    var info = stat()
                    if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) < 0 && errno == ENOENT {
                        let make = {
                            try self.control.check()
                            if mkdirat(descriptor, name, 0o700) < 0 && errno != EEXIST { throw self.failure("A parent folder cannot be created.") }
                        }
                        if index == 0 { try make() }
                        else { try withItem(names.prefix(index).joined(separator: "/"), writingOptions: [], expectedDescriptor: descriptor, operation: make) }
                    }
                }
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw failure("A parent folder is unavailable or is a symbolic link.") }
                Darwin.close(descriptor); descriptor = child
            }
            return (descriptor, names.last!)
        } catch { Darwin.close(descriptor); throw error }
    }
    private func identity(_ path: String) throws -> Identity {
        let (parent, name) = try parent(path)
        defer { Darwin.close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw failure("The file identity cannot be verified.")
        }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }
    private func names(_ descriptor: Int32) throws -> [String] {
        let fresh = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fresh >= 0 else { throw failure("The directory cannot be listed.") }
        guard let directory = fdopendir(fresh) else { Darwin.close(fresh); throw failure("The directory cannot be listed.") }
        defer { closedir(directory) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
            // Listing itself is bounded, including directories with no matching files.
            if result.count > 10000 { throw WorkspaceError.operation("This directory has too many entries to list in one operation.") }
            errno = 0
        }
        guard errno == 0 else { throw failure("The directory listing was interrupted.") }
        return result.sorted()
    }
    private func walk(_ descriptor: Int32, prefix: String, depth: Int, pattern: String, contains: String?,
                      matches: inout [String], visits: inout Int, partial: inout Bool, deadline: Double) throws {
        guard depth <= 6 else { partial = true; return }
        let entries = prefix.isEmpty ? try names(descriptor) : try withItem(prefix, expectedDescriptor: descriptor) { try names(descriptor) }
        for name in entries {
            try control.check()
            guard visits < 400, matches.count < 10, ProcessInfo.processInfo.systemUptime < deadline else { partial = true; return }
            visits += 1
            let path = prefix.isEmpty ? name : prefix + "/" + name
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { partial = true; continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { partial = true; continue }
                defer { Darwin.close(child) }
                try walk(child, prefix: path, depth: depth + 1, pattern: pattern, contains: contains,
                         matches: &matches, visits: &visits, partial: &partial, deadline: deadline)
            } else if info.st_mode & S_IFMT == S_IFREG && Self.matches(name, pattern: pattern) {
                if let contains {
                    guard info.st_size <= 1024 * 1024 else { continue }
                    guard let window = try? read(path), window.text.range(of: contains, options: .caseInsensitive) != nil else { continue }
                }
                matches.append(path)
            }
        }
    }
    private func remove(parent: Int32, name: String, depth: Int, visits: inout Int, deadline: Double) throws {
        try control.check()
        guard depth <= 64, visits < 10000, ProcessInfo.processInfo.systemUptime < deadline else { throw WorkspaceError.interrupted }
        visits += 1
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("The entry cannot be inspected.") }
        if info.st_mode & S_IFMT == S_IFDIR {
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw failure("The directory cannot be opened without following links.") }
            defer { Darwin.close(child) }
            for name in try names(child) { try remove(parent: child, name: name, depth: depth + 1, visits: &visits, deadline: deadline) }
            try control.check()
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw failure("The directory cannot be removed.") }
        } else {
            // Unlinking a link removes the link itself, never its destination.
            guard unlinkat(parent, name, 0) == 0 else { throw failure("The file cannot be removed.") }
        }
    }
    static func matches(_ name: String, pattern: String) -> Bool {
        if !pattern.contains("*") && !pattern.contains("?") { return name.range(of: pattern, options: .caseInsensitive) != nil }
        let p = Array(pattern.lowercased()), value = Array(name.lowercased())
        var pi = 0, vi = 0, star: Int?, after = 0
        while vi < value.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == value[vi]) { pi += 1; vi += 1 }
            else if pi < p.count && p[pi] == "*" { star = pi; pi += 1; after = vi }
            else if let star { after += 1; vi = after; pi = star + 1 }
            else { return false }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
    private func failure(_ message: String) -> WorkspaceError {
        .operation(message + " " + String(cString: strerror(errno)))
    }
}

private struct FileBytes: IteratorProtocol {
    let file: Int32
    let deadline: Double
    let control: WorkspaceOperationControl
    var error: WorkspaceError?
    private var buffer = [UInt8](repeating: 0, count: 8192)
    private var position = 0, count = 0
    init(file: Int32, deadline: Double, control: WorkspaceOperationControl) { self.file = file; self.deadline = deadline; self.control = control }
    mutating func next() -> UInt8? {
        if position == count {
            do { try control.check() } catch { self.error = .cancelled; return nil }
            guard ProcessInfo.processInfo.systemUptime < deadline else { error = .interrupted; return nil }
            repeat { count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) } } while count < 0 && errno == EINTR
            if count < 0 { error = .operation("The file read failed."); return nil }
            guard count > 0 else { return nil }
            position = 0
        }
        defer { position += 1 }
        return buffer[position]
    }
}

private final class WorkspaceOperationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var coordinators: [NSFileCoordinator] = []
    func check() throws { if lock.withLock({ stopped }) { throw WorkspaceError.cancelled } }
    func reset() { lock.withLock { if coordinators.isEmpty { stopped = false } } }
    func bind(_ value: NSFileCoordinator) {
        let stop = lock.withLock { coordinators.append(value); return stopped }
        if stop { value.cancel() }
    }
    func unbind(_ value: NSFileCoordinator) { lock.withLock { coordinators.removeAll { $0 === value } } }
    func cancel() {
        let values = lock.withLock { stopped = true; return coordinators }
        values.forEach { $0.cancel() }
    }
}
