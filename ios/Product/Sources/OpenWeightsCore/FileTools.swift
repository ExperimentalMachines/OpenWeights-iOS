import Foundation
import CoreFoundation

public enum AgentMode: String, Codable, Sendable, CaseIterable {
    case auto, ask, plan, yolo
}

public struct FileToolSettings: Sendable {
    public var enabled: Set<String> = []
    public var mode: AgentMode = .auto
    public init() {}
}

public enum FileToolDefinitions {
    public static let all = [
        AgentToolDefinition(name: "find_files", description: "Find files in the shared folder by a name pattern like *.md, optionally containing given text. Not for reading a file whose path you have. If nothing was named to look for, ask rather than guess.", parametersJSON: "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"contains\":{\"type\":\"string\"}},\"required\":[\"pattern\"]}"),
        AgentToolDefinition(name: "read_file", description: "Read a UTF-8 text file in the shared folder. Use the path returned by find_files. An offset continues a truncated file in UTF-16 characters.", parametersJSON: "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"offset\":{\"type\":\"integer\"}},\"required\":[\"path\"]}"),
        AgentToolDefinition(name: "write_file", description: "Save a file into the folder the user shared. Pass replace to overwrite one that exists. If no path is given, ask where.", parametersJSON: "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"},\"replace\":{\"type\":\"boolean\"}},\"required\":[\"path\",\"content\"]}"),
        AgentToolDefinition(name: "delete_file", description: "Delete a file or folder from the folder the user shared. Deleting a folder deletes everything in it.", parametersJSON: "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}")
    ]
    public static func enabled(_ settings: FileToolSettings, writable: Bool) -> [AgentToolDefinition] {
        all.filter { settings.enabled.contains($0.name) && (writable || !["write_file", "delete_file"].contains($0.name)) }
    }
}

public actor FileTools {
    public let workspace: Workspace
    private var consumedApprovals: Set<UUID> = []
    private var readUntrustedText = false
    public init(workspace: Workspace) { self.workspace = workspace }
    public func beginTurn(carriesUntrustedText: Bool = false) async {
        await workspace.prepareTurn()
        readUntrustedText = carriesUntrustedText
    }
    public func noteUntrustedRead() { readUntrustedText = true }
    public func requiresApproval(_ call: AgentToolCall, mode: AgentMode) async -> Bool {
        guard let args = try? arguments(call), mode != .plan else { return false }
        let writes = ["write_file", "delete_file"].contains(call.name)
        if writes && readUntrustedText { return true }
        if writes, let path = string(args, "path", "file", "name") {
            let own = await workspace.isSessionOwned(path)
            if call.name == "delete_file" && !own { return true }
            if call.name == "write_file" && flag(args, "replace", "overwrite") && !own { return true }
        }
        return mode == .ask
    }
    public func execute(_ call: AgentToolCall, settings: FileToolSettings, approval: ApprovedToolCall? = nil) async -> ToolResult {
        var readAttempted = false
        do {
            guard FileToolDefinitions.all.contains(where: { $0.name == call.name }) else { return refused("Unknown file tool.") }
            guard settings.enabled.contains(call.name) else { return refused("This file tool is switched off.") }
            guard settings.mode != .plan else { return refused("Plan mode: nothing was run.") }
            guard await workspace.isReady else { return refused(WorkspaceError.unavailable.localizedDescription) }
            let args = try arguments(call)
            if await requiresApproval(call, mode: settings.mode) {
                guard let approval, approval.displayedCall == call, !consumedApprovals.contains(approval.ticketID) else {
                    return refused("Approve this exact file tool call before it runs.")
                }
                consumedApprovals.insert(approval.ticketID)
            }
            let text: String
            switch call.name {
            case "find_files":
                guard let pattern = string(args, "pattern", "name", "glob", "query") else { return refused("Give a file name or pattern such as *.md.") }
                // File names and contents both come from outside the model's instructions.
                readUntrustedText = true
                readAttempted = true
                let result = try await workspace.find(pattern: pattern, contains: string(args, "contains", "text", "containing"))
                if result.paths.isEmpty {
                    text = result.partial ? "Nothing matched in the part of the folder searched. More entries remain. Try a narrower pattern." : "Nothing in the shared folder matched."
                } else {
                    text = (result.partial ? "The first \(result.paths.count), and there may be more:" : "\(result.paths.count) found:") + "\n" + result.paths.joined(separator: "\n")
                }
            case "read_file":
                guard let path = string(args, "path", "file", "name") else { return refused("Give the path of the file to read.") }
                let offset = try offset(args)
                readUntrustedText = true
                readAttempted = true
                let window = try await workspace.read(path, offset: offset)
                if window.text.isEmpty { text = "\(path) has nothing more to read from character \(offset)." }
                else if let next = window.nextOffset {
                    text = window.text + "\n\n[Cut here: \(window.text.utf16.count) characters starting at \(offset). To read the next part, call read_file with the same path and offset \(next).]"
                } else { text = window.text }
            case "write_file":
                guard let path = string(args, "path", "file", "name"), let content = string(args, "content", "text", "body") else {
                    return refused("Give both the relative path and the whole file content.")
                }
                try await workspace.write(path, content: content, replace: flag(args, "replace", "overwrite"))
                text = "Saved \(path)."
            default:
                guard let path = string(args, "path", "file", "name") else { return refused("Give the relative path to delete.") }
                try await workspace.delete(path)
                text = "Deleted \(path)."
            }
            return ToolResult(text: text, untrustedText: readAttempted)
        } catch { return ToolResult(text: error.localizedDescription, rejected: true, untrustedText: readAttempted) }
    }
    private func arguments(_ call: AgentToolCall) throws -> [String: Any] {
        guard let args = try JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any] else {
            throw WorkspaceError.operation("Tool arguments must be a JSON object.")
        }
        return args
    }
    private func string(_ arguments: [String: Any], _ names: String...) -> String? {
        names.compactMap { arguments[$0] as? String }.first
    }
    private func flag(_ arguments: [String: Any], _ names: String...) -> Bool {
        names.contains { (arguments[$0] as? Bool) == true }
    }
    private func offset(_ arguments: [String: Any]) throws -> Int {
        guard let value = arguments["offset"] ?? arguments["start"] ?? arguments["skip"] else { return 0 }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue >= 0, number.doubleValue < Double(Int.max),
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else { throw WorkspaceError.invalidOffset }
            return number.intValue
        }
        if let string = value as? String, let integer = Int(string), integer >= 0 { return integer }
        throw WorkspaceError.invalidOffset
    }
    private func refused(_ text: String) -> ToolResult { ToolResult(text: text, rejected: true) }
}
