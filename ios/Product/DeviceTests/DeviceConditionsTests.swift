import XCTest
import UIKit
@testable import OpenWeights

extension ProductTests {
    @MainActor func nativeDeviceConditions() -> [String: Any] {
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        let battery = UIDevice.current.batteryLevel
        return ["observedAtUTC":ISO8601DateFormatter().string(from: Date()), "thermalStateRaw":thermal,
                "batteryLevel":battery, "batteryStateRaw":UIDevice.current.batteryState.rawValue,
                "batteryMonitoringEnabled":UIDevice.current.isBatteryMonitoringEnabled,
                "watchGuardWouldHalt":thermal == ProcessInfo.ThermalState.critical.rawValue || (battery >= 0 && battery < 0.15),
                "backgroundWatchHaltReason":ChatController.systemWatchHaltReason(background: true) ?? "",
                "foregroundWorkHaltReason":ChatController.systemGoalHaltReason() ?? "",
                "applicationStateRaw":UIApplication.shared.applicationState.rawValue]
    }

    @MainActor func testNativeRecordDeviceConditions() async throws {
        let prior = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        defer { UIDevice.current.isBatteryMonitoringEnabled = prior }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while UIDevice.current.batteryLevel < 0 && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for:.milliseconds(50)) }
        var value = nativeDeviceConditions()
        value["purpose"] = "native-real-device-conditions-observation"
        value["completed"] = true
        value["operatingSystem"] = ProcessInfo.processInfo.operatingSystemVersionString
        value["limitations"] = ["A current device-condition snapshot after the failed cohort, not a measurement of conditions at its earlier failures or proof of their cause."]
        let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json");attachment.name = "Current iPhone conditions";attachment.lifetime = .keepAlways;add(attachment)
    }
}
