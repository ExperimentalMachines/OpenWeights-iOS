import CryptoKit
import Foundation

public enum ModelFileTransfer {
    public static func byteCount(_ url: URL) throws -> Int64 {
        // URL resource values can cache the size observed before an append.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw ModelError.corrupt(url.lastPathComponent) }
        return size.int64Value
    }
    public static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var value = SHA256()
        // Foundation's read buffers can remain autoreleased for an entire executor
        // job. Drain each chunk before multi-gigabyte verification allocates more.
        while true {
            let hasBytes = try autoreleasepool { () -> Bool in
                guard let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else { return false }
                value.update(data: chunk)
                return true
            }
            if !hasBytes { break }
        }
        return value.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ url: URL, file: ModelFile) throws {
        if let bytes = file.bytes {
            guard try byteCount(url) == bytes else { throw ModelError.corrupt(file.path) }
        }
        if let expected = file.sha256, try hash(url) != expected { throw ModelError.corrupt(file.path) }
        if let expected = file.gitBlobSHA1 {
            let bytes = try byteCount(url)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // Regular Hub files use Git's object ID, including the blob header.
            // LFS blob IDs identify pointer files and must not verify weight bytes.
            var hash = Insecure.SHA1()
            hash.update(data: Data("blob \(bytes)\0".utf8))
            while true {
                let hasBytes = try autoreleasepool { () -> Bool in
                    guard let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else { return false }
                    hash.update(data: chunk)
                    return true
                }
                if !hasBytes { break }
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw ModelError.corrupt(file.path) }
        }
    }

    public static func verify(_ data: Data, file: ModelFile) throws {
        guard file.bytes == nil || file.bytes == Int64(data.count) else { throw ModelError.corrupt(file.path) }
        if let expected = file.sha256, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() != expected {
            throw ModelError.corrupt(file.path)
        }
        if let expected = file.gitBlobSHA1 {
            var hash = Insecure.SHA1(); hash.update(data: Data("blob \(data.count)\0".utf8)); hash.update(data: data)
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw ModelError.corrupt(file.path) }
        }
    }

    public static func commitChunk(_ staged: URL, destination: URL, status: Int,
                                   contentRange: String?, offset: Int64, file: ModelFile) throws {
        try applyChunk(staged, destination: destination, status: status, contentRange: contentRange,
            offset: offset, file: file, recoverWrittenPrefix: false)
    }
    public static func recoverChunk(_ staged: URL, destination: URL, status: Int,
                                    contentRange: String?, offset: Int64, file: ModelFile) throws {
        try applyChunk(staged, destination: destination, status: status, contentRange: contentRange,
            offset: offset, file: file, recoverWrittenPrefix: true)
    }
    private static func applyChunk(_ staged: URL, destination: URL, status: Int,
                                   contentRange: String?, offset: Int64, file: ModelFile, recoverWrittenPrefix: Bool) throws {
        defer { try? FileManager.default.removeItem(at: staged) }
        let partial = destination.appendingPathExtension("partial")
        if status == 206 {
            guard let header = contentRange, header.hasPrefix("bytes ") else { throw ModelError.corrupt(file.path) }
            let components = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 2, let total = Int64(components[1]), total > 0,
                  file.bytes == nil || file.bytes == total else { throw ModelError.corrupt(file.path) }
            let bounds = components[0].split(separator: "-", omittingEmptySubsequences: false)
            guard offset >= 0, bounds.count == 2, Int64(bounds[0]) == offset,
                  let end = Int64(bounds[1]), end >= offset, end < total,
                  try byteCount(staged) == end - offset + 1 else {
                throw ModelError.corrupt(file.path)
            }
            let stored = (try? byteCount(partial)) ?? 0
            guard stored == offset || (recoverWrittenPrefix && stored >= offset && stored <= total) else {
                throw ModelError.unsupported("Download checkpoint changed. Retry the model download.")
            }
            let overlap = recoverWrittenPrefix ? min(stored - offset, end - offset + 1) : 0
            if overlap > 0 {
                let checkpoint = try FileHandle(forReadingFrom: partial)
                defer { try? checkpoint.close() }
                let arrival = try FileHandle(forReadingFrom: staged)
                defer { try? arrival.close() }
                try checkpoint.seek(toOffset: UInt64(offset))
                var remaining = overlap
                while remaining > 0 {
                    let count = Int(min(remaining, 1024 * 1024))
                    guard let left = try checkpoint.read(upToCount: count), let right = try arrival.read(upToCount: count),
                          left.count == count, right.count == count, left == right else {
                        throw ModelError.unsupported("The interrupted download prefix does not match its saved arrival. Retry the model download.")
                    }
                    remaining -= Int64(count)
                }
            }
            if !FileManager.default.fileExists(atPath: partial.path) {
                guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw ModelError.corrupt(file.path) }
            }
            let input = try FileHandle(forReadingFrom: staged)
            defer { try? input.close() }
            try input.seek(toOffset: UInt64(overlap))
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            try output.seekToEnd()
            while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty { try output.write(contentsOf: bytes) }
            try output.synchronize()
            if try byteCount(partial) == total {
                do { try verify(partial, file: file) }
                catch {
                    // A complete corrupt checkpoint cannot be repaired by appending more bytes.
                    try? FileManager.default.removeItem(at: partial)
                    throw error
                }
                try FileManager.default.moveItem(at: partial, to: destination)
            }
        } else if status == 200 {
            // Some servers ignore Range. Verify the whole response before replacing the checkpoint.
            try verify(staged, file: file)
            if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
            try FileManager.default.moveItem(at: staged, to: destination)
        } else { throw ModelError.unsupported("Hugging Face returned an unsuccessful download response.") }
    }
}
