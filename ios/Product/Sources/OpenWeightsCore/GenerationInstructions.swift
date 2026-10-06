import Foundation

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case `default`, low, medium, high
    public var label: String { rawValue.capitalized }
    public var wireValue: String { self == .default ? "" : rawValue }
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .default
    }
}

public enum AnswerLength: String, Codable, CaseIterable, Sendable {
    case brief, balanced, thorough
    public var label: String { rawValue.capitalized }
    // Keep Android's measured wording. The output token ceiling is separate.
    public var instruction: String {
        switch self {
        case .brief:
            return "Answer from what you know. Reply with the answer itself and keep it short: the fewest sentences that answer the question."
        case .balanced:
            return "Answer from what you know. Reply with the answer itself, at the length the question calls for: a sentence for a simple one, and as long as it takes for one that asks for detail."
        case .thorough:
            return "Answer from what you know. Reply with the answer itself, and be thorough: cover the parts of the question somebody would ask about next, and use sections when there is more than one."
        }
    }
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .balanced
    }
}

extension ModelSettings {
    public func systemInstructions(base: String, toolsAvailable: Bool) -> String {
        var parts = [base]
        if let answerLength { parts.append(answerLength.instruction) }
        if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(systemPrompt) }
        if toolsAvailable, let toolPrompt, !toolPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(toolPrompt) }
        return parts.joined(separator: "\n\n")
    }
}
