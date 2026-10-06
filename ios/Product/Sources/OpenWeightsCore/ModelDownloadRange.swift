import Foundation

public enum ModelDownloadRange {
    public static func header(offset: Int64, total: Int64?, chunkBytes: Int64, background: Bool) throws -> String {
        guard offset >= 0, offset < Int64.max, chunkBytes > 0,
              total == nil || (total! > offset && total! > 0) else {
            throw ModelError.unsupported("The model download has an invalid byte range.")
        }
        // Background wake-ups are rate limited. A known file can finish with one
        // remaining-range request, while foreground checkpoints stay bounded.
        let addition = offset.addingReportingOverflow(chunkBytes - 1)
        let bounded = addition.overflow ? Int64.max - 1 : min(addition.partialValue, Int64.max - 1)
        let end = background && total != nil ? total! - 1 : min(total.map { $0 - 1 } ?? Int64.max - 1, bounded)
        return "bytes=\(offset)-\(end)"
    }
}
