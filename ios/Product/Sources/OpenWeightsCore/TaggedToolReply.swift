import Foundation

// Android also falls back when a template renders tools but its native parser misses them.
public struct TaggedToolReply: Sendable {
    public let content: String
    public let calls: [AgentToolCall]
    public static func parse(_ raw: String, offered: Set<String>) -> TaggedToolReply? {
        guard !offered.isEmpty, raw.utf16.count <= 65_536 else { return nil }
        var answer = raw
        if let close = answer.range(of: "</think>"), answer.range(of: "<think>").map({ close.lowerBound < $0.lowerBound }) ?? true {
            answer = String(answer[close.upperBound...])
        } else if let open = answer.range(of: "<think>") {
            guard let close = answer.range(of: "</think>", range: open.upperBound..<answer.endIndex) else { return nil }
            answer.removeSubrange(open.lowerBound..<close.upperBound)
        }
        // A fenced example is display text, not a request to invoke a function.
        guard !answer.contains("```") else { return nil }
        var remaining = answer[...]; var prose = ""; var calls: [AgentToolCall] = []
        while let open = remaining.range(of: "<tool_call>") {
            guard calls.count < 16, let close = remaining.range(of: "</tool_call>", range: open.upperBound..<remaining.endIndex) else { return nil }
            let body = String(remaining[open.upperBound..<close.lowerBound])
            guard let data = body.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = object["name"] as? String, offered.contains(name), let arguments = object["arguments"] as? [String: Any],
                  let encoded = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
                  let json = String(data: encoded, encoding: .utf8) else { return nil }
            calls.append(AgentToolCall(id: "\(name)-\(calls.count)", name: name, argumentsJSON: json))
            prose += remaining[..<open.lowerBound]
            remaining = remaining[close.upperBound...]
        }
        guard !calls.isEmpty else { return nil }
        prose += remaining
        return TaggedToolReply(content: prose.trimmingCharacters(in: .whitespacesAndNewlines), calls: calls)
    }
}
