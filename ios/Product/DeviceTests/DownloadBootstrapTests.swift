import Foundation
import XCTest
@testable import OpenWeights

extension ProductTests {
    func testNativeDownloadBootstrapEarlyCallbacksAndCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-bootstrap-native-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let observations = try await DownloadBootstrapChecks.run(root: root)
        XCTAssertEqual((observations["passedChecks"] as? [String])?.count, 9)
        let value: [String: Any] = ["purpose": "native-controlled-background-download-bootstrap", "observations": observations,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "download-bootstrap-controls.json"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
