import Foundation
import ExtensionFoundation
import XPC
import OpenWeightsCore

@available(iOS 26.0, *) extension AppExtensionPoint {
    @Definition static var scriptSandbox: AppExtensionPoint {
        Name("ScriptSandbox")
        Scope(restriction: .application)
        EnhancedSecurity()
    }
}

@available(iOS 26.0, *) @MainActor final class IsolatedScriptRunner: ScriptRunner {
    private nonisolated let control = ScriptRequestControl()
    private let deadlineNanoseconds: UInt64
    private let beforeDiscovery: (@MainActor () async -> Void)?
    private(set) var lastProcessID: Int32?
    private(set) var lastStage = "idle"
    private(set) var lastReplyDescription: String?
    var hasPendingRequest: Bool { control.hasActiveRequest }
    init(deadlineNanoseconds: UInt64 = 5_000_000_000, beforeDiscovery: (@MainActor () async -> Void)? = nil) {
        precondition(deadlineNanoseconds > 0 && deadlineNanoseconds <= 5_000_000_000)
        self.deadlineNanoseconds = deadlineNanoseconds; self.beforeDiscovery = beforeDiscovery
    }
    nonisolated func cancel() { control.cancel() }

    func run(source: String, inputsJSON: String) async throws -> ScriptResult {
        try await request(action: .run, source: source, inputsJSON: inputsJSON)
    }
    #if OW_SCRIPT_SECURITY_VALIDATION
    func validateAccess(path: String, port: UInt16) async throws -> ScriptResult {
        let data = try JSONSerialization.data(withJSONObject: ["path": path, "port": Int(port)])
        return try await request(action: .validateAccess, source: "", inputsJSON: String(decoding: data, as: UTF8.self))
    }
    func terminateForValidation() async throws -> ScriptResult {
        try await request(action: .terminateForValidation, source: "", inputsJSON: "{}")
    }
    #endif

    private func request(action: ScriptWireRequest.Action, source: String, inputsJSON: String) async throws -> ScriptResult {
        try Task.checkCancellation()
        guard source.utf8.count <= 72 * 1024, inputsJSON.utf8.count <= 400 * 1024 else { throw ScriptProcessError.invalidRequest }
        let pending = try control.begin()
        let reply: ScriptWireReply = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                // The caller waits on its own continuation, never on a potentially
                // non-cooperative OS launch. A late launch remains the only admitted
                // request until its resources have been invalidated.
                pending.attach(continuation)
                pending.deadline = Task {
                    try? await Task.sleep(nanoseconds: deadlineNanoseconds)
                    if !Task.isCancelled { pending.finish(.failure(URLError(.timedOut))) }
                }
                pending.launch = Task { @MainActor in
                    defer { pending.launchEnded() }
                    do {
                        try pending.check()
                        lastStage = "discovering-extension"
                        if let beforeDiscovery { await beforeDiscovery() }
                        try pending.check()
                        let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .scriptSandbox)
                        lastStage = "extension-discovered"
                        try pending.check()
                        let expected = (Bundle.main.bundleIdentifier ?? "") + ".script"
                        guard let identity = monitor.identities.first(where: { $0.bundleIdentifier == expected }) else { throw ScriptProcessError.unavailable }
                        lastStage = "launching-extension"
                        pending.process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity, onInterruption: {
                            Task { @MainActor in pending.finish(.failure(ScriptProcessError.interrupted)) }
                        }))
                        try pending.check()
                        lastStage = "connecting-xpc"
                        let channel = try pending.process!.makeXPCSession(); pending.session = channel
                        channel.setCancellationHandler { error in Task { @MainActor in pending.finish(.failure(error)) } }
                        try channel.activate()
                        try pending.check()
                        lastStage = "waiting-for-reply"
                        try channel.send(ScriptWireRequest(action: action, id: pending.id, source: source, inputsJSON: inputsJSON)) { (result: Result<ScriptWireReply, Error>) in
                            Task { @MainActor in pending.finish(result) }
                        }
                    } catch { pending.finish(.failure(error)) }
                }
            }
        }, onCancel: { pending.requestCancellation() })
        lastReplyDescription = String(describing: reply)
        try Task.checkCancellation()
        guard reply.id == pending.id, reply.processID > 0, reply.processID != getpid(), reply.output.utf8.count <= 2000 else { throw ScriptProcessError.invalidReply }
        lastStage = "received-reply"; lastProcessID = reply.processID
        return ScriptResult(output: reply.output, failed: reply.failed)
    }
}

enum ScriptProcessError: LocalizedError {
    case unavailable, interrupted, busy, invalidReply, invalidRequest
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The isolated script extension is unavailable. No script was run."
        case .interrupted: return "The isolated script process stopped before returning a result."
        case .busy: return "Another script request is still running or stopping. Try again shortly."
        case .invalidReply: return "The isolated script process returned an invalid result."
        case .invalidRequest: return "The script request exceeds its resource limits."
        }
    }
}

@available(iOS 26.0, *) private final class ScriptRequestControl: @unchecked Sendable {
    private let lock = NSLock()
    private var active: ScriptPendingRequest?
    var hasActiveRequest: Bool { lock.withLock { active != nil } }
    @MainActor func begin() throws -> ScriptPendingRequest {
        try lock.withLock {
            guard active == nil else { throw ScriptProcessError.busy }
            let request = ScriptPendingRequest(onEnd: { [self] request in end(request) })
            active = request; return request
        }
    }
    private func end(_ request: ScriptPendingRequest) { lock.withLock { if active === request { active = nil } } }
    func cancel() { let request = lock.withLock { active }; request?.requestCancellation() }
}

@available(iOS 26.0, *) @MainActor private final class ScriptPendingRequest {
    let id = UUID()
    var deadline: Task<Void, Never>?
    var launch: Task<Void, Never>?
    var process: AppExtensionProcess?
    var session: XPCSession?
    private var result: Result<ScriptWireReply, Error>?
    private var continuation: CheckedContinuation<ScriptWireReply, Error>?
    private var launching = true
    private var ended = false
    private let onEnd: (ScriptPendingRequest) -> Void
    init(onEnd: @escaping (ScriptPendingRequest) -> Void) { self.onEnd = onEnd }
    func attach(_ continuation: CheckedContinuation<ScriptWireReply, Error>) {
        if let stored = result { continuation.resume(with: stored) }
        else { self.continuation = continuation }
    }
    func finish(_ outcome: Result<ScriptWireReply, Error>) {
        guard result == nil else { return }
        result = outcome
        deadline?.cancel(); deadline = nil
        launch?.cancel()
        clearResources()
        if !launching { end() }
        let callback = continuation; continuation = nil
        callback?.resume(with: outcome)
    }
    func launchEnded() {
        launching = false; launch = nil
        if result != nil { clearResources(); end() }
    }
    private func clearResources() {
        if case .failure = result, let session {
            try? session.send(ScriptWireRequest(action: .cancel, id: id, source: "", inputsJSON: "{}"))
        }
        session?.cancel(reason: "Script request finished."); session = nil
        process?.invalidate(); process = nil
    }
    private func end() { guard !ended else { return }; ended = true; onEnd(self) }
    func check() throws {
        if case .failure(let error) = result { throw error }
        try Task.checkCancellation()
    }
    nonisolated func requestCancellation() { Task { @MainActor in finish(.failure(CancellationError())) } }
}
