import Foundation

@main
struct StorageSnapshotHostChecks {
    enum Failure: Error { case check(String) }
    static func require(_ value: Bool, _ name: String) throws {
        if !value { throw Failure.check(name) }
    }

    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let owned = root.appendingPathComponent("owned")
        let outside = root.appendingPathComponent("outside")
        try manager.createDirectory(at: owned.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let first = owned.appendingPathComponent("sensitive-filename")
        let nested = owned.appendingPathComponent("nested/.hidden")
        let external = outside.appendingPathComponent("external")
        try Data(repeating: 1, count: 3).write(to: first)
        try Data(repeating: 2, count: 7).write(to: nested)
        try Data(repeating: 3, count: 100).write(to: external)

        let measured = StorageSnapshot.directory(owned, label: "owned")
        try require(measured.state == "complete" && measured.logicalBytes == 10
            && measured.regularFiles == 2, "nested and hidden file sizes")
        try require(try Data(contentsOf: first) == Data(repeating: 1, count: 3)
            && Data(contentsOf: nested) == Data(repeating: 2, count: 7), "read-only file preservation")

        let rootLink = root.appendingPathComponent("root-link")
        try manager.createSymbolicLink(at: rootLink, withDestinationURL: outside)
        let rejected = StorageSnapshot.directory(rootLink, label: "root-link")
        try require(rejected.state == "root-symlink-rejected" && rejected.logicalBytes == 0,
                    "root symlink refusal")

        try manager.createSymbolicLink(at: owned.appendingPathComponent("escape"), withDestinationURL: outside)
        let bounded = StorageSnapshot.directory(owned, label: "owned")
        try require(bounded.logicalBytes == 10 && bounded.regularFiles == 2
            && bounded.skippedSymlinks == 1, "descendant symlink refusal: \(bounded)")

        let limited = StorageSnapshot.directory(owned, label: "owned", maximumEntries: 1)
        try require(limited.state == "entry-limit-reached" && limited.entriesVisited == 1,
                    "bounded enumeration reports truncation")

        let missing = root.appendingPathComponent("missing")
        try require(StorageSnapshot.directory(missing, label: "missing").state == "missing",
                    "missing root distinguished from inaccessible root")
        let snapshot = StorageSnapshot.capture(volumeURL: missing, directories: [("owned", owned)])
        try require(snapshot.availableBytes == nil && snapshot.availableForImportantUsageBytes == nil
            && snapshot.capacityErrorDomain != nil, "unknown capacity is not measured zero")
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        try require(!encoded.contains(root.path) && !encoded.contains("sensitive-filename")
            && !encoded.contains("external"), "attachment omits paths and filenames")
        print("8 storage controls passed. Temporary fixture removed after read-only measurements.")
    }
}
