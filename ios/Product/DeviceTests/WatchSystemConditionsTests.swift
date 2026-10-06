import XCTest
import UIKit
import UserNotifications
import BackgroundTasks
@testable import OpenWeights

extension ProductTests {
    @MainActor func testNativeWatchSystemPermissionsAndPendingRequests() async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let notifications = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let tasks: [BGTaskRequest] = await withCheckedContinuation { continuation in
            BGTaskScheduler.shared.getPendingTaskRequests { continuation.resume(returning: $0) }
        }
        let actualWatches = await ProductDelegate.productState.watches?.store.list() ?? []
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        let identifiers = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        let value: [String: Any] = ["purpose":"native-watch-OS-permissions-and-pending-requests-read-only", "completed":true,
            "notificationAuthorizationRaw":settings.authorizationStatus.rawValue,
            "alertSettingRaw":settings.alertSetting.rawValue, "soundSettingRaw":settings.soundSetting.rawValue,
            "notificationCenterSettingRaw":settings.notificationCenterSetting.rawValue,
            "lockScreenSettingRaw":settings.lockScreenSetting.rawValue,
            "backgroundRefreshStatusRaw":UIApplication.shared.backgroundRefreshStatus.rawValue,
            "applicationStateRaw":UIApplication.shared.applicationState.rawValue,
            "pendingNotificationIdentifiers":notifications.map { $0.identifier },
            "deliveredNotificationIdentifiers":delivered.map { $0.request.identifier },
            "pendingBackgroundTasks":tasks.map { task -> [String: Any] in
                var result: [String: Any] = ["identifier":task.identifier, "kind":String(describing:type(of:task)),
                    "earliestBeginDate":task.earliestBeginDate.map { ISO8601DateFormatter().string(from:$0) } ?? ""]
                if let processing = task as? BGProcessingTaskRequest {
                    result["requiresExternalPower"] = processing.requiresExternalPower
                    result["requiresNetworkConnectivity"] = processing.requiresNetworkConnectivity
                }
                return result
            }, "savedProductWatchCount":actualWatches.count,
            "backgroundModes":modes, "permittedBackgroundIdentifiers":identifiers,
            "operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations":["Read-only actual iOS settings/queues. No permission request, task submission, notification send/removal, model inference or UI interaction.",
                "Pending request configuration does not prove OS launch, expiry or notification delivery. No notification task/body text is copied."]]
        let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name = "Watch system settings and pending requests"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(modes.contains("processing"))
        XCTAssertTrue(identifiers.contains(AppleWatchScheduler.taskIdentifier))
    }
}
