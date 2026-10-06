import Foundation

public enum GGUFRangePolicy {
    public static func pinnedURL(repository: String, revision: String, path: String) throws -> URL {
        guard HubDiscoveryClient.validRepositoryID(repository), hex(revision, count: 40) else {
            throw ModelError.unsupported("The model needs a valid repository and pinned revision.")
        }
        try ModelFile.validatePath(path)
        return URL(string: "https://huggingface.co")!.appendingPathComponent(repository)
            .appendingPathComponent("resolve").appendingPathComponent(revision).appendingPathComponent(path)
    }
    public static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    public static func allowedRedirect(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host == "hf.co" || host.hasSuffix(".hf.co")
    }
    public static func rangeEnd(offset: Int64, length: Int) throws -> Int64 {
        guard offset >= 0, (1...1_048_576).contains(length), offset <= Int64.max - Int64(length) else {
            throw ModelError.unsupported("The GGUF inspection byte range is invalid.")
        }
        return offset + Int64(length) - 1
    }
    public struct Response: Equatable, Sendable {
        public let bytes: Int
        public let total: Int64
    }
    public static func validate(status: Int, contentRange: String?, contentLength: Int64?, encoding: String?,
                                offset: Int64, length: Int, expectedTotal: Int64?) throws -> Response {
        let end = try rangeEnd(offset: offset, length: length)
        guard encoding == nil || encoding?.lowercased() == "identity" else {
            throw ModelError.unsupported("GGUF header inspection requires uncompressed byte ranges.")
        }
        let bytes: Int64, total: Int64
        if status == 206, let range = contentRange {
            let expression = try! NSRegularExpression(pattern: "^bytes ([0-9]+)-([0-9]+)/([0-9]+)$")
            let source = range as NSString
            guard let match = expression.firstMatch(in: range, range: NSRange(location: 0, length: source.length)),
                  let start = Int64(source.substring(with: match.range(at: 1))),
                  let actualEnd = Int64(source.substring(with: match.range(at: 2))),
                  let size = Int64(source.substring(with: match.range(at: 3))),
                  size > 0, start == offset, actualEnd >= start, actualEnd <= end, actualEnd < size,
                  actualEnd == min(end, size - 1) else {
                throw ModelError.unsupported("The Hub returned an invalid GGUF byte range.")
            }
            bytes = actualEnd - start + 1; total = size
            guard contentLength == nil || contentLength == bytes else { throw ModelError.unsupported("The GGUF byte range length disagrees with its header.") }
        } else if status == 200, offset == 0, let size = contentLength, size > 0, size <= Int64(length), contentRange == nil {
            bytes = size; total = size
        } else {
            throw ModelError.unsupported("The Hub did not return a bounded GGUF byte range. Check access permissions and retry.")
        }
        guard expectedTotal == nil || expectedTotal == total else { throw ModelError.unsupported("The GGUF file size changed from the pinned metadata.") }
        return Response(bytes: Int(bytes), total: total)
    }
}
