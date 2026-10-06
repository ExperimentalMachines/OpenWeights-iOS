import Foundation

public struct EngineFeatures: Equatable, Sendable {
    public let backends: [String]
    public let enabled: [String]
    public init(info: String) {
        let parts = info.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let part = parts.first(where: { $0.lowercased().hasPrefix("backends:") }), let colon = part.firstIndex(of: ":") {
            backends = part[part.index(after: colon)...].split(whereSeparator: { $0.isWhitespace }).map(String.init)
        } else { backends = [] }
        enabled = parts.compactMap { part in
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[1].trimmingCharacters(in: .whitespaces) == "1" else { return nil }
            let key = pair[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "CPU :", with: "").trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : key
        }
    }
}
