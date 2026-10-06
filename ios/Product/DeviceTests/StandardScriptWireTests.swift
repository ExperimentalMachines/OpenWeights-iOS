#if !OW_SCRIPT_SECURITY_VALIDATION
import XCTest
import ExtensionFoundation
import XPC
@testable import OpenWeights

private struct UndeclaredScriptAction: Codable {
    let action: String
    let id = UUID()
    let source = ""
    let inputsJSON = "{}"
}
@MainActor extension ProductTests {
    func testNativeStandardScriptHelperRefusesValidationWireActions() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The isolated helper requires iOS 26.") }
        let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .scriptSandbox)
        let expected = (Bundle.main.bundleIdentifier ?? "") + ".script"
        let identity = try XCTUnwrap(monitor.identities.first { $0.bundleIdentifier == expected })
        let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity))
        defer { process.invalidate() }
        let channel = try process.makeXPCSession(); try channel.activate()
        defer { channel.cancel(reason: "Standard wire refusal checks completed.") }
        var refused: [String] = []
        for action in ["validateAccess", "terminateForValidation"] {
            let reply: ScriptWireReply = try await withCheckedThrowingContinuation { continuation in
                do {
                    try channel.send(UndeclaredScriptAction(action: action)) { (result: Result<ScriptWireReply, Error>) in continuation.resume(with: result) }
                } catch { continuation.resume(throwing: error) }
            }
            XCTAssertTrue(reply.failed); XCTAssertTrue(reply.output.hasPrefix("Request decoding failed:"))
            XCTAssertNotEqual(reply.processID, getpid()); XCTAssertGreaterThan(reply.processID, 0)
            guard reply.failed, reply.output.hasPrefix("Request decoding failed:") else { return }
            refused.append(action)
        }
        let observation: [String: Any] = ["purpose": "native-standard-script-helper-validation-actions-refused", "completed": refused.count == 2,
            "hostPID": getpid(), "refusedActions": refused,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString]
        let data = try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
