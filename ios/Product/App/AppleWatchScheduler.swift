import Foundation
import BackgroundTasks
import UserNotifications
import OpenWeightsCore

@MainActor final class AppleWatchScheduler: WatchScheduling {
    static let taskIdentifier = "org.experimentalmachines.openweights.watches"
    private static let prefix = "openweights.watch."
    private let center: UNUserNotificationCenter
    private let store: WatchStore
    private(set) var authorization = WatchNotificationAuthorization.notRequested
    private(set) var schedulingWarning: String?
    private var queue: [@MainActor () async -> Void] = []
    private var worker: Task<Void, Never>?
    init(store: WatchStore, center: UNUserNotificationCenter = .current()) { self.store = store; self.center = center }
    private func serial<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.append {
                do { continuation.resume(returning: try await operation()) }
                catch { continuation.resume(throwing: error) }
            }
            if worker == nil {
                worker = Task {
                    while !self.queue.isEmpty { let operation = self.queue.removeFirst(); await operation() }
                    self.worker = nil
                }
            }
        }
    }
    func requestPermission() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        await readAuthorization()
    }
    private func readAuthorization() async {
        switch (await center.notificationSettings()).authorizationStatus {
        case .authorized, .provisional, .ephemeral: authorization = .enabled
        case .notDetermined: authorization = .notRequested
        case .denied: authorization = .denied
        @unknown default: authorization = .unavailable
        }
    }
    func update(_ watches: [ScheduledWatch], at date: Date) async throws {
        try await serial { try await self.apply(watches, at: date) }
    }
    private func apply(_ watches: [ScheduledWatch], at date: Date) async throws {
        await readAuthorization()
        let byID = Dictionary(uniqueKeysWithValues: watches.map { ($0.id.uuidString, $0) })
        let pending = await center.pendingNotificationRequests()
        let obsolete = pending.filter { request in
            guard request.identifier.hasPrefix(Self.prefix) else { return false }
            guard let id = request.content.userInfo["watchID"] as? String, let watch = byID[id] else { return true }
            return request.identifier.hasPrefix(Self.prefix + "due.") || request.identifier.hasPrefix(Self.prefix + "window.") || request.content.userInfo["watchTask"] as? String != watch.task
        }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: obsolete)
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter { notification in
            let request = notification.request
            guard request.identifier.hasPrefix(Self.prefix) else { return false }
            guard let id = request.content.userInfo["watchID"] as? String, let watch = byID[id] else { return true }
            return request.identifier.hasPrefix(Self.prefix + "due.") || request.content.userInfo["watchTask"] as? String != watch.task
        }.map { $0.request.identifier })
        let active = watches.filter { $0.state == .active && !$0.isSpent(at: date) }
        if authorization == .enabled {
            for watch in active {
                if watch.claim == nil {
                    let content = content(watch: watch, kind: "due", title: "Watch check due",
                        body: "\(watch.task.prefix(160))\nOpen OpenWeights to run the due check. This reminder is not a completed check.")
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, watch.nextDueAt.timeIntervalSince(date)), repeats: false)
                    try await center.add(UNNotificationRequest(identifier: Self.prefix + "due." + watch.id.uuidString, content: content, trigger: trigger))
                }
                let ending = content(watch: watch, kind: "window", title: "Watch window ended",
                    body: "The 72-hour window for \(watch.task.prefix(120)) has ended. Open OpenWeights to review its completed checks.")
                try await center.add(UNNotificationRequest(identifier: Self.prefix + "window." + watch.id.uuidString, content: ending,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, watch.expiresAt.timeIntervalSince(date)), repeats: false)))
            }
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        schedulingWarning = nil
        let eligible = watches.filter { [.active, .paused].contains($0.state) }
        if let due = eligible.map({ $0.state == .paused ? $0.expiresAt : min($0.nextDueAt, $0.expiresAt) }).min() {
            let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
            request.earliestBeginDate = max(date.addingTimeInterval(1), due)
            request.requiresExternalPower = false; request.requiresNetworkConnectivity = false
            do { try BGTaskScheduler.shared.submit(request) }
            catch { schedulingWarning = "iOS did not accept a background check request. Keep the app open or return for catch-up. Due reminders still work when notifications are enabled." }
        }
    }
    func post(_ notice: WatchNotice, watch: ScheduledWatch) async throws -> Bool {
        try await serial {
            await self.readAuthorization()
            guard self.authorization == .enabled, let current = await self.store.watch(watch.id),
                  current.resultNotice?.id == notice.id || current.endNotice?.id == notice.id else { return false }
            let identifier = Self.prefix + notice.kind.rawValue + "." + watch.id.uuidString
            let delivered = await self.center.deliveredNotifications()
            let pending = await self.center.pendingNotificationRequests()
            if delivered.contains(where: { $0.request.identifier == identifier && $0.request.content.userInfo["noticeID"] as? String == notice.id.uuidString }) ||
                pending.contains(where: { $0.identifier == identifier && $0.content.userInfo["noticeID"] as? String == notice.id.uuidString }) { return true }
            let title = notice.kind == .result ? String(watch.task.prefix(80)) : "Watch ended"
            let content = self.content(watch: watch, kind: notice.kind.rawValue, title: title, body: notice.body)
            content.userInfo["noticeID"] = notice.id.uuidString
            try await self.center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            return true
        }
    }
    private func content(watch: ScheduledWatch, kind: String, title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        content.userInfo = ["watchID": watch.id.uuidString, "watchTask": watch.task, "watchKind": kind]
        return content
    }
}
