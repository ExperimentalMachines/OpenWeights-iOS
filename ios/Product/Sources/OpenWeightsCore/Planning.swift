import CoreFoundation
import Foundation

public struct TaskStep: Codable, Equatable, Sendable {
    public var text: String
    public var done: Bool
    public init(text: String, done: Bool = false) { self.text = text; self.done = done }
}

public struct TaskPlan: Codable, Equatable, Sendable {
    public var steps: [TaskStep]
    public init(steps: [TaskStep]) { self.steps = steps }
    public var isFinished: Bool { !steps.isEmpty && steps.allSatisfy(\.done) }
    public var next: TaskStep? { steps.first { !$0.done } }
    public func ticked(_ index: Int, done: Bool = true) -> TaskPlan {
        guard steps.indices.contains(index) else { return self }
        var value = self; value.steps[index].done = done; return value
    }
    public var statusBlock: String {
        guard !steps.isEmpty else { return "" }
        var lines = ["Plan:"] + steps.enumerated().map { "\($0.offset + 1). [\($0.element.done ? "x" : " ")] \($0.element.text)" }
        if next != nil { lines.append("Do the next unticked step, then say what you did.") }
        return lines.joined(separator: "\n")
    }
    public static func read(_ text: String) -> TaskPlan? {
        let marker = try! NSRegularExpression(pattern: "^(?:step\\s*)?(?:\\d+[.):]|[-*•])\\s*", options: .caseInsensitive)
        let emphasis = try! NSRegularExpression(pattern: "\\*\\*|__|`|(?<![\\p{L}\\p{N}])[*_](?=\\S)|(?<=\\S)[*_](?![\\p{L}\\p{N}])")
        var steps: [TaskStep] = []
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = marker.firstMatch(in: line, range: range), let cut = Range(match.range, in: line) else { continue }
            let body = String(line[cut.upperBound...])
            let plain = emphasis.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { continue }
            // Kotlin counts UTF-16. Keep that budget without severing a Swift grapheme.
            var window = ""
            for character in plain {
                if window.utf16.count + String(character).utf16.count > 60 { break }
                window.append(character)
            }
            if plain.utf16.count > 60 {
                if let space = window.lastIndex(of: " "), window[..<space].utf16.count >= 30 { window = String(window[..<space]) }
                while let last = window.last, " ,;:-".contains(last) { window.removeLast() }
            }
            steps.append(TaskStep(text: window))
            if steps.count == 5 { break }
        }
        return steps.count >= 2 ? TaskPlan(steps: steps) : nil
    }
}

public struct UserQuestion: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let options: [String]
    public let multiple: Bool
    public init(id: UUID = UUID(), text: String, options: [String] = [], multiple: Bool = false) {
        self.id = id; self.text = text; self.options = Array(options.prefix(4)); self.multiple = multiple
    }
    public static func read(_ call: AgentToolCall) throws -> UserQuestion {
        let args = try PlanningToolDefinitions.arguments(call)
        let text = ["question", "text", "prompt"].compactMap { args[$0] as? String }.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { throw PlanningError.arguments("Give the question to ask.") }
        let options = (args["options"] as? [Any] ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let flag = args["multiple"] ?? args["multi"]
        let boolean = flag as? NSNumber
        let multiple = (boolean.map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false) || (flag as? String)?.lowercased() == "true"
        return UserQuestion(text: text, options: options, multiple: multiple)
    }
}

public enum PlanningError: LocalizedError {
    case arguments(String)
    public var errorDescription: String? { if case .arguments(let text) = self { return text }; return nil }
}

public enum PlanningToolDefinitions {
    public static func enabled(plan: TaskPlan?, mode: AgentMode) -> [AgentToolDefinition] {
        var values: [AgentToolDefinition] = []
        if plan?.isFinished == false {
            values.append(AgentToolDefinition(name: "advance", description: "Mark one step of the plan finished, by its number.",
                parametersJSON: "{\"type\":\"object\",\"properties\":{\"step\":{\"type\":\"integer\"}},\"required\":[\"step\"]}"))
        }
        if mode == .plan {
            values.append(AgentToolDefinition(name: "ask_user", description: "Ask for a missing preference or information only the user can provide, when it is required to proceed. Use details already supplied. Do the assigned work yourself, including calculations. Do not ask for optional details a general plan does not need. Suggest up to four short options. The user can always type an answer.",
                parametersJSON: "{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\"},\"options\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"multiple\":{\"type\":\"boolean\"}},\"required\":[\"question\"]}"))
        }
        return values
    }
    public static func step(_ call: AgentToolCall) throws -> Int {
        let args = try arguments(call)
        guard let value = args["step"] ?? args["number"] ?? args["index"] else { throw PlanningError.arguments("Give the step's number.") }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue >= Double(Int.min), number.doubleValue < Double(Int.max),
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else { throw PlanningError.arguments("Give a whole step number.") }
            return number.intValue
        }
        if let text = value as? String, let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return number }
        throw PlanningError.arguments("Give a whole step number.")
    }
    static func arguments(_ call: AgentToolCall) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any] else {
            throw PlanningError.arguments("Tool arguments must be a JSON object.")
        }
        return value
    }
}
