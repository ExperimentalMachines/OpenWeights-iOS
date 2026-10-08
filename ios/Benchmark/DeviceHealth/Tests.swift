import XCTest
import UIKit

final class DeviceHealthTests: XCTestCase {
    @MainActor
    func testLaunchAndAttachDeviceConditions() throws {
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(Bundle.main.bundleIdentifier,
                       "org.experimentalmachines.openweights.benchmark")
        XCTAssertTrue(ProcessInfo.processInfo.physicalMemory > 0)
        XCTAssertFalse(UIApplication.shared.windows.isEmpty, "The test host must create its window")
        var system = utsname()
        XCTAssertEqual(uname(&system), 0)
        let model = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let snapshot: [String: Any] = [
            "purpose": "firebase-device-launch-diagnostic-no-inference",
            "device": model,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "applicationState": UIApplication.shared.applicationState.rawValue,
            "protectedDataAvailable": UIApplication.shared.isProtectedDataAvailable,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
            "inferenceExecuted": false
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(
            withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]),
            uniformTypeIdentifier: "public.json")
        attachment.name = "device-launch-conditions.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAttachStorageConditionsWithoutInferenceOrCleanup() throws {
        let manager = FileManager.default
        let caches = try XCTUnwrap(manager.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let support = try XCTUnwrap(manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let storage = StorageSnapshot.capture(
            volumeURL: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), directories: [
            ("default-CoreML-cache", caches.appendingPathComponent("executorchcoreml")),
            ("default-CoreML-trash", manager.temporaryDirectory.appendingPathComponent("executorchcoreml")),
            ("default-CoreML-database", support.appendingPathComponent("executorchcoreml"))
        ])
        let attachment = XCTAttachment(data: try JSONEncoder().encode(storage),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "device-storage-conditions.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Capacity observations are diagnostic. A missing or small value does
        // not justify deleting files or treating this device as runtime-compatible.
        XCTAssertEqual(storage.directories.count, 3)
    }
}
