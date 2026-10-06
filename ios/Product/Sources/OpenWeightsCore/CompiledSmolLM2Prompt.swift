import Foundation

// Android's SmolLm2Prompt preserves every role as its own ChatML block.
// Its upstream template has no tool-schema contract or thinking seed.
public enum CompiledSmolLM2Prompt {
    public static func render(_ messages: [[String: String]], tools: [AgentToolDefinition] = []) throws -> String {
        guard tools.isEmpty else {
            throw ModelError.unsupported("This SmolLM2 template does not support enabled tools. Turn the tools off or select a tool-capable model.")
        }
        var result = ""
        func block(_ role: String, _ content: String) {
            result += "<|im_start|>" + role + "\n" + content + "<|im_end|>\n"
        }
        if messages.first?["role"] != "system" {
            block("system", "You are a helpful AI assistant named SmolLM, trained by Hugging Face")
        }
        for message in messages {
            let role = message["role"] ?? "user"
            guard ["system", "user", "assistant", "tool"].contains(role) else {
                throw ModelError.unsupported("This compiled template cannot render that message role.")
            }
            block(role, message["content"] ?? "")
        }
        return result + "<|im_start|>assistant\n"
    }
}
