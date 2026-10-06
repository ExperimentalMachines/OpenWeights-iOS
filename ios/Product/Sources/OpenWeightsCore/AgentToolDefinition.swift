import Foundation

public struct AgentToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersJSON: String
    public init(name: String, description: String, parametersJSON: String) {
        self.name = name; self.description = description; self.parametersJSON = parametersJSON
    }
}

public enum MemoryToolDefinitions {
    public static func enabled(_ settings: MemoryToolSettings) -> [AgentToolDefinition] {
        var result: [AgentToolDefinition] = []
        if settings.readEnabled {
            result.append(AgentToolDefinition(name: "read_memory",
                description: "Read short facts saved about this user in earlier conversations. Call before answering something that depends on who the user is or what they prefer.",
                parametersJSON: "{\"type\":\"object\",\"properties\":{}}"))
        }
        if settings.writeEnabled {
            result += [
                AgentToolDefinition(name: "save_memory", description: "Save one short lasting fact about the user for future conversations. The user must approve the exact fact.",
                    parametersJSON: "{\"type\":\"object\",\"properties\":{\"fact\":{\"type\":\"string\"}},\"required\":[\"fact\"]}"),
                AgentToolDefinition(name: "update_memory", description: "Rewrite one saved fact. Use its current text from read_memory and the replacement. The user must approve both values.",
                    parametersJSON: "{\"type\":\"object\",\"properties\":{\"old\":{\"type\":\"string\"},\"new\":{\"type\":\"string\"}},\"required\":[\"old\",\"new\"]}"),
                AgentToolDefinition(name: "forget_memory", description: "Delete one saved fact when the user asks to forget it. The user must approve the exact fact.",
                    parametersJSON: "{\"type\":\"object\",\"properties\":{\"fact\":{\"type\":\"string\"}},\"required\":[\"fact\"]}")
            ]
        }
        return result
    }
}
