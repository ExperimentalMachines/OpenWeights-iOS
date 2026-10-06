import XCTest
import UIKit
import BackgroundTasks
import UserNotifications
import OpenWeightsCore
@testable import OpenWeights

@MainActor private func pendingWatchTasks() async -> [BGTaskRequest] {
    await withCheckedContinuation { continuation in
        BGTaskScheduler.shared.getPendingTaskRequests { continuation.resume(returning:$0) }
    }
}
@MainActor private func watchSchedulerWait(_ condition: () async -> Bool, seconds: Double = 20) async throws {
    let until = ProcessInfo.processInfo.systemUptime + seconds
    while await !condition() {
        guard ProcessInfo.processInfo.systemUptime < until else { throw URLError(.timedOut) }
        try await Task.sleep(for:.milliseconds(50))
    }
}
@MainActor private func requireEmptyProductWatchQueues() async throws {
    let saved = await ProductDelegate.productState.watches?.store.list() ?? []
    let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
    let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
    let tasks = await pendingWatchTasks()
    guard saved.isEmpty,
          !pending.contains(where: { $0.identifier.hasPrefix("openweights.watch.") }),
          !delivered.contains(where: { $0.request.identifier.hasPrefix("openweights.watch.") }),
          !tasks.contains(where: { $0.identifier == AppleWatchScheduler.taskIdentifier }) else {
        throw XCTSkip("Real product watches or requests are present. This fixture will not replace them.")
    }
}
@MainActor private func ownedWatchNotificationIDs(_ id: UUID) -> [String] {
    ["due", "window", "result", "ended"].map { "openweights.watch." + $0 + "." + id.uuidString }
}

@MainActor private final class WatchNotificationRecorder: NSObject, UNUserNotificationCenterDelegate {
    let previous: ProductDelegate
    let owned: Set<String>
    private(set) var events: [[String:Any]] = []
    init(previous: ProductDelegate, owned: [String]) { self.previous = previous; self.owned = Set(owned) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            self.previous.userNotificationCenter(center,willPresent:notification) { presentation in
                Task { @MainActor in
                    let request = notification.request
                    if self.owned.contains(request.identifier) {
                        self.events.append(["identifier":request.identifier, "kind":request.content.userInfo["watchKind"] as? String ?? "",
                            "noticeID":request.content.userInfo["noticeID"] as? String ?? "", "title":request.content.title,
                            "body":request.content.body, "presentationOptionsRaw":presentation.rawValue,
                            "observedAtUTC":ISO8601DateFormatter().string(from:Date())])
                    }
                    completionHandler(presentation)
                }
            }
        }
    }
}

extension ProductTests {
    @MainActor func testNativeAppleWatchNotificationPermissionAndDelivery() async throws {
        try await requireEmptyProductWatchQueues()
        try await watchSchedulerWait { UIApplication.shared.applicationState == .active }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-OS-notifications-" + UUID().uuidString)
        let store = try WatchStore(file:root.appendingPathComponent("watches.json"))
        let center = UNUserNotificationCenter.current(), scheduler = AppleWatchScheduler(store:store)
        let previous = try XCTUnwrap(center.delegate as? ProductDelegate)
        let before = await center.notificationSettings()
        var completed = false, observations: [String:Any] = ["authorizationBeforeRaw":before.authorizationStatus.rawValue]
        var owned: [String] = [], recorder: WatchNotificationRecorder?
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            center.delegate = previous; UIApplication.shared.isIdleTimerDisabled = idle
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:AppleWatchScheduler.taskIdentifier)
            center.removePendingNotificationRequests(withIdentifiers:owned); center.removeDeliveredNotifications(withIdentifiers:owned)
            try? FileManager.default.removeItem(at:root)
            let value: [String:Any] = ["purpose":"native-Apple-watch-notification-permission-and-OS-delivery", "completed":completed,
                "observations":observations, "OSForegroundDeliveryEvents":recorder?.events ?? [], "operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations":["Uses actual iOS notification permission, queues and framework delivery callbacks. The test forwards through the original ProductDelegate presentation policy.",
                    "Seeded owned WatchStore results test notification delivery, not model inference. The 72-hour ending uses a controlled store clock.",
                    "Foreground OS callbacks do not prove background/lock-screen delivery, a visible banner, sound or touch interaction. Denial verifies refusal/persistence only.",
                    "Existing product watches/requests cause a skip. Only owned notification IDs are removed. Notification authorization remains the user's system choice."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Actual notification permission and delivery"; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await scheduler.requestPermission()
        let after = await center.notificationSettings()
        observations["authorizationAfterRaw"] = after.authorizationStatus.rawValue
        observations["schedulerAuthorization"] = scheduler.authorization.rawValue
        let watch = try await store.start(task:"Owned native notification fixture",everyMinutes:1,at:Date().addingTimeInterval(-59))
        owned = ownedWatchNotificationIDs(watch.id)
        let delegate = WatchNotificationRecorder(previous:previous,owned:owned); recorder = delegate; center.delegate = delegate
        try await scheduler.update(await store.list(),at:Date())
        if scheduler.authorization != .enabled {
            let pending = await center.pendingNotificationRequests().filter { owned.contains($0.identifier) }
            XCTAssertTrue(pending.isEmpty)
            let ticketValue = try await store.begin(watch.id,at:watch.nextDueAt.addingTimeInterval(1))
            let ticket = try XCTUnwrap(ticketValue)
            _ = try await store.record(ticket,outcome:.checked,summary:"Owned seeded result while notifications are denied",at:watch.nextDueAt.addingTimeInterval(2),changed:true)
            let savedValue = await store.watch(watch.id)
            let saved = try XCTUnwrap(savedValue), notice = try XCTUnwrap(saved.resultNotice)
            let posted = try await scheduler.post(notice,watch:saved)
            XCTAssertFalse(posted)
            let reopened = try WatchStore(file:root.appendingPathComponent("watches.json")); let durable = await reopened.watch(watch.id)
            XCTAssertEqual(durable?.resultNotice,notice)
            observations["branch"] = "permission-refused-no-notification-and-durable-result-retained"
            observations["posted"] = posted; observations["ownedPendingCount"] = pending.count
            observations["durableNoticeRetained"] = durable?.resultNotice == notice
            completed = !posted && pending.isEmpty && durable?.resultNotice == notice
            return
        }
        observations["branch"] = "permission-enabled-foreground-OS-delivery"
        let pending = await center.pendingNotificationRequests().filter { owned.contains($0.identifier) }
        XCTAssertTrue(pending.contains { $0.identifier == owned[1] })
        XCTAssertTrue(Set(pending.map(\.identifier)).isSubset(of:Set(owned.prefix(2))))
        observations["initialPendingIdentifiers"] = pending.map(\.identifier)
        try await watchSchedulerWait { delegate.events.contains { $0["kind"] as? String == "due" } }
        let due = try XCTUnwrap(delegate.events.first { $0["kind"] as? String == "due" })
        XCTAssertEqual(due["presentationOptionsRaw"] as? UInt,0)
        XCTAssertTrue((due["body"] as? String)?.contains("not a completed check") == true)
        let ticketValue = try await store.begin(watch.id,at:Date())
        let ticket = try XCTUnwrap(ticketValue)
        _ = try await store.record(ticket,outcome:.checked,summary:"Owned seeded OS notification result",at:Date(),changed:true)
        let savedValue = await store.watch(watch.id)
        let saved = try XCTUnwrap(savedValue), notice = try XCTUnwrap(saved.resultNotice)
        let posted = try await scheduler.post(notice,watch:saved)
        XCTAssertTrue(posted)
        try await watchSchedulerWait { delegate.events.contains { $0["kind"] as? String == "result" } }
        let result = try XCTUnwrap(delegate.events.first { $0["kind"] as? String == "result" })
        XCTAssertEqual(result["noticeID"] as? String,notice.id.uuidString)
        XCTAssertEqual(result["body"] as? String,notice.body)
        let expectedPresentation: UNNotificationPresentationOptions = [.banner,.sound,.list]
        XCTAssertEqual(result["presentationOptionsRaw"] as? UInt,expectedPresentation.rawValue)
        try await watchSchedulerWait { await center.deliveredNotifications().contains { $0.request.identifier == owned[2] } }
        let postedAgain = try await scheduler.post(notice,watch:saved)
        XCTAssertTrue(postedAgain)
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertEqual(delegate.events.filter { $0["kind"] as? String == "result" }.count,1)
        observations["duplicatePostDeliveredOnce"] = delegate.events.filter { $0["kind"] as? String == "result" }.count == 1
        try await store.acknowledgeNotice(watchID:watch.id,noticeID:notice.id)
        let reopened = try WatchStore(file:root.appendingPathComponent("watches.json")); let acknowledged = await reopened.watch(watch.id)
        XCTAssertNil(acknowledged?.resultNotice); XCTAssertEqual(acknowledged?.lastSummary,notice.body)
        observations["acknowledgedNoticeReopened"] = acknowledged?.resultNotice == nil && acknowledged?.lastSummary == notice.body
        _ = try await store.expire(at:watch.expiresAt)
        let expiredValue = await store.watch(watch.id)
        let expired = try XCTUnwrap(expiredValue), end = try XCTUnwrap(expired.endNotice)
        try await scheduler.update(await store.list(),at:Date())
        let endingPosted = try await scheduler.post(end,watch:expired)
        XCTAssertTrue(endingPosted)
        try await watchSchedulerWait { delegate.events.contains { $0["kind"] as? String == "ended" } }
        let ending = try XCTUnwrap(delegate.events.first { $0["kind"] as? String == "ended" })
        XCTAssertEqual(ending["noticeID"] as? String,end.id.uuidString); XCTAssertEqual(ending["body"] as? String,end.body)
        try await store.forget(watch.id); try await scheduler.update(await store.list(),at:Date())
        try await watchSchedulerWait {
            let pending = await center.pendingNotificationRequests(), delivered = await center.deliveredNotifications()
            return !pending.contains { owned.contains($0.identifier) } && !delivered.contains { owned.contains($0.request.identifier) }
        }
        observations["ownedNotificationsRemovedAfterForget"] = true
        observations["frameworkEventKinds"] = delegate.events.compactMap { $0["kind"] as? String }
        completed = delegate.events.filter { $0["kind"] as? String == "due" }.count == 1 && delegate.events.filter { $0["kind"] as? String == "result" }.count == 1 && delegate.events.filter { $0["kind"] as? String == "ended" }.count == 1
    }

    @MainActor func testNativeAppleWatchBackgroundRequestManagement() async throws {
        try await requireEmptyProductWatchQueues()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-OS-requests-" + UUID().uuidString)
        let store = try WatchStore(file:root.appendingPathComponent("watches.json"))
        let scheduler = AppleWatchScheduler(store:store)
        let center = UNUserNotificationCenter.current()
        let now = Date()
        let watch = try await store.start(task:"Owned native scheduler request fixture",everyMinutes:1,at:now)
        let owned = ownedWatchNotificationIDs(watch.id)
        var completed = false, observations: [[String:Any]] = []
        defer {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:AppleWatchScheduler.taskIdentifier)
            center.removePendingNotificationRequests(withIdentifiers:owned)
            center.removeDeliveredNotifications(withIdentifiers:owned)
            try? FileManager.default.removeItem(at:root)
            let value: [String:Any] = ["purpose":"native-actual-BGProcessingTaskRequest-create-pause-resume-stop", "completed":completed,
                "observations":observations, "operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations":["Actual iOS task submission and pending queues through production AppleWatchScheduler, with an app-owned isolated WatchStore and no inference.",
                    "Fixture refuses existing product watches/queues and removes only its owned notification IDs. The sole task identifier is used only after proving no existing request.",
                    "Pending requests do not prove framework launch, expiration, OS-granted cadence, suspension or notification delivery. No permission request is made."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Actual background request management"; attachment.lifetime = .keepAlways; add(attachment)
        }
        func check(_ label: String, date: Date?) async throws {
            let tasks = await pendingWatchTasks().filter { $0.identifier == AppleWatchScheduler.taskIdentifier }
            observations.append(["stage":label, "requestCount":tasks.count, "schedulerWarning":scheduler.schedulingWarning ?? "",
                "notificationAuthorization":scheduler.authorization.rawValue,
                "requests":tasks.map { request -> [String:Any] in
                    ["identifier":request.identifier, "kind":String(describing:type(of:request)),
                     "earliestBeginDate":request.earliestBeginDate.map { ISO8601DateFormatter().string(from:$0) } ?? "",
                     "requiresExternalPower":(request as? BGProcessingTaskRequest)?.requiresExternalPower ?? true,
                     "requiresNetworkConnectivity":(request as? BGProcessingTaskRequest)?.requiresNetworkConnectivity ?? true]
                }])
            XCTAssertNil(scheduler.schedulingWarning)
            if let date {
                XCTAssertEqual(tasks.count,1)
                let request = try XCTUnwrap(tasks.first as? BGProcessingTaskRequest)
                XCTAssertEqual(try XCTUnwrap(request.earliestBeginDate).timeIntervalSince1970,date.timeIntervalSince1970,accuracy:0.1)
                XCTAssertFalse(request.requiresExternalPower); XCTAssertFalse(request.requiresNetworkConnectivity)
            } else { XCTAssertTrue(tasks.isEmpty) }
        }
        try await scheduler.update(await store.list(),at:now); try await check("created",date:watch.nextDueAt)
        _ = try await store.pause(watch.id)
        try await scheduler.update(await store.list(),at:now); try await check("paused-window-expiry-only",date:watch.expiresAt)
        let resumed = try await store.resume(watch.id,at:now.addingTimeInterval(1))
        try await scheduler.update(await store.list(),at:now); try await check("resumed-single-replacement",date:resumed.nextDueAt)
        _ = try await store.stop(watch.id)
        try await scheduler.update(await store.list(),at:now); try await check("stopped-no-request",date:nil)
        let reopened = try WatchStore(file:root.appendingPathComponent("watches.json")); let durable = await reopened.watch(watch.id)
        XCTAssertEqual(durable?.state,.stopped)
        completed = observations.count == 4 && durable?.state == .stopped && scheduler.schedulingWarning == nil
    }
}
