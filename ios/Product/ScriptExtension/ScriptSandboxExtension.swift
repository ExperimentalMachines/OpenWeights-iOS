import Foundation
import ExtensionFoundation
import XPC

@main struct ScriptSandboxExtension: AppExtension {
    @AppExtensionPoint.Bind var extensionPoint: AppExtensionPoint {
        #if OW_BENCHMARK_SLOT
        AppExtensionPoint.Identifier(host: "org.experimentalmachines.openweights.benchmark", name: "ScriptSandbox")
        #else
        AppExtensionPoint.Identifier(host: "org.experimentalmachines.openweights.ios", name: "ScriptSandbox")
        #endif
    }
    var configuration: some AppExtensionConfiguration {
        ConnectionHandler(onSessionRequest: { request in
            request.accept { _ in ScriptPeer() }
        })
    }
}

// Reply handoff leaves the XPC queue available to deliver cancellation while the
// interpreter runs. Every connection gets its own gate and fresh runtime per run.
private final class ScriptPeer: XPCPeerHandler, @unchecked Sendable {
    typealias Input = XPCReceivedMessage
    typealias Output = any Encodable
    private let queue = DispatchQueue(label: "org.experimentalmachines.script.worker")
    private let lock = NSLock()
    private var active: (UUID, OWScriptSession)?
    private var closed = false
    func handleIncomingRequest(_ incoming: XPCReceivedMessage) -> (any Encodable)? {
        let message: ScriptWireRequest
        do { message = try incoming.decode(as: ScriptWireRequest.self) }
        catch { return ScriptWireReply(id: UUID(), output: "Request decoding failed: \(error)", failed: true, processID: getpid()) }
        #if OW_SCRIPT_SECURITY_VALIDATION
        if message.action == .validateAccess || message.action == .terminateForValidation {
            return ScriptSandboxValidation.reply(to: message)
        }
        #endif
        if message.action == .cancel {
            lock.withLock { if active?.0 == message.id { active?.1.cancel() } }
            return ScriptWireReply(id: message.id, output: "Cancellation requested.", failed: true, processID: getpid())
        }
        guard message.source.utf8.count <= 72 * 1024, message.inputsJSON.utf8.count <= 400 * 1024 else {
            return ScriptWireReply(id: message.id, output: "The script request exceeds its resource limits.", failed: true, processID: getpid())
        }
        let interpreter = OWScriptSession()
        let admitted = lock.withLock { () -> Bool in
            guard !closed, active == nil else { return false }
            active = (message.id, interpreter); return true
        }
        guard admitted else { return ScriptWireReply(id: message.id, output: "The script connection is closed or busy.", failed: true, processID: getpid()) }
        return incoming.handoffReply(to: queue) { [self] in
            let value = interpreter.runSource(message.source, inputsJSON: message.inputsJSON)
            lock.withLock { active = nil }
            incoming.reply(ScriptWireReply(id: message.id, output: value["output"] as? String ?? "Missing script output.", failed: value["failed"] as? Bool ?? true, processID: getpid()))
        }
    }
    func handleCancellation(error: XPCRichError) {
        lock.withLock { closed = true; active?.1.cancel() }
    }
}
