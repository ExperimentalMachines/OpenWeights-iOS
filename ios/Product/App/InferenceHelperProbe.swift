import Foundation
import ExtensionFoundation
import XPC

@available(iOS 26.0, *) extension AppExtensionPoint {
    @Definition static var inferenceHelper: AppExtensionPoint {
        Name("InferenceHelper")
        Scope(restriction: .application)
        EnhancedSecurity(false)
    }
}

// This bounded probe verifies process isolation and descriptor loading. It is
// deliberately separate from RuntimeFactory until streaming/settings are supported.
@available(iOS 26.0, *) @MainActor final class InferenceHelperProbe {
    private var active: InferenceProbeRequest?
    private(set) var stage = "idle"
    private let stages = InferenceProbeStages()
    var progress: [[String: Any]] { stages.snapshot() }

    func run(model: URL, tokenizer: URL) async throws -> [String: Any] {
        guard active == nil else { throw ScriptProcessError.busy }
        try Task.checkCancellation()
        let modelFD = open(model.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        let tokenizerFD = open(tokenizer.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        defer { if modelFD >= 0 { close(modelFD) }; if tokenizerFD >= 0 { close(tokenizerFD) } }
        guard modelFD >= 0, tokenizerFD >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let message = XPCDictionary()
        message.withUnsafeUnderlyingDictionary {
            xpc_dictionary_set_fd($0, "model", modelFD)
            xpc_dictionary_set_fd($0, "tokenizer", tokenizerFD)
        }
        let pending = InferenceProbeRequest(onEnd: { [weak self] request in
            if self?.active === request { self?.active = nil }
        })
        active = pending
        stages.reset()
        let result: XPCDictionary = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending.attach(continuation)
                pending.deadline = Task {
                    try? await Task.sleep(for: .seconds(120))
                    if !Task.isCancelled { pending.finish(.failure(URLError(.timedOut))) }
                }
                pending.launch = Task { @MainActor in
                    defer { pending.launchEnded() }
                    do {
                        try pending.check(); stage = "discovering"
                        let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .inferenceHelper)
                        try pending.check()
                        let expected = (Bundle.main.bundleIdentifier ?? "") + ".inference"
                        guard let identity = monitor.identities.first(where: { $0.bundleIdentifier == expected }) else { throw ScriptProcessError.unavailable }
                        stage = "launching"
                        pending.process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity, onInterruption: {
                            Task { @MainActor in pending.finish(.failure(ScriptProcessError.interrupted)) }
                        }))
                        try pending.check(); stage = "connecting"
                        let session = try pending.process!.makeXPCSession(); pending.session = session
                        session.setIncomingMessageHandler { [stages] (value: XPCDictionary) -> XPCDictionary? in
                            stages.record(value)
                            return XPCDictionary()
                        }
                        session.setCancellationHandler { error in Task { @MainActor in pending.finish(.failure(error)) } }
                        try session.activate(); try pending.check(); stage = "waiting"
                        try session.send(message: message) { (result: Result<XPCDictionary, XPCRichError>) in
                            Task { @MainActor in pending.finish(result.mapError { $0 as Error }) }
                        }
                    } catch { pending.finish(.failure(error)) }
                }
            }
        }, onCancel: { Task { @MainActor in pending.finish(.failure(CancellationError())) } })
        try Task.checkCancellation()
        stage = "replied"
        return result.withUnsafeUnderlyingDictionary { raw in
            func string(_ key: String) -> String { xpc_dictionary_get_string(raw, key).map { String(cString: $0) } ?? "" }
            return ["stage":string("stage"), "error":string("error"), "text":string("text"),
                    "processID":xpc_dictionary_get_int64(raw,"processID"), "hostProcessID":getpid(),
                    "modelBytes":xpc_dictionary_get_int64(raw,"modelBytes"), "tokenizerBytes":xpc_dictionary_get_int64(raw,"tokenizerBytes"),
                    "metalAvailable":xpc_dictionary_get_bool(raw,"metalAvailable")]
        }
    }
}

private final class InferenceProbeStages: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String: Any]] = []
    func reset() { lock.withLock { values = [] } }
    func snapshot() -> [[String: Any]] { lock.withLock { values } }
    func record(_ message: XPCDictionary) {
        message.withUnsafeUnderlyingDictionary { raw in
            guard let pointer = xpc_dictionary_get_string(raw,"progress") else { return }
            let name = String(cString:pointer), pid = xpc_dictionary_get_int64(raw,"processID")
            guard name.utf8.count <= 64, pid > 0, pid != getpid() else { return }
            let record: [String: Any] = ["stage":name,"processID":pid,"footprintBytes":xpc_dictionary_get_uint64(raw,"footprintBytes"),"availableMemoryBytes":xpc_dictionary_get_uint64(raw,"availableMemoryBytes"),"observedAtUTC":ISO8601DateFormatter().string(from:Date())]
            lock.withLock { if values.count < 32 { values.append(record) } }
        }
    }
}

@available(iOS 26.0, *) @MainActor private final class InferenceProbeRequest {
    var deadline: Task<Void, Never>?
    var launch: Task<Void, Never>?
    var process: AppExtensionProcess?
    var session: XPCSession?
    private var result: Result<XPCDictionary, Error>?
    private var continuation: CheckedContinuation<XPCDictionary, Error>?
    private var launching = true
    private var ended = false
    private let onEnd: (InferenceProbeRequest) -> Void
    init(onEnd: @escaping (InferenceProbeRequest) -> Void) { self.onEnd = onEnd }
    func attach(_ value: CheckedContinuation<XPCDictionary, Error>) {
        if let result { value.resume(with: result) } else { continuation = value }
    }
    func finish(_ outcome: Result<XPCDictionary, Error>) {
        guard result == nil else { return }
        result = outcome; deadline?.cancel(); deadline = nil; launch?.cancel()
        clearResources()
        if !launching { end() }
        let callback = continuation; continuation = nil; callback?.resume(with: outcome)
    }
    func launchEnded() {
        launching = false; launch = nil
        if result != nil { clearResources(); end() }
    }
    private func clearResources() {
        session?.cancel(reason: "Inference probe ended."); session = nil
        process?.invalidate(); process = nil
    }
    private func end() { guard !ended else { return }; ended = true; onEnd(self) }
    func check() throws {
        if case .failure(let error) = result { throw error }
        try Task.checkCancellation()
    }
}
