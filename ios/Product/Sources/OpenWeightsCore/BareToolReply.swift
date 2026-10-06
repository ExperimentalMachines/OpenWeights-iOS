import Foundation

public enum BareToolReply {
    // Android's controller accepts name/arguments and tool/arguments replies.
    // This compiled fallback requires one complete JSON object and an offered name.
    public static func parse(_ raw: String, offered: Set<String>) -> TaggedToolReply? {
        guard !offered.isEmpty, raw.utf16.count <= 65_536,
              let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = (object["name"] ?? object["tool"]) as? String, offered.contains(name),
              let arguments = object["arguments"] as? [String: Any],
              let encoded = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let json = String(data: encoded, encoding: .utf8) else { return nil }
        return TaggedToolReply(content: "", calls: [AgentToolCall(id: name + "-0", name: name, argumentsJSON: json)])
    }
}
