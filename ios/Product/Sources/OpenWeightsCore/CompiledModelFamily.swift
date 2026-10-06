import Foundation

public enum CompiledModelFamily: String, Sendable {
    case qwen3, qwen25, smollm2, llama32
    public var supportsThinking: Bool { self == .qwen3 }
    public var supportsTools: Bool { self != .smollm2 }
    public var label: String {
        switch self {
        case .qwen3: return "Qwen3"
        case .qwen25: return "Qwen2.5 Instruct"
        case .smollm2: return "SmolLM2 Instruct"
        case .llama32: return "Llama 3.2 Instruct"
        }
    }

    public static func from(sourceModel: String) -> Self? {
        let name = String(sourceModel.split(separator: "/").last ?? "")
        let lowered = name.lowercased()
        guard !["coder", "vision", "-vl", "guard"].contains(where: lowered.contains) else { return nil }
        if name.hasPrefix("Qwen3-") { return .qwen3 }
        if name.hasPrefix("Qwen2.5-"), name.hasSuffix("-Instruct") { return .qwen25 }
        if name.hasPrefix("SmolLM2-"), name.hasSuffix("-Instruct") { return .smollm2 }
        if name.hasPrefix("Llama-3.2-"), name.hasSuffix("-Instruct") { return .llama32 }
        return nil
    }

    public var endOfTurnTokens: [String] {
        self == .llama32 ? ["<|eot_id|>", "<|eom_id|>", "<|end_of_text|>"] : ["<|im_end|>"]
    }
    public var endOfTextToken: String { self == .llama32 ? "<|end_of_text|>" : "<|endoftext|>" }

    public func render(_ messages: [[String: String]], tools: [AgentToolDefinition] = [], thinking: Bool,
                       date: String = CompiledLlama32Prompt.today()) throws -> String {
        switch self {
        case .qwen3: return try CompiledQwen3Prompt.render(messages, tools: tools, thinking: thinking)
        case .qwen25: return try CompiledQwen25Prompt.render(messages, tools: tools)
        case .smollm2: return try CompiledSmolLM2Prompt.render(messages, tools: tools)
        case .llama32: return try CompiledLlama32Prompt.render(messages, tools: tools, date: date)
        }
    }
}
