import Foundation
import Combine
import OpenWeightsCore

@MainActor final class WorkspaceController: ObservableObject {
    @Published private(set) var folderName: String?
    @Published private(set) var busy = false
    @Published private(set) var acceptsWrites = false
    @Published var error: String?
    @Published var enabled: Set<String> { didSet { defaults.set(Array(enabled).sorted(), forKey: "tools.files.enabled") } }
    @Published var canvasEnabled: Set<String> { didSet { defaults.set(Array(canvasEnabled).sorted(), forKey: "tools.canvas.enabled") } }
    @Published private(set) var canvas: CanvasDescriptor?
    var pageChecker: ((CanvasDescriptor, Workspace) async -> CanvasPageReport?)?
    private var canvasApprovals: Set<UUID> = []
    private var canvasEpoch = UUID()
    private var grading: Task<CanvasPageReport?, Never>?
    @Published var mode: AgentMode { didSet { if mode != .yolo { defaults.set(mode.rawValue, forKey: "tools.mode") } } }
    private(set) var grantID: UUID?
    private var workspace: Workspace?
    private var tools: FileTools?
    private let bookmarkFile: URL
    private let defaults: UserDefaults

    init(bookmarkFile: URL, defaults: UserDefaults = .standard) {
        self.bookmarkFile = bookmarkFile; self.defaults = defaults
        enabled = Set(defaults.stringArray(forKey: "tools.files.enabled") ?? []).intersection(Set(FileToolDefinitions.all.map(\.name)))
        canvasEnabled = Set(defaults.stringArray(forKey: "tools.canvas.enabled") ?? []).intersection(Set(CanvasToolDefinitions.all.map(\.name)))
        let savedMode = AgentMode(rawValue: defaults.string(forKey: "tools.mode") ?? "auto") ?? .auto
        mode = savedMode == .yolo ? .auto : savedMode
    }
    var definitions: [AgentToolDefinition] {
        guard workspace != nil else { return [] }
        var settings = FileToolSettings(); settings.enabled = enabled; settings.mode = mode
        return FileToolDefinitions.enabled(settings, writable: acceptsWrites) + CanvasToolDefinitions.all.filter { canvasEnabled.contains($0.name) }
    }
    func restore() async {
        guard !busy, FileManager.default.fileExists(atPath: bookmarkFile.path) else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let data = try Data(contentsOf: bookmarkFile)
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw WorkspaceError.operation("The shared-folder bookmark is stale. Choose the folder again under Tools.") }
            try await activate(url, persist: false)
        } catch { self.error = error.localizedDescription }
    }
    func choose(_ url: URL) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await activate(url, persist: true) }
        catch { self.error = error.localizedDescription }
    }
    private func activate(_ url: URL, persist: Bool) async throws {
        let access: WorkspaceAccess = Self.belongsToApp(url) ? .coordinated : .securityScoped
        let candidate = try await Task.detached { try Workspace(root: url, access: access) }.value
        do {
            if persist {
                let data = try Self.bookmark(url, scoped: access == .securityScoped)
                try FileManager.default.createDirectory(at: bookmarkFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: bookmarkFile, options: .atomic)
            }
        } catch { await candidate.revoke(); throw error }
        await workspace?.revoke()
        cancel(); canvas = nil; canvasApprovals.removeAll()
        workspace = candidate; tools = FileTools(workspace: candidate)
        acceptsWrites = await candidate.acceptsWrites
        grantID = UUID(); folderName = url.lastPathComponent
    }
    func revoke() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            if FileManager.default.fileExists(atPath: bookmarkFile.path) { try FileManager.default.removeItem(at: bookmarkFile) }
            cancel(); canvas = nil; canvasApprovals.removeAll()
            await workspace?.revoke(); workspace = nil; tools = nil; folderName = nil; grantID = nil; acceptsWrites = false
        } catch { self.error = error.localizedDescription }
    }
    func clearSessionArtifacts() async { await workspace?.clearSessionArtifacts() }
    func cancel() { workspace?.cancel(); canvasEpoch = UUID(); grading?.cancel() }
    func beginTurn(carriesUntrustedText: Bool) async { await tools?.beginTurn(carriesUntrustedText: carriesUntrustedText) }
    func noteUntrustedRead() async { await tools?.noteUntrustedRead() }
    func workspaceForFetch(expectedGrantID: UUID?) -> Workspace? {
        guard !busy, let grantID, grantID == expectedGrantID else { return nil }
        return workspace
    }
    func requiresApproval(_ call: AgentToolCall) async -> Bool {
        if CanvasToolDefinitions.kind(call.name) != nil { return mode == .ask }
        guard let tools else { return false }
        return await tools.requiresApproval(call, mode: mode)
    }
    func execute(_ call: AgentToolCall, approval: ApprovedToolCall?, expectedGrantID: UUID?) async -> ToolResult {
        guard !busy, let tools, let grantID, grantID == expectedGrantID else {
            return ToolResult(text: "The shared folder changed or is unavailable. No file operation was started.", rejected: true)
        }
        if let kind = CanvasToolDefinitions.kind(call.name) {
            let epoch = canvasEpoch
            guard canvasEnabled.contains(call.name), mode != .plan, let workspace else { return ToolResult(text: "This canvas tool is switched off or Plan is active.", rejected: true) }
            if mode == .ask {
                guard let approval, approval.displayedCall == call, canvasApprovals.insert(approval.ticketID).inserted else { return ToolResult(text: "Approve this exact preview before it opens.", rejected: true) }
            }
            do {
                let path = try CanvasToolDefinitions.path(call)
                let entry = try await workspace.canvasEntry(path)
                guard kind == .site || entry == path else { throw WorkspaceError.operation("Choose a file, not a folder, for a document or deck.") }
                guard self.grantID == expectedGrantID, !busy, canvasEnabled.contains(call.name), epoch == canvasEpoch, !Task.isCancelled else { throw WorkspaceError.cancelled }
                let shown = CanvasDescriptor(kind: kind, entry: entry); canvas = shown
                let verdict = kind == .site ? await grade(shown, workspace: workspace, grant: expectedGrantID)?.verdict : nil
                return ToolResult(text: "Showing \(entry). Further saves update it live." + (verdict.map { "\n" + $0 } ?? ""), untrustedText: verdict != nil, privateDataRead: true)
            } catch { return ToolResult(text: error.localizedDescription, rejected: true) }
        }
        var settings = FileToolSettings(); settings.enabled = enabled; settings.mode = mode
        var result = await tools.execute(call, settings: settings, approval: approval)
        if !result.rejected, ["write_file", "delete_file"].contains(call.name),
           let path = try? CanvasToolDefinitions.path(call), let shown = canvas, shown.contains(path), self.grantID == expectedGrantID {
            canvas?.revision += 1
            if call.name == "write_file", shown.kind == .site, let workspace {
                let arguments = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any]
                let content = ["content", "text", "body"].compactMap { arguments?[$0] as? String }.first
                if let verdict = await grade(shown, workspace: workspace, grant: expectedGrantID, savedPath: path, savedContent: content)?.verdict {
                    result = ToolResult(text: result.text + "\n" + verdict, untrustedText: true, privateDataRead: true)
                }
            }
        }
        return result
    }
    func dismissCanvas() { canvas = nil }
    private func grade(_ shown: CanvasDescriptor, workspace: Workspace, grant: UUID?, savedPath: String? = nil, savedContent: String? = nil) async -> CanvasPageReport? {
        let checker = pageChecker
        let epoch = canvasEpoch
        let work = Task { await checker?(shown, workspace) }; grading = work
        let result = await work.value
        grading = nil
        guard epoch == canvasEpoch, grant == grantID, canvas?.id == shown.id, !work.isCancelled else { return nil }
        return (result ?? CanvasPageReport()).includingSavedHTML(path: savedPath, content: savedContent)
    }
    func executeUnattended(_ call: AgentToolCall, expectedGrantID: UUID?) async -> ToolResult {
        guard !busy, let tools, let grantID, grantID == expectedGrantID else {
            return ToolResult(text: "The shared folder changed or is unavailable. No file operation was started.", rejected: true)
        }
        var settings = FileToolSettings(); settings.enabled = enabled; settings.mode = .auto
        guard !(await tools.requiresApproval(call, mode: .auto)) else {
            return ToolResult(text: "This file action needs approval, so the scheduled check did not perform it.", rejected: true)
        }
        return await tools.execute(call, settings: settings)
    }
    nonisolated private static func bookmark(_ url: URL, scoped: Bool) throws -> Data {
        if scoped && !url.startAccessingSecurityScopedResource() { throw WorkspaceError.unavailable }
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    nonisolated private static func belongsToApp(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let roots = [URL(fileURLWithPath: NSHomeDirectory()), FileManager.default.temporaryDirectory]
        return roots.contains {
            let root = $0.resolvingSymlinksInPath().path
            return path == root || path.hasPrefix(root + "/")
        }
    }
}
