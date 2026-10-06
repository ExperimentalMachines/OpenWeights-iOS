import Foundation
import ExtensionFoundation
import XPC
import Metal

@main struct InferenceHelper: AppExtension {
    @AppExtensionPoint.Bind var extensionPoint: AppExtensionPoint {
        #if OW_BENCHMARK_SLOT
        AppExtensionPoint.Identifier(host: "org.experimentalmachines.openweights.benchmark", name: "InferenceHelper")
        #else
        AppExtensionPoint.Identifier(host: "org.experimentalmachines.openweights.ios", name: "InferenceHelper")
        #endif
    }
    var configuration: some AppExtensionConfiguration {
        ConnectionHandler(onSessionRequest: { request in request.accept { session in InferencePeer(session: session) } })
    }
}

private final class InferencePeer: XPCPeerHandler, @unchecked Sendable {
    typealias Input = XPCDictionary
    typealias Output = XPCDictionary
    private let worker = DispatchQueue(label: "org.experimentalmachines.inference.worker")
    private let lock = NSLock()
    private var admitted = false
    private var closed = false
    private let session: XPCSession
    init(session: XPCSession) { self.session = session }

    func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
        let accepted = lock.withLock { () -> Bool in
            guard !closed, !admitted else { return false }
            admitted = true; return true
        }
        guard accepted else { return reply(stage: "admission", error: "The inference connection is closed or busy.") }
        // Keep the incoming dictionary alive until its asynchronous reply is sent.
        worker.async { [self] in
            defer { lock.withLock { admitted = false } }
            message.reply(run(message))
        }
        return nil
    }

    func handleCancellation(error: XPCRichError) { lock.withLock { closed = true } }

    private func reply(stage: String, error: String = "", text: String = "", modelSize: Int64 = 0, tokenizerSize: Int64 = 0) -> XPCDictionary {
        let response = XPCDictionary()
        response.withUnsafeUnderlyingDictionary { raw in
            xpc_dictionary_set_string(raw, "stage", stage)
            xpc_dictionary_set_string(raw, "error", error)
            xpc_dictionary_set_string(raw, "text", text)
            xpc_dictionary_set_int64(raw, "processID", Int64(getpid()))
            xpc_dictionary_set_int64(raw, "modelBytes", modelSize)
            xpc_dictionary_set_int64(raw, "tokenizerBytes", tokenizerSize)
            xpc_dictionary_set_bool(raw, "metalAvailable", MTLCreateSystemDefaultDevice() != nil)
        }
        return response
    }

    private func run(_ message: XPCDictionary) -> XPCDictionary {
        let model = message.withUnsafeUnderlyingDictionary { xpc_dictionary_dup_fd($0, "model") }
        let tokenizer = message.withUnsafeUnderlyingDictionary { xpc_dictionary_dup_fd($0, "tokenizer") }
        defer { if model >= 0 { close(model) }; if tokenizer >= 0 { close(tokenizer) } }
        var modelStat = stat(), tokenizerStat = stat()
        let modelFlags = fcntl(model, F_GETFL), modelFlagsError = errno
        let tokenizerFlags = fcntl(tokenizer, F_GETFL), tokenizerFlagsError = errno
        let modelResult = fstat(model, &modelStat), modelStatError = errno
        let tokenizerResult = fstat(tokenizer, &tokenizerStat), tokenizerStatError = errno
        guard model >= 0, tokenizer >= 0,
              modelFlags >= 0, tokenizerFlags >= 0, modelFlags & O_ACCMODE == O_RDONLY, tokenizerFlags & O_ACCMODE == O_RDONLY,
              modelResult == 0, tokenizerResult == 0,
              modelStat.st_mode & S_IFMT == S_IFREG, tokenizerStat.st_mode & S_IFMT == S_IFREG,
              modelStat.st_size == 646_789_248, tokenizerStat.st_size == 11_422_654 else {
            let detail = "Expected read-only regular files: model fd=\(model), flags=\(modelFlags), flagsError=\(modelFlagsError), stat=\(modelResult), statError=\(modelStatError), mode=\(modelStat.st_mode), size=\(modelStat.st_size); tokenizer fd=\(tokenizer), flags=\(tokenizerFlags), flagsError=\(tokenizerFlagsError), stat=\(tokenizerResult), statError=\(tokenizerStatError), mode=\(tokenizerStat.st_mode), size=\(tokenizerStat.st_size). Error codes matter only for failed calls."
            return reply(stage: "descriptor-validation", error: detail, modelSize: modelStat.st_size, tokenizerSize: tokenizerStat.st_size)
        }
        guard MTLCreateSystemDefaultDevice() != nil else {
            return reply(stage: "metal-capability", error: "Metal is unavailable in the inference helper.", modelSize: modelStat.st_size, tokenizerSize: tokenizerStat.st_size)
        }
        let result = OWRunMLXDescriptorProbeWithProgress(model, tokenizer) { [self] stage, footprint in
            let value = XPCDictionary()
            value.withUnsafeUnderlyingDictionary {
                xpc_dictionary_set_string($0, "progress", stage)
                xpc_dictionary_set_int64($0, "processID", Int64(getpid()))
                xpc_dictionary_set_uint64($0, "footprintBytes", footprint)
                xpc_dictionary_set_uint64($0, "availableMemoryBytes", OWDescriptorAvailableMemory())
            }
            // The host records and acknowledges a stage before native work proceeds.
            // Its overall probe deadline terminates this process on a stalled peer.
            _ = try? session.sendSync(message: value)
        }
        return reply(stage: result["stage"] as? String ?? "invalid-native-reply", error: result["error"] as? String ?? "Missing native error status.", text: result["text"] as? String ?? "", modelSize: modelStat.st_size, tokenizerSize: tokenizerStat.st_size)
    }
}
