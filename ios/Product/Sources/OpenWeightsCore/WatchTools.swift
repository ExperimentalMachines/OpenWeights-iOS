import Foundation
import CoreFoundation

public enum WatchToolDefinitions {
    public static let all = [AgentToolDefinition(name: "watch",
        description: "Check something again on a schedule when the user asks to be told about a change or to look again later. Stops after 60 checks or 72 hours. iOS decides background execution time. Creating a watch always requires approval.",
        parametersJSON: "{\"type\":\"object\",\"properties\":{\"task\":{\"type\":\"string\",\"description\":\"The condition or fact to check each time.\"},\"every_minutes\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":1440}},\"required\":[\"task\",\"every_minutes\"]}")]
}

public actor WatchTools {
    private let store: WatchStore
    private var consumedApprovals: Set<UUID> = []
    public init(store: WatchStore) { self.store = store }
    public func execute(_ call: AgentToolCall, enabled: Bool, mode: AgentMode, approval: ApprovedToolCall? = nil,
                        at date: Date = Date()) async -> ToolResult {
        do {
            guard call.name == "watch" else { return refused("Unknown watch tool.") }
            guard enabled else { return refused("The watch tool is switched off.") }
            guard mode != .plan else { return refused("Plan mode: no watch was started.") }
            guard let args = try JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any] else {
                return refused("Watch arguments must be a JSON object.")
            }
            guard let task = ["task", "what", "check"].compactMap({ args[$0] as? String }).first else { return refused("Give the task to check.") }
            let interval = args["every_minutes"] ?? args["minutes"] ?? args["interval"]
            let minutes: Int
            if let number = interval as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
               (1...1440).contains(number.doubleValue), number.doubleValue.rounded(.towardZero) == number.doubleValue {
                minutes = number.intValue
            } else if let text = interval as? String, let integer = Int(text), (1...1440).contains(integer) { minutes = integer }
            else { return refused("Give every_minutes as a whole number between 1 and 1,440.") }
            guard let approval, approval.displayedCall == call, !consumedApprovals.contains(approval.ticketID) else {
                return refused("Approve this exact watch task and interval before it starts.")
            }
            consumedApprovals.insert(approval.ticketID)
            _ = try await store.start(task: task, everyMinutes: minutes, at: date)
            return ToolResult(text: "Watch saved with a requested interval of \(minutes) minutes. Fast checks run while the app is open. Background checks run when iOS grants time. Due reminders need notification permission. Catch-up runs when reopened. It stops after 60 checks or 72 hours, whichever comes first.")
        } catch { return refused(error.localizedDescription) }
    }
    private func refused(_ text: String) -> ToolResult { ToolResult(text: text, rejected: true) }
}
