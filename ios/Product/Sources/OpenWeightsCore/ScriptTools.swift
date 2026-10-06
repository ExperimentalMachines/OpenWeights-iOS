import Foundation

public struct ScriptResult: Sendable, Equatable {
    public let output: String
    public let failed: Bool
    public init(output: String, failed: Bool) { self.output = output; self.failed = failed }
}
public protocol ScriptRunner: Sendable {
    func run(source: String, inputsJSON: String) async throws -> ScriptResult
    func cancel()
}

public enum ScriptToolDefinition {
    public static let tool = AgentToolDefinition(name: "run_script",
        description: "Run a JavaScript program in a sandbox and use what it returns. For real computation: arithmetic, dates, regex, JSON, or a file too large to read whole. Give source, or path to a saved .js file. Modern JavaScript with await; no network; require('fs') and require('path') only, for files you named in files. The last expression is the answer.",
        parametersJSON: #"{"type":"object","properties":{"source":{"type":"string"},"path":{"type":"string"},"files":{"type":"array","items":{"type":"string"}}}}"#)
    public static func program(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), let regex = try? NSRegularExpression(pattern: #"^```[A-Za-z0-9+#._-]*[ \t]*\r?\n(.*?)(?:\r?\n```|```|$)"#, options: .dotMatchesLineSeparators),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) {
            text = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let replacements: [Character: Character] = ["\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{00A0}": " "]
        return String(text.map { replacements[$0] ?? $0 })
    }
    public static func mentionedPaths(_ source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"["']((?!\w+://)(?:[\w.\-]+/)*[\w.\-]+\.[A-Za-z0-9]{1,6})["']"#) else { return [] }
        var result: [String] = []
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            if let range = Range(match.range(at: 1), in: source) {
                let path = String(source[range]); if !result.contains(path) { result.append(path) }
                if result.count == 3 { break }
            }
        }
        return result
    }
    public static let nodeShim = #"""
    const __read = (p) => {
      const k = String(p).replace(/^\.?\//, "");
      const v = inputs[p] ?? inputs[k];
      if (v === undefined) throw new Error(p + " was not passed in files, so it is not readable here");
      return v;
    };
    const require = (m) => {
      const name = String(m).replace(/^node:/, "");
      if (name === "fs") return {
        readFileSync: __read,
        existsSync: (p) => { try { __read(p); return true; } catch (e) { return false; } },
        promises: { readFile: async (p) => __read(p) },
      };
      if (name === "path") return {
        join: (...a) => a.filter(Boolean).join("/").replace(/\/+/g, "/"),
        basename: (p) => String(p).split("/").pop(),
        extname: (p) => { const b = String(p).split("/").pop(); const i = b.lastIndexOf("."); return i < 0 ? "" : b.slice(i); },
      };
      throw new Error("there is no module '" + m + "' in this sandbox: it is plain JavaScript, with files in inputs['path']");
    };
    """# + "\n"
}

// The production controller must supply a verified isolated runner, never a fallback
// interpreter in the chat process. File bytes cross that boundary only as JSON data.
public actor ScriptTools {
    private let runner: any ScriptRunner
    private var approvals: Set<UUID> = []
    public init(runner: any ScriptRunner) { self.runner = runner }
    public nonisolated func cancel() { runner.cancel() }
    public func execute(_ call: AgentToolCall, enabled: Bool, mode: AgentMode,
                        workspace: Workspace? = nil, approval: ApprovedToolCall? = nil) async -> ToolResult {
        var privateDataRead = false
        func refuse(_ text: String) -> ToolResult { ToolResult(text: text, rejected: true, untrustedText: true, privateDataRead: privateDataRead) }
        do {
            guard call.name == "run_script", enabled else { return refuse("This script tool is switched off or unavailable.") }
            guard mode != .plan else { return refuse("Plan mode: no script was run.") }
            guard let args = try JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any] else { return refuse("Tool arguments must be a JSON object.") }
            if mode == .ask {
                guard let approval, approval.displayedCall == call, !approvals.contains(approval.ticketID) else { return refuse("Approve this exact script call before it runs.") }
                approvals.insert(approval.ticketID)
            }
            func string(_ names: String...) -> String? { names.compactMap { args[$0] as? String }.first }
            let from = string("path", "file", "script_path")
            let source: String
            if let inline = string("source", "code", "script", "js"), !inline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                source = ScriptToolDefinition.program(inline)
            } else if let from, let workspace {
                source = ScriptToolDefinition.program(try await workspace.readScriptInput(from, maximum: 16 * 1024))
                privateDataRead = true
            } else { return refuse("Give source, or path to a saved JavaScript file in the shared folder.") }
            guard !source.isEmpty, source.utf16.count <= 16 * 1024 else { return refuse("Keep the script at or below 16,384 UTF-16 characters.") }
            let declared: [String]
            if let files = args["files"] {
                guard let paths = files as? [String] else { return refuse("files must be an array of relative paths.") }
                declared = paths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            } else { declared = [] }
            var wanted: [String] = []
            for path in declared + ScriptToolDefinition.mentionedPaths(source) where !wanted.contains(path) {
                wanted.append(path); if wanted.count == 3 { break }
            }
            if !wanted.isEmpty && workspace == nil { return refuse("No folder has been shared, so there are no files to read. Choose one under Tools or run without files.") }
            var inputs: [String: String] = [:]
            if let workspace {
                guard await workspace.isReady else { return refuse(WorkspaceError.unavailable.localizedDescription) }
                for path in wanted {
                    // Missing files stay absent. A failed/revoked grant never reaches the runner.
                    _ = try Workspace.segments(path)
                    if try await workspace.exists(path) {
                        inputs[path] = try await workspace.readScriptInput(path, maximum: 20 * 1024)
                        privateDataRead = true
                    }
                }
            }
            try Task.checkCancellation()
            let json = try JSONSerialization.data(withJSONObject: inputs, options: .sortedKeys)
            let result = try await runner.run(source: ScriptToolDefinition.nodeShim + source, inputsJSON: String(decoding: json, as: UTF8.self))
            try Task.checkCancellation()
            if result.failed {
                let repair = from.map { " Save a corrected program at \($0) with write_file and replace, then run it again." } ?? ""
                return refuse("The script did not finish: " + result.output + repair)
            }
            return ToolResult(text: result.output.isEmpty ? "The script ran and produced nothing." : result.output, untrustedText: true, privateDataRead: privateDataRead)
        } catch { return refuse(error.localizedDescription) }
    }
}
