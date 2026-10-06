#if OW_BACKGROUND_DOWNLOAD_VALIDATION
import Foundation
import UIKit
import Darwin
import OpenWeightsCore

// This observer is absent from standard builds. It requests no extra background
// time for ordinary acquisition. Controlled scenarios request a UIKit grant to
// observe Pause, process exit or actual OS grant expiration during networking.
// It uses the ordinary production manager/session rather than a test session.
@MainActor enum BackgroundDownloadValidation {
    private struct Marker: Codable {
        var model: LocalModel
        var preparedPID: Int32
        var preexistingModelIDs: [UUID]
        var started: Bool
        var scenario: String?
        var phase: String?
        var executionGrant: Bool?
        var exitingTaskIdentifier: Int?
    }
    private static let identity = "OWBackgroundDownloadValidationMarker-v1"
    private static var observing = false
    private static var manager: ModelDownloads?
    private static var marker: Marker?
    private static var timer: Timer?
    private static var observers: [NSObjectProtocol] = []
    private static var lastTick: TimeInterval?
    private static var verification: Task<Void, Never>?
    private static var verified = false
    private static var executionGrant: UIBackgroundTaskIdentifier = .invalid
    private static var grantSafety: Task<Void, Never>?
    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWeights/BackgroundDownloadValidation")
    }
    private static var markerURL: URL { folder.appendingPathComponent("marker.json") }
    // Capture cold background entry before restoration can drain daemon callbacks.
    static func captureLaunch(_ downloads: ModelDownloads) {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        do {
            marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
            manager = downloads
            record("cold-process-launch-observer", fields: ["preparedPID": marker?.preparedPID ?? -1,
                "scenario": marker?.scenario ?? "", "phase": marker?.phase ?? ""])
        } catch { NSLog("Background validation launch capture failed: %@", error.localizedDescription) }
    }
    static func start(_ downloads: ModelDownloads) async {
        guard !observing else { return }
        let mode = ProcessInfo.processInfo.environment["OW_BACKGROUND_DOWNLOAD_VALIDATION"]
        guard mode == "prepare" || mode == "prepare-interruption" || mode == "prepare-interruption-granted" || mode == "prepare-reattachment" || mode?.hasPrefix("prepare-expiry") == true || FileManager.default.fileExists(atPath: markerURL.path) else { return }
        observing = true; manager = downloads
        do {
            if mode == "prepare-expiry-retry", FileManager.default.fileExists(atPath: markerURL.path) {
                let prior = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
                guard prior.model.id.uuidString == ProcessInfo.processInfo.environment["OW_BACKGROUND_DOWNLOAD_RETAINED_MODEL"],
                      prior.scenario == "execution-expiry", prior.phase == "awaiting-execution-budget", prior.started,
                      let owned = downloads.models.first(where: { $0.id == prior.model.id }), owned.state == .paused,
                      owned.repository == "experimentalmachines/Qwen2.5-1.5B-Instruct-ExecuTorch",
                      owned.revision == "0a912670f4bf6039d0192cc420960039bff0d402",
                      downloads.diagnosticSnapshot().isEmpty,
                      prior.preexistingModelIDs.allSatisfy({ id in downloads.models.contains { $0.id == id } }) else {
                    throw ModelError.unsupported("Retain and identify the incomplete expiry fixture before retrying.")
                }
                let directory = downloads.directory(owned)
                try await Task.detached {
                    for file in owned.files {
                        let destination = try file.destination(in: directory)
                        if file.path == owned.entryFile {
                            let partial = destination.appendingPathExtension("partial")
                            guard try ModelFileTransfer.byteCount(partial) == 33554432,
                                  try ModelFileTransfer.hash(partial) == "679229877c0cc4c874ee354217373046e3ae4444082a8d92f5d81251d97852ea" else { throw ModelError.corrupt(file.path) }
                        } else { try ModelFileTransfer.verify(destination, file: file) }
                    }
                }.value
                try await downloads.remove(owned)
                try FileManager.default.removeItem(at: folder)
            }
            if mode == "prepare-interruption-granted", FileManager.default.fileExists(atPath: markerURL.path) {
                let prior = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
                guard prior.scenario == "nonzero-background-interruption", prior.phase == "interruptible-background-range",
                      let owned = downloads.models.first(where: { $0.id == prior.model.id }), owned.state == .ready,
                      owned.repository == "experimentalmachines/Qwen2.5-1.5B-Instruct-ExecuTorch",
                      owned.revision == "0a912670f4bf6039d0192cc420960039bff0d402",
                      prior.preexistingModelIDs.allSatisfy({ id in downloads.models.contains { $0.id == id } }) else {
                    throw ModelError.unsupported("Preserve the prior validation fixture until its completed outcome is retained.")
                }
                let directory = downloads.directory(owned)
                try await Task.detached {
                    for file in owned.files { try ModelFileTransfer.verify(file.destination(in: directory), file: file) }
                }.value
                try await downloads.remove(owned)
                try FileManager.default.removeItem(at: folder)
            }
            if FileManager.default.fileExists(atPath: markerURL.path) {
                marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
            } else {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let repository = "experimentalmachines/Qwen2.5-1.5B-Instruct-ExecuTorch"
                let revision = "0a912670f4bf6039d0192cc420960039bff0d402"
                let entry = "xnnpack/Qwen2.5-1.5B-Instruct-8da4w-2k.pte"
                let details = try await HubClient.details(repository, revision: revision, transport: HubAPITransport(useStoredCredential: false))
                guard let selected = details.siblings.first(where: { $0.rfilename == entry }) else { throw ModelError.corrupt(entry) }
                var model = try await HubClient.compiled(details, file: selected, useStoredCredential: false)
                guard model.files.first(where: { $0.path == entry })?.sha256 == "be2c11bbe75269f03a95b0407f6bcb976b7282daf259f522850281e614f711dd",
                      model.files.first(where: { $0.path == entry })?.bytes == 1107613952,
                      !downloads.models.contains(where: { $0.repository == repository && $0.revision == revision && $0.entryFile == entry }) else {
                    throw ModelError.unsupported("The validation artifact is already installed or its pin changed. Preserve it and inspect before proceeding.")
                }
                model.name = "Background validation Qwen2.5 1.5B"
                marker = Marker(model: model, preparedPID: ProcessInfo.processInfo.processIdentifier,
                    preexistingModelIDs: downloads.models.map(\.id), started: false,
                    scenario: mode?.hasPrefix("prepare-expiry") == true ? "execution-expiry" : (mode == "prepare-reattachment" ? "process-reattachment" : (mode?.hasPrefix("prepare-interruption") == true ? "nonzero-background-interruption" : nil)),
                    phase: mode?.hasPrefix("prepare-expiry") == true || mode == "prepare-reattachment" || mode?.hasPrefix("prepare-interruption") == true ? "preparing-checkpoint" : nil,
                    executionGrant: mode?.hasPrefix("prepare-expiry") == true || mode == "prepare-interruption-granted" || mode == "prepare-reattachment", exitingTaskIdentifier: nil)
                try saveMarker()
            }
            record("observer-start", fields: ["markerIdentity": identity, "preparedPID": marker?.preparedPID ?? -1,
                "productionSessionIdentifier": "org.experimentalmachines.openweights.models"])
            for (notification, event) in [(UIApplication.didEnterBackgroundNotification, "did-enter-background"),
                                          (UIApplication.willEnterForegroundNotification, "will-enter-foreground"),
                                          (UIApplication.didBecomeActiveNotification, "did-become-active"),
                                          (UIApplication.willResignActiveNotification, "will-resign-active")] {
                observers.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { _ in
                    Task { @MainActor in
                        record(event)
                        if notification == UIApplication.didEnterBackgroundNotification { await beginTransfer() }
                    }
                })
            }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in await tick() } }
            if marker?.phase == "preparing-checkpoint", let fixture = marker {
                record("foreground-checkpoint-preparation-begin")
                await downloads.install(fixture.model)
            } else {
                record(marker?.started == true ? "reconnected-observer" : "armed-awaiting-user-background")
            }
        } catch { record("observer-error", fields: ["error": error.localizedDescription]) }
    }
    private static func saveMarker() throws {
        guard let marker else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(to: markerURL, options: .atomic)
    }
    private static func beginTransfer() async {
        guard let downloads = manager, var next = marker, !next.started else { return }
        if next.scenario != nil {
            guard next.phase == "armed-checkpoint" else { return }
            next.phase = next.scenario == "execution-expiry" ? "awaiting-execution-budget" : (next.scenario == "process-reattachment" ? "transfer-before-controlled-exit" : "interruptible-background-range")
        }
        next.started = true; marker = next
        do { try saveMarker() } catch { record("marker-write-error", fields: ["error": error.localizedDescription]); return }
        if next.scenario == "execution-expiry" {
            // The reported budget is meaningful only after real background entry
            // with a grant begun in the foreground. Leave the network in flight
            // when UIKit expires the grant, without simulating that callback.
            var remaining = UIApplication.shared.backgroundTimeRemaining
            for attempt in 0..<4 {
                if remaining.isFinite, remaining > 0, remaining < 600 { break }
                record("expiry-budget-transition-sample", fields: ["attempt": attempt,
                    "reportedValue": String(remaining), "grantValid": executionGrant != .invalid])
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard executionGrant != .invalid, marker?.phase == "awaiting-execution-budget",
                      UIApplication.shared.applicationState == .background else { return }
                remaining = UIApplication.shared.backgroundTimeRemaining
            }
            guard executionGrant != .invalid, remaining.isFinite, remaining > 0, remaining < 600 else {
                record("expiry-budget-unavailable", fields: ["grantValid": executionGrant != .invalid, "reportedValue": String(remaining)])
                endExecutionGrant(reason: "invalid-expiry-budget"); return
            }
            let delay = max(0, remaining - 8)
            record("expiry-budget-observed", fields: ["remainingSeconds": remaining, "delaySeconds": delay])
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard executionGrant != .invalid, marker?.phase == "awaiting-execution-budget",
                  UIApplication.shared.applicationState == .background else {
                record("expiry-transfer-not-started"); endExecutionGrant(reason: "expiry-transfer-not-started"); return
            }
            next.phase = "transfer-before-execution-expiry"; marker = next
            do { try saveMarker() } catch { record("marker-write-error", fields: ["error": error.localizedDescription]); endExecutionGrant(reason: "marker-write-error"); return }
            let budget = UIApplication.shared.backgroundTimeRemaining
            record("expiry-transfer-resume", fields: ["remainingSeconds": budget.isFinite && budget < 600 ? budget : -1])
        } else if next.executionGrant == true {
            grantSafety = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                endExecutionGrant(reason: "bounded-timeout")
            }
        }
        record("install-begin", modelID: next.model.id)
        if next.scenario != nil, let model = downloads.models.first(where: { $0.id == next.model.id }) {
            await downloads.resume(model)
        } else { await downloads.install(next.model) }
        record("install-return", modelID: next.model.id, fields: ["error": downloads.error ?? "",
            "tasks": downloads.diagnosticSnapshot()])
    }
    // Pause at a completed foreground checkpoint before the next range is scheduled.
    // Only the validation build changes transfer timing for this controlled scenario.
    static func didCommit(modelID: UUID, filePath: String) async {
        guard let downloads = manager, var fixture = marker, fixture.model.id == modelID,
              fixture.scenario != nil, fixture.phase == "preparing-checkpoint",
              filePath == fixture.model.entryFile,
              UIApplication.shared.applicationState == .active,
              let model = downloads.models.first(where: { $0.id == modelID }) else { return }
        do {
            guard let file = model.files.first(where: { $0.path == filePath }) else { throw ModelError.corrupt(filePath) }
            let partial = try file.destination(in: downloads.directory(model)).appendingPathExtension("partial")
            guard try ModelFileTransfer.byteCount(partial) == 33554432 else { throw ModelError.corrupt(filePath) }
            await downloads.pause(model)
            fixture.phase = "armed-checkpoint"; marker = fixture; try saveMarker()
            record("armed-nonzero-checkpoint-awaiting-user-background", modelID: modelID,
                fields: ["checkpointBytes": 33554432, "checkpointSHA256": try ModelFileTransfer.hash(partial), "tasks": downloads.diagnosticSnapshot()])
            if fixture.executionGrant == true {
                executionGrant = UIApplication.shared.beginBackgroundTask(withName: "OpenWeights controlled download lifecycle") {
                    if marker?.scenario == "execution-expiry" { captureExecutionExpiration() }
                    endExecutionGrant(reason: "os-expiration")
                }
                record("validation-execution-grant-begin", fields: ["granted": executionGrant != .invalid])
            }
        } catch { record("checkpoint-preparation-error", modelID: modelID, fields: ["error": error.localizedDescription]) }
    }
    private static func captureExecutionExpiration() {
        guard let downloads = manager, var fixture = marker else { return }
        fixture.phase = "execution-expired"; marker = fixture
        // Keep the OS handler short: durable metadata and task counters only.
        // Full-file verification belongs to the later normal arrival path.
        do { try saveMarker() } catch { record("marker-write-error", fields: ["error": error.localizedDescription]) }
        let model = downloads.models.first { $0.id == fixture.model.id }
        record("os-execution-expiration-handler", fields: ["grantValid": executionGrant != .invalid,
            "modelState": model?.state.rawValue ?? "absent", "committedBytes": model.map(downloads.committedBytes) ?? 0,
            "tasks": downloads.diagnosticSnapshot()])
    }
    static func didReceive(modelID: UUID, filePath: String, taskID: Int, range: String, received: Int64, expected: Int64) async {
        if let downloads = manager, var fixture = marker, fixture.model.id == modelID,
           fixture.scenario == "process-reattachment", fixture.phase == "transfer-before-controlled-exit",
           filePath == fixture.model.entryFile, UIApplication.shared.applicationState == .background,
           range == "bytes=33554432-1107613951", received > 0, received < expected,
           let model = downloads.models.first(where: { $0.id == modelID }) {
            do {
                guard let file = model.files.first(where: { $0.path == filePath }) else { throw ModelError.corrupt(filePath) }
                let partial = try file.destination(in: downloads.directory(model)).appendingPathExtension("partial")
                guard try ModelFileTransfer.byteCount(partial) == 33554432 else { throw ModelError.corrupt(filePath) }
                fixture.phase = "awaiting-process-reattachment"; fixture.exitingTaskIdentifier = taskID
                marker = fixture; try saveMarker()
                record("controlled-process-exit-request", modelID: modelID,
                    fields: ["signal": "SIGKILL", "taskIdentifier": taskID, "range": range,
                        "receivedBytes": received, "expectedBytes": expected, "checkpointBytes": 33554432,
                        "checkpointSHA256": try ModelFileTransfer.hash(partial), "tasks": downloads.diagnosticSnapshot()])
                endExecutionGrant(reason: "controlled-process-exit")
                // Only this validation process ends. The ordinary daemon task is not
                // cancelled or paused, and its durable model state remains downloading.
                let result = Darwin.kill(Darwin.getpid(), SIGKILL)
                record("controlled-process-exit-unexpected-return", fields: ["result": result])
            } catch { record("controlled-process-exit-error", fields: ["error": error.localizedDescription]) }
            return
        }
        guard let downloads = manager, var fixture = marker, fixture.model.id == modelID,
              fixture.scenario == "nonzero-background-interruption", fixture.phase == "interruptible-background-range",
              filePath == fixture.model.entryFile, UIApplication.shared.applicationState == .background,
              range == "bytes=33554432-1107613951", received > 0, received < expected,
              let model = downloads.models.first(where: { $0.id == modelID }) else { return }
        // Claim the trigger before yielding so subsequent progress events cannot pause twice.
        fixture.phase = "controlled-pause-triggered"; marker = fixture
        defer { endExecutionGrant(reason: "controlled-pause-resume-finished") }
        do {
            try saveMarker()
            guard let file = model.files.first(where: { $0.path == filePath }) else { throw ModelError.corrupt(filePath) }
            let partial = try file.destination(in: downloads.directory(model)).appendingPathExtension("partial")
            let before = try ModelFileTransfer.hash(partial)
            record("background-inflight-pause-trigger", modelID: modelID,
                fields: ["taskIdentifier": taskID, "range": range, "receivedBytes": received, "expectedBytes": expected,
                         "checkpointBytes": try ModelFileTransfer.byteCount(partial), "checkpointSHA256": before])
            await downloads.pause(model)
            let after = try ModelFileTransfer.hash(partial)
            guard try ModelFileTransfer.byteCount(partial) == 33554432, after == before,
                  downloads.models.first(where: { $0.id == modelID })?.state == .paused,
                  downloads.diagnosticSnapshot().isEmpty else { throw ModelError.corrupt(filePath) }
            fixture.phase = "resuming-after-controlled-pause"; marker = fixture; try saveMarker()
            record("background-pause-checkpoint-preserved", modelID: modelID,
                fields: ["checkpointBytes": 33554432, "checkpointSHA256": after, "tasks": downloads.diagnosticSnapshot()])
            guard let paused = downloads.models.first(where: { $0.id == modelID }) else { throw ModelError.corrupt(filePath) }
            await downloads.resume(paused)
            record("background-resume-after-controlled-pause", modelID: modelID, fields: ["tasks": downloads.diagnosticSnapshot()])
        } catch { record("background-interruption-error", modelID: modelID, fields: ["error": error.localizedDescription]) }
    }
    private static func endExecutionGrant(reason: String) {
        guard executionGrant != .invalid else { return }
        let identifier = executionGrant; executionGrant = .invalid
        grantSafety?.cancel(); grantSafety = nil
        record("validation-execution-grant-end", fields: ["reason": reason])
        UIApplication.shared.endBackgroundTask(identifier)
    }
    private static func tick() async {
        let now = ProcessInfo.processInfo.systemUptime
        let gap = lastTick.map { now - $0 } ?? 0; lastTick = now
        guard let downloads = manager, let fixture = marker else { return }
        let model = downloads.models.first(where: { $0.id == fixture.model.id })
        record("heartbeat", modelID: fixture.model.id, fields: ["gapSeconds": gap, "modelState": model?.state.rawValue ?? "absent",
            "committedBytes": model.map(downloads.committedBytes) ?? 0, "tasks": downloads.diagnosticSnapshot()])
        await verifyReady()
    }
    static func verifyReady() async {
        if let verification { await verification.value; return }
        guard let downloads = manager, let fixture = marker,
              let model = downloads.models.first(where: { $0.id == fixture.model.id }), model.state == .ready, !verified else { return }
        let work = Task { @MainActor in
            do {
                let directory = downloads.directory(model)
                let hashes = try await Task.detached { () throws -> [String: String] in
                    var values: [String: String] = [:]
                    for file in model.files {
                        let destination = try file.destination(in: directory)
                        try ModelFileTransfer.verify(destination, file: file)
                        values[file.path] = try ModelFileTransfer.hash(destination)
                    }
                    return values
                }.value
                verified = true
                record("complete-files-independently-verified", modelID: model.id, fields: ["sha256": hashes,
                    "completeBytes": downloads.committedBytes(model), "preexistingModelIDsPreserved": fixture.preexistingModelIDs.allSatisfy { id in downloads.models.contains { $0.id == id } }])
            } catch { record("verification-error", modelID: model.id, fields: ["error": error.localizedDescription]) }
        }
        verification = work
        await work.value
        verification = nil
    }
    static func record(_ event: String, modelID: UUID? = nil, fields: [String: Any] = [:]) {
        guard manager != nil, modelID == nil || modelID == marker?.model.id else { return }
        do {
            var value = fields
            value["event"] = event; value["modelID"] = modelID?.uuidString ?? marker?.model.id.uuidString ?? ""
            value["pid"] = ProcessInfo.processInfo.processIdentifier
            value["uptime"] = ProcessInfo.processInfo.systemUptime
            value["atUTC"] = ISO8601DateFormatter().string(from: Date())
            value["applicationState"] = UIApplication.shared.applicationState.rawValue
            let log = folder.appendingPathComponent("events.jsonl")
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
            try handle.seekToEnd()
            var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10)
            try handle.write(contentsOf: data); try handle.synchronize()
        } catch { NSLog("Background download validation record failed: %@", error.localizedDescription) }
    }
}
#endif
