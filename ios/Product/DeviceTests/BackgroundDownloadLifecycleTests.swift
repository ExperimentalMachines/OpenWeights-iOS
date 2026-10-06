import Foundation
import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

private struct BackgroundDownloadMarker: Codable {
    var model: LocalModel
    var preparedPID: Int32
    var preexistingModelIDs: [UUID]
    var started: Bool
    var scenario: String?
    var phase: String?
    var exitingTaskIdentifier: Int?
}
extension ProductTests {
    func testNativeFullBackgroundDownloadedModelChatAndPreservation() async throws {
        try await verifyBackgroundDownloadedModel(interrupted: false)
    }
    func testNativeInterruptedBackgroundDownloadedModelChatAndPreservation() async throws {
        try await verifyBackgroundDownloadedModel(interrupted: true)
    }
    func testNativeProcessReattachedBackgroundModelChatAndPreservation() async throws {
        try await verifyBackgroundDownloadedModel(interrupted: false, reattached: true)
    }
    func testNativeExecutionExpiredBackgroundModelChatAndPreservation() async throws {
        try await verifyBackgroundDownloadedModel(interrupted: false, expired: true)
    }
    private func verifyBackgroundDownloadedModel(interrupted: Bool, reattached: Bool = false, expired: Bool = false) async throws {
#if OW_BACKGROUND_DOWNLOAD_VALIDATION
        XCTFail("This acceptance method requires the standard product build.")
        return
#else
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWeights/BackgroundDownloadValidation")
        let marker = try JSONDecoder().decode(BackgroundDownloadMarker.self, from: Data(contentsOf: root.appendingPathComponent("marker.json")))
        let lines = try String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n")
        let events = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let background = events.filter { ($0["event"] as? String) == "os-background-session-handler" && ($0["applicationState"] as? Int) == 2 }
        if expired {
            XCTAssertEqual(marker.scenario, "execution-expiry")
            XCTAssertEqual(marker.phase, "execution-expired")
            let grant = try XCTUnwrap(events.first { ($0["event"] as? String) == "validation-execution-grant-begin" })
            XCTAssertEqual(grant["granted"] as? Bool, true)
            XCTAssertEqual(grant["applicationState"] as? Int, 0)
            let expiration = try XCTUnwrap(events.first { ($0["event"] as? String) == "os-execution-expiration-handler" })
            XCTAssertEqual(expiration["grantValid"] as? Bool, true)
            XCTAssertEqual(expiration["applicationState"] as? Int, 2)
            XCTAssertEqual(expiration["modelState"] as? String, "downloading")
            XCTAssertEqual(expiration["committedBytes"] as? Int64, 40589248)
            let task = try XCTUnwrap((expiration["tasks"] as? [[String: Any]])?.first)
            XCTAssertEqual(task["range"] as? String, "bytes=33554432-1107613951")
            let received = try XCTUnwrap(task["receivedBytes"] as? Int64)
            XCTAssertGreaterThan(received, 0); XCTAssertLessThan(received, try XCTUnwrap(task["expectedBytes"] as? Int64))
            let ended = try XCTUnwrap(events.first { ($0["event"] as? String) == "validation-execution-grant-end" })
            XCTAssertEqual(ended["reason"] as? String, "os-expiration")
            let requests = events.filter { ($0["event"] as? String) == "task-scheduled" && ($0["range"] as? String) == "bytes=33554432-1107613951" }
            XCTAssertEqual(requests.count, 1)
            let request = try XCTUnwrap(requests.first)
            let arrival = try XCTUnwrap(events.first { ($0["event"] as? String) == "delegate-arrival" && ($0["taskIdentifier"] as? Int) == (request["taskIdentifier"] as? Int) })
            XCTAssertEqual(arrival["applicationState"] as? Int, 2)
            XCTAssertEqual(arrival["range"] as? String, "bytes 33554432-1107613951/1107613952")
            XCTAssertLessThan(try XCTUnwrap(expiration["uptime"] as? Double), try XCTUnwrap(ended["uptime"] as? Double))
            XCTAssertLessThan(try XCTUnwrap(ended["uptime"] as? Double), try XCTUnwrap(arrival["uptime"] as? Double))
            XCTAssertFalse(events.contains { ["will-enter-foreground", "did-become-active", "controlled-process-exit-request", "background-inflight-pause-trigger"].contains($0["event"] as? String ?? "") })
            XCTAssertGreaterThanOrEqual(background.count, 1)
        } else if reattached {
            XCTAssertEqual(marker.scenario, "process-reattachment")
            let exit = try XCTUnwrap(events.first { ($0["event"] as? String) == "controlled-process-exit-request" })
            XCTAssertEqual(exit["pid"] as? Int32, marker.preparedPID)
            XCTAssertEqual(exit["applicationState"] as? Int, 2)
            XCTAssertEqual(exit["signal"] as? String, "SIGKILL")
            let received = try XCTUnwrap(exit["receivedBytes"] as? Int64)
            XCTAssertGreaterThan(received, 0); XCTAssertLessThan(received, try XCTUnwrap(exit["expectedBytes"] as? Int64))
            let checkpoint = try XCTUnwrap(events.first { ($0["event"] as? String) == "armed-nonzero-checkpoint-awaiting-user-background" })
            XCTAssertEqual(exit["checkpointBytes"] as? Int64, 33554432)
            XCTAssertEqual(exit["checkpointSHA256"] as? String, checkpoint["checkpointSHA256"] as? String)
            let ended = try XCTUnwrap(events.first { ($0["event"] as? String) == "validation-execution-grant-end" })
            XCTAssertEqual(ended["reason"] as? String, "controlled-process-exit")
            let launch = try XCTUnwrap(events.first { ($0["event"] as? String) == "cold-process-launch-observer" })
            XCTAssertNotEqual(launch["pid"] as? Int32, marker.preparedPID)
            XCTAssertEqual(launch["applicationState"] as? Int, 2)
            XCTAssertTrue(background.contains { ($0["pid"] as? Int32) == (launch["pid"] as? Int32) })
            let arrival = try XCTUnwrap(events.first { ($0["event"] as? String) == "delegate-arrival" && ($0["taskIdentifier"] as? Int) == marker.exitingTaskIdentifier })
            XCTAssertEqual(arrival["pid"] as? Int32, launch["pid"] as? Int32)
            XCTAssertEqual(arrival["applicationState"] as? Int, 2)
            XCTAssertEqual(arrival["range"] as? String, "bytes 33554432-1107613951/1107613952")
            XCTAssertFalse(events.contains { ($0["event"] as? String) == "task-scheduled" && ($0["pid"] as? Int32) == (launch["pid"] as? Int32) })
        } else if interrupted {
            XCTAssertEqual(marker.scenario, "nonzero-background-interruption")
            let grant = try XCTUnwrap(events.first { ($0["event"] as? String) == "validation-execution-grant-begin" })
            XCTAssertEqual(grant["granted"] as? Bool, true)
            let ended = try XCTUnwrap(events.first { ($0["event"] as? String) == "validation-execution-grant-end" })
            XCTAssertEqual(ended["reason"] as? String, "controlled-pause-resume-finished")
            let checkpoint = try XCTUnwrap(events.first { ($0["event"] as? String) == "armed-nonzero-checkpoint-awaiting-user-background" })
            let trigger = try XCTUnwrap(events.first { ($0["event"] as? String) == "background-inflight-pause-trigger" })
            let paused = try XCTUnwrap(events.first { ($0["event"] as? String) == "background-pause-checkpoint-preserved" })
            let resumed = try XCTUnwrap(events.first { ($0["event"] as? String) == "background-resume-after-controlled-pause" })
            XCTAssertEqual(checkpoint["applicationState"] as? Int, 0)
            for event in [trigger, paused, resumed] { XCTAssertEqual(event["applicationState"] as? Int, 2) }
            XCTAssertEqual(trigger["range"] as? String, "bytes=33554432-1107613951")
            let received = try XCTUnwrap(trigger["receivedBytes"] as? Int64)
            let expected = try XCTUnwrap(trigger["expectedBytes"] as? Int64)
            XCTAssertGreaterThan(received, 0); XCTAssertLessThan(received, expected)
            for event in [checkpoint, trigger, paused] {
                XCTAssertEqual(event["checkpointBytes"] as? Int64, 33554432)
                XCTAssertEqual(event["checkpointSHA256"] as? String, checkpoint["checkpointSHA256"] as? String)
            }
            XCTAssertTrue((paused["tasks"] as? [[String: Any]])?.isEmpty == true)
            let cancelledID = try XCTUnwrap(trigger["taskIdentifier"] as? Int)
            XCTAssertFalse(events.contains { ($0["event"] as? String) == "delegate-arrival" && ($0["taskIdentifier"] as? Int) == cancelledID })
            let requests = events.filter { ($0["event"] as? String) == "task-scheduled" && ($0["range"] as? String) == "bytes=33554432-1107613951" }
            XCTAssertEqual(requests.count, 2)
            XCTAssertTrue(requests.allSatisfy { ($0["applicationState"] as? Int) == 2 })
            XCTAssertGreaterThanOrEqual(background.count, 1)
            XCTAssertTrue(events.contains { ($0["event"] as? String) == "delegate-arrival" && ($0["applicationState"] as? Int) == 2 && ($0["range"] as? String) == "bytes 33554432-1107613951/1107613952" })
        } else {
            XCTAssertGreaterThanOrEqual(background.count, 3)
            XCTAssertTrue(events.contains { ($0["event"] as? String) == "delegate-arrival" && ($0["applicationState"] as? Int) == 2 && ($0["range"] as? String) == "bytes 0-1107613951/1107613952" })
        }
        let verified = try XCTUnwrap(events.last { ($0["event"] as? String) == "complete-files-independently-verified" })
        XCTAssertEqual(verified["applicationState"] as? Int, 2)
        XCTAssertEqual(verified["completeBytes"] as? Int64, 1114648768)
        XCTAssertEqual(verified["preexistingModelIDsPreserved"] as? Bool, true)
        let downloads = try XCTUnwrap(ProductDelegate.productState.downloads)
        await downloads.restore()
        var model = try XCTUnwrap(downloads.models.first { $0.id == marker.model.id })
        XCTAssertEqual(model.state, .ready)
        XCTAssertTrue(marker.preexistingModelIDs.allSatisfy { id in downloads.models.contains { $0.id == id } })
        var hashes: [String: String] = [:]
        for expected in NativeCompiledArtifact.qwen25().files {
            let destination = try expected.destination(in: downloads.directory(model))
            try await Task.detached { try ModelFileTransfer.verify(destination, file: expected) }.value
            hashes[expected.path] = try await Task.detached { try ModelFileTransfer.hash(destination) }.value
            XCTAssertEqual(hashes[expected.path], expected.sha256)
        }
        let suite = "background-download-chat-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1; model.settings.outputTokens = 96
        try await downloads.save(model)
        var observations: [String: Any] = ["modelID": model.id.uuidString, "backgroundProcessIdentifier": marker.preparedPID,
            "standardTestProcessIdentifier": ProcessInfo.processInfo.processIdentifier, "independentFullFileSHA256": hashes,
            "backgroundHandlerCount": background.count, "fullCompletionState": "background", "completed": false]
        defer {
            let evidence: [String: Any] = ["purpose": expired ? "native-standard-build-execution-expired-background-model-chat-and-preservation" : (reattached ? "native-standard-build-process-reattached-background-model-chat-and-preservation" : (interrupted ? "native-standard-build-interrupted-background-model-chat-and-preservation" : "native-standard-build-full-background-downloaded-model-chat-and-preservation")),
                "observations": observations, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations": ["Reads a retained actual-background validation journal, then tests the same owned artifact under the standard product build with the observer compiled out.", "The journal records the specific controlled scenario. Complete selected files have independent pinned hashes. Validation-only independent verification delays the OS completion callback; the standard build does not add that extra hash pass.", expired ? "Actual OS expiry concerns a validation-only UIKit execution grant during network transfer. No watch-task expiry, file-copy interruption, natural OS termination, force-quit, touch, VoiceOver, energy or general-quality claim." : "Chat uses its own conversation store and preference suite with the production model library. No touch, VoiceOver, natural OS termination, expiry, energy or general-quality claim."]]
            let attachment = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "native-background-download-standard-chat.json"; attachment.lifetime = .keepAlways; add(attachment)
        }
        do {
            let chat = ChatController(store: try ConversationStore(file: root.appendingPathComponent("chat.json")), downloads: downloads, defaults: defaults)
            await chat.load(model); XCTAssertNil(chat.error)
            chat.draft = "Reply with exactly Cedar."; await chat.send()
            try await waitUntil(seconds: 90) { !chat.busy }
            XCTAssertNil(chat.error)
            let first = try XCTUnwrap(chat.current?.messages.last { $0.role == .assistant }?.content).trimmingCharacters(in: .whitespacesAndNewlines)
            observations["firstAnswer"] = first; XCTAssertTrue(first == "Cedar" || first == "Cedar.")
            guard first == "Cedar" || first == "Cedar." else { return }
            let store = try ConversationStore(file: root.appendingPathComponent("chat.json"))
            let saved = try await store.conversation(try XCTUnwrap(chat.current?.id))
            await chat.open(saved); XCTAssertNil(chat.error)
            chat.draft = "What is 2 + 2? Reply with only the number."; await chat.send()
            try await waitUntil(seconds: 90) { !chat.busy }
            XCTAssertNil(chat.error)
            let answer = try XCTUnwrap(chat.current?.messages.last { $0.role == .assistant }?.content).trimmingCharacters(in: .whitespacesAndNewlines)
            observations["reopenedAnswer"] = answer; XCTAssertEqual(answer, "4")
            guard answer == "4" else { return }
        }
        try await downloads.remove(model)
        XCTAssertFalse(downloads.models.contains { $0.id == model.id })
        XCTAssertTrue(marker.preexistingModelIDs.allSatisfy { id in downloads.models.contains { $0.id == id } })
        observations["testModelRemovedPreexistingModelsPreserved"] = true
        observations["completed"] = true
        try FileManager.default.removeItem(at: root)
#endif
    }
}
