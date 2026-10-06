import CryptoKit
import Foundation

public struct ModelDownloadArrival: Codable, Sendable {
    public let version: Int
    public let owner: UUID
    public let nonce: UUID
    public let modelID: UUID
    public let filePath: String
    public let requestURLSHA256: String
    public let offset: Int64
    public let status: Int
    public let contentRange: String?
    private var stem: String { "arrival-" + owner.uuidString + "-" + nonce.uuidString }
    public static func urlIdentity(_ url: URL) -> String {
        // Persist request identity without copying query credentials or headers.
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func stage(_ temporary: URL, directory: URL, owner: UUID, modelID: UUID,
                             filePath: String, requestURL: URL, offset: Int64, status: Int, contentRange: String?) throws -> URL {
        try ModelFile.validatePath(filePath)
        guard offset >= 0, status == 200 || status == 206 else { throw ModelError.corrupt(filePath) }
        let arrival = Self(version: 1, owner: owner, nonce: UUID(), modelID: modelID, filePath: filePath,
            requestURLSHA256: urlIdentity(requestURL), offset: offset, status: status, contentRange: contentRange)
        let destination = try ModelFile(path: filePath).destination(in: directory)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = directory.appendingPathComponent(arrival.stem + ".data")
        try FileManager.default.moveItem(at: temporary, to: body)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(arrival).write(to: body.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
        } catch { try? FileManager.default.removeItem(at: body); throw error }
        return body
    }
    public static func discard(_ body: URL) throws {
        if FileManager.default.fileExists(atPath: body.path) { try FileManager.default.removeItem(at: body) }
        let manifest = body.deletingPathExtension().appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: manifest.path) { try FileManager.default.removeItem(at: manifest) }
    }
    private static func namespaced(_ name: String) -> Bool {
        guard name.hasPrefix("arrival-") else { return false }
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let value = String(stem.dropFirst(8))
        guard value.count == 73 else { return false }
        let separator = value.index(value.startIndex, offsetBy: 36)
        return value[separator] == "-" && UUID(uuidString: String(value.prefix(36))) != nil && UUID(uuidString: String(value.suffix(36))) != nil
    }
    private static func regular(_ url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw ModelError.invalidPath(url.lastPathComponent)
        }
    }
    @discardableResult public static func recover(in directory: URL, model: LocalModel, excludingOwner: UUID) throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let currentPrefix = "arrival-" + excludingOwner.uuidString + "-"
        var recovered = 0
        // A current-process stage may be waiting in the delegate queue. Never
        // steal or clean it while scene/background bootstrap is reconciling tasks.
        let protected = Set(model.files.map(\.path))
        let manifests = names.filter { namespaced($0) && $0.hasSuffix(".json") && !$0.hasPrefix(currentPrefix)
            && !protected.contains($0) && !protected.contains(URL(fileURLWithPath: $0).deletingPathExtension().appendingPathExtension("data").lastPathComponent) }
        var pending: [(URL, Self)] = []
        for name in manifests {
            let manifest = directory.appendingPathComponent(name), body = manifest.deletingPathExtension().appendingPathExtension("data")
            guard model.state == .downloading else { try discard(body); continue }
            do {
                try regular(manifest)
                guard try ModelFileTransfer.byteCount(manifest) <= 16 * 1024 else { throw ModelError.corrupt(name) }
                let arrival = try JSONDecoder().decode(Self.self, from: Data(contentsOf: manifest))
                guard arrival.version == 1, name == arrival.stem + ".json", arrival.modelID == model.id,
                      arrival.offset >= 0, arrival.status == 200 || arrival.status == 206 else { throw ModelError.corrupt(name) }
                pending.append((body, arrival))
            } catch { try? discard(body); throw error }
        }
        // UUID filenames do not express range order. Earlier chunks must recover
        // first when more than one completed callback survived process exit.
        pending.sort { $0.1.filePath == $1.1.filePath ? $0.1.offset < $1.1.offset : $0.1.filePath < $1.1.filePath }
        for (body, arrival) in pending {
            defer { try? discard(body) }
            guard let file = model.files.first(where: { $0.path == arrival.filePath }), let url = file.url,
                  urlIdentity(url) == arrival.requestURLSHA256 else { throw ModelError.corrupt(arrival.filePath) }
            let destination = try file.destination(in: directory)
            if FileManager.default.fileExists(atPath: destination.path) {
                try ModelFileTransfer.verify(destination, file: file)
                recovered += 1; continue
            }
            try regular(body)
            try ModelFileTransfer.recoverChunk(body, destination: destination, status: arrival.status,
                contentRange: arrival.contentRange, offset: arrival.offset, file: file)
            recovered += 1
        }
        // A crash can occur between moving the body and publishing its manifest.
        // Old unjournaled stages cannot be attributed to a file/range safely.
        for name in names where !name.hasPrefix(currentPrefix) {
            let legacy = name.hasPrefix("arrival-") && UUID(uuidString: String(name.dropFirst(8))) != nil
            let orphan = namespaced(name) && name.hasSuffix(".data") && !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).deletingPathExtension().appendingPathExtension("json").path)
            if (legacy || orphan), !model.files.contains(where: { $0.path == name }),
               FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        return recovered
    }
}
