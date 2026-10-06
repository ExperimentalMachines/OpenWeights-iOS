import Foundation

struct ScriptWireRequest: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case run, cancel
        #if OW_SCRIPT_SECURITY_VALIDATION
        case validateAccess, terminateForValidation
        #endif
    }
    let action: Action
    let id: UUID
    let source: String
    let inputsJSON: String
}
struct ScriptWireReply: Codable, Sendable {
    let id: UUID
    let output: String
    let failed: Bool
    let processID: Int32
}
