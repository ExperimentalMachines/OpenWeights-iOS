import Foundation
import CryptoKit
import ImageIO

public actor MediaPreviewCache {
    public static let maximumBody = 524_288
    public static let maximumPreview = 65_536
    public static let maximumPixels = 288
    private let root: URL
    private let client: PublicWebClient
    public init(root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenWeightsWebMedia"), client: PublicWebClient = PublicWebClient()) { self.root = root; self.client = client }
    private func key(_ url: String) -> String { SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func file(_ key: String) -> URL? {
        guard key.utf8.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return root.appendingPathComponent(key + ".jpg")
    }
    public func cached(_ key: String) -> Data? {
        guard let file = file(key), let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]), values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= Self.maximumPreview, let bytes = try? Data(contentsOf: file), bytes.count <= Self.maximumPreview else { return nil }
        return bytes
    }
    public func prepare(_ rawURL: String, timeout: TimeInterval = 8) async throws -> String {
        let address = try PublicWebAddress(rawURL); let name = key(address.url.absoluteString)
        try Task.checkCancellation()
        if cached(name) != nil { return name }
        let document = try await client.fetch(address.url.absoluteString, maximumBody: Self.maximumBody, timeout: min(8, max(1, timeout)))
        try Task.checkCancellation()
        guard document.response.status == 200, document.response.headers["content-type"]?.lowercased().hasPrefix("image/") == true,
              document.response.headers["content-encoding"].map({ $0.lowercased() == "identity" }) ?? true else { throw PublicWebError.refused("The result did not return a readable image preview.") }
        let preview = try Self.thumbnail(document.response.body)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true, let destination = file(name) else { throw PublicWebError.refused("The media cache location is unavailable.") }
        try preview.write(to: destination, options: .atomic)
        try trim()
        return name
    }
    private func trim() throws {
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        let owned = files.compactMap { url -> (URL, Int, Date)? in
            guard url.pathExtension == "jpg", file(url.deletingPathExtension().lastPathComponent) != nil, let attributes = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]), attributes.isRegularFile == true, attributes.isSymbolicLink != true else { return nil }
            return (url, attributes.fileSize ?? 0, attributes.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var bytes = owned.reduce(0) { $0 + $1.1 }; var count = owned.count
        for (url, size, _) in owned where bytes > 16_777_216 || count > 256 {
            try FileManager.default.removeItem(at: url); bytes -= size; count -= 1
        }
    }
    static func thumbnail(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumBody,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0, width.doubleValue <= 16_384, height.doubleValue <= 16_384,
              width.doubleValue * height.doubleValue <= 16_777_216,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximumPixels, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw PublicWebError.refused("The preview is not a complete image within the size limits.") }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw PublicWebError.refused("The image preview could not be prepared.") }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(output), data.length <= maximumPreview else { throw PublicWebError.refused("The prepared image preview is too large.") }
        return data as Data
    }
}
