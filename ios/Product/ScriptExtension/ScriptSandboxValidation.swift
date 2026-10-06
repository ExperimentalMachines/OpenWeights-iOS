#if OW_SCRIPT_SECURITY_VALIDATION
import Foundation
import Darwin

// Compiled only by the explicit native-security validation build. Standard builds
// have neither these operations nor the corresponding wire action names.
enum ScriptSandboxValidation {
    static func reply(to request: ScriptWireRequest) -> ScriptWireReply {
        if request.action == .terminateForValidation {
            raise(SIGKILL)
            return ScriptWireReply(id: request.id, output: "Helper termination was refused.", failed: true, processID: getpid())
        }
        guard request.inputsJSON.utf8.count <= 4096,
              let data = request.inputsJSON.data(using: .utf8),
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = input["path"] as? String, path.utf8.count <= 2048,
              let rawPort = input["port"] as? Int, let port = UInt16(exactly: rawPort), port != 0 else {
            return ScriptWireReply(id: request.id, output: "Invalid validation fixture.", failed: true, processID: getpid())
        }
        let file = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let fileError = file < 0 ? errno : 0
        if file >= 0 { close(file) }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        let socketError = fd < 0 ? errno : 0
        var connection = Int32(-1), connectionError = socketError
        if fd >= 0 {
            defer { close(fd) }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            connection = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            connectionError = connection < 0 ? errno : 0
        }
        let output: [String: Any] = ["fileOpened": file >= 0, "fileErrno": fileError,
            "socketCreated": fd >= 0, "socketErrno": socketError,
            "connectionResult": connection, "connectionErrno": connectionError]
        let encoded = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        return ScriptWireReply(id: request.id, output: encoded.map { String(decoding: $0, as: UTF8.self) } ?? "Missing validation result.", failed: encoded == nil, processID: getpid())
    }
}
#endif
