import Foundation

struct DirectoryStorage: Codable {
    let label: String
    var state = "complete"
    var entriesVisited = 0
    var regularFiles = 0
    var logicalBytes: Int64 = 0
    var skippedSymlinks = 0
    var errorCount = 0
}

struct StorageSnapshot: Encodable {
    let schemaVersion = 1
    let recordedAt: String
    let filesystemFreeBytes: Int64?
    let availableBytes: Int64?
    let availableForImportantUsageBytes: Int64?
    let capacityErrorDomain: String?
    let capacityErrorCode: Int?
    let directories: [DirectoryStorage]

    // Only caller-selected app-owned directories are scanned. Filenames and
    // absolute paths are deliberately absent from the attachment.
    static func directory(_ url: URL, label: String, maximumEntries: Int = 10_000) -> DirectoryStorage {
        precondition(maximumEntries > 0)
        let manager = FileManager.default
        var result = DirectoryStorage(label: label)
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        do {
            let root = try url.resourceValues(forKeys: keys)
            if root.isSymbolicLink == true {
                result.state = "root-symlink-rejected"
                result.skippedSymlinks = 1
                return result
            }
            guard root.isDirectory == true else {
                result.state = "root-not-directory"
                return result
            }
        } catch {
            let value = error as NSError
            result.state = value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoSuchFileError
                ? "missing" : "root-unreadable"
            if result.state != "missing" { result.errorCount = 1 }
            return result
        }
        var enumerationErrors = 0
        guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, _ in enumerationErrors += 1; return true }) else {
            result.state = "enumeration-unavailable"
            result.errorCount = 1
            return result
        }
        while let item = enumerator.nextObject() as? URL {
            guard result.entriesVisited < maximumEntries else {
                result.state = "entry-limit-reached"
                break
            }
            result.entriesVisited += 1
            do {
                let values = try item.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    result.skippedSymlinks += 1
                    // Foundation does not descend into symbolic links. Calling
                    // skipDescendants here can suppress the next real directory.
                } else if values.isRegularFile == true, let size = values.fileSize, size >= 0 {
                    let (total, overflow) = result.logicalBytes.addingReportingOverflow(Int64(size))
                    if overflow { result.state = "byte-count-overflow"; break }
                    result.logicalBytes = total
                    result.regularFiles += 1
                }
            } catch { result.errorCount += 1 }
        }
        result.errorCount += enumerationErrors
        if result.errorCount > 0 && result.state == "complete" { result.state = "partial-errors" }
        return result
    }

    static func capture(volumeURL: URL, directories: [(String, URL)]) -> StorageSnapshot {
        var free: Int64?, available: Int64?, important: Int64?
        var capacityError: NSError?
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: volumeURL.path)
            free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value
        } catch { capacityError = error as NSError }
        do {
            let values = try volumeURL.resourceValues(forKeys: [
                .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            available = values.volumeAvailableCapacity.map(Int64.init)
            important = values.volumeAvailableCapacityForImportantUsage
        } catch { capacityError = error as NSError }
        return StorageSnapshot(recordedAt: ISO8601DateFormatter().string(from: Date()),
            filesystemFreeBytes: free, availableBytes: available,
            availableForImportantUsageBytes: important, capacityErrorDomain: capacityError?.domain,
            capacityErrorCode: capacityError?.code,
            directories: directories.map { directory($0.1, label: $0.0) })
    }
}
