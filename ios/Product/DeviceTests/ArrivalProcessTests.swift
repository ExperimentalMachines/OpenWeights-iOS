import Foundation
import UIKit
import XCTest
import OpenWeightsCore
@testable import OpenWeights

private final class ArrivalValidationTask: URLSessionDownloadTask, @unchecked Sendable {
    let descriptor: String
    let request: URLRequest
    let receivedResponse: URLResponse
    init(model: LocalModel, url: URL, response: URLResponse) {
        descriptor = model.id.uuidString + ":" + model.entryFile + ":0"
        request = URLRequest(url: url); receivedResponse = response; super.init()
    }
    override var taskIdentifier: Int { 741 }
    override var taskDescription: String? { get { descriptor } set {} }
    override var originalRequest: URLRequest? { request }
    override var response: URLResponse? { receivedResponse }
}
private actor ArrivalValidationGate {
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { waiting = $0 } }
}
private struct ArrivalValidationMarker: Codable {
    let preparedPID: Int32
    let model: LocalModel
    let checkpointBytes: Int64
    let priorOwner: UUID
}
extension ProductTests {
    private var arrivalValidationRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWeights/DownloadArrivalValidation")
    }
    func testNativeArrivalProcessPrepare() async throws {
        let root = arrivalValidationRoot
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw ModelError.unsupported("A prior arrival fixture exists. Finish its second phase before preparing another.")
        }
        let store = try ModelLibrary(file: root.appendingPathComponent("models.json"))
        let bytes = Data(repeating: 19, count: 4 * 1024 * 1024 + 11)
        let temporary = root.appendingPathComponent("delegate-temporary")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: temporary)
        let url = URL(string: "https://huggingface.co/fixture/model/resolve/pin/weights.pte")!
        let file = ModelFile(path: "xnnpack/model.pte", bytes: Int64(bytes.count), sha256: try ModelFileTransfer.hash(temporary), url: url)
        let model = LocalModel(name: "Controlled saved arrival", backend: .xnnpack, entryFile: file.path, files: [file])
        try await store.save(model)
        let gate = ArrivalValidationGate()
        var listings = 0
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: store,
            sessionIdentifier: "org.experimentalmachines.openweights.arrival-prepare." + UUID().uuidString,
            sessionConfiguration: .ephemeral, taskListing: { _ in listings += 1; await gate.wait(); return [] })
        downloads.handleBackgroundEvents { XCTFail("Held restoration must not call background completion") }
        try await waitUntil(seconds: 5) { listings == 1 }
        let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes 0-\(bytes.count - 1)/\(bytes.count)"])!
        let callback = ArrivalValidationTask(model: model, url: url, response: response)
        let eventSession = URLSession(configuration: .ephemeral)
        defer { eventSession.invalidateAndCancel() }
        downloads.urlSession(eventSession, downloadTask: callback, didFinishDownloadingTo: temporary)
        let directory = downloads.directory(model)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let manifest = directory.appendingPathComponent(try XCTUnwrap(names.first { $0.hasPrefix("arrival-") && $0.hasSuffix(".json") }))
        let arrival = try JSONDecoder().decode(ModelDownloadArrival.self, from: Data(contentsOf: manifest))
        let destination = try file.destination(in: directory)
        // A controlled persisted prefix represents interrupted copying. The process
        // boundary is real, while this write is a fixture, not an OS-timed copy kill.
        let checkpoint = Int64(1024 * 1024 + 3)
        try bytes.prefix(Int(checkpoint)).write(to: destination.appendingPathExtension("partial"))
        let marker = ArrivalValidationMarker(preparedPID: ProcessInfo.processInfo.processIdentifier, model: model,
            checkpointBytes: checkpoint, priorOwner: arrival.owner)
        try JSONEncoder().encode(marker).write(to: root.appendingPathComponent("marker.json"), options: .atomic)
        arrivalProcessAttachment(["phase": "prepare", "completed": true, "processIdentifier": marker.preparedPID,
            "checkpointBytes": checkpoint, "modelID": model.id.uuidString, "priorOwner": arrival.owner.uuidString,
            "completeBytes": bytes.count, "expectedSHA256": file.sha256 ?? "", "journalFile": manifest.lastPathComponent])
    }
    func testNativeArrivalProcessFinish() async throws {
        let root = arrivalValidationRoot
        let marker = try JSONDecoder().decode(ArrivalValidationMarker.self, from: Data(contentsOf: root.appendingPathComponent("marker.json")))
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertNotEqual(pid, marker.preparedPID)
        guard pid != marker.preparedPID else { return }
        let store = try ModelLibrary(file: root.appendingPathComponent("models.json"))
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: store,
            sessionIdentifier: "org.experimentalmachines.openweights.arrival-finish." + UUID().uuidString)
        defer { downloads.cancelAllTransfers() }
        let expected = try XCTUnwrap(marker.model.files.first)
        let destination = try expected.destination(in: downloads.directory(marker.model))
        XCTAssertEqual(try ModelFileTransfer.byteCount(destination.appendingPathExtension("partial")), marker.checkpointBytes)
        await downloads.restore()
        let restored = try XCTUnwrap(downloads.models.first)
        XCTAssertEqual(restored.id, marker.model.id); XCTAssertEqual(restored.state, .ready, restored.failure ?? downloads.error ?? "")
        XCTAssertNil(downloads.error)
        guard restored.state == .ready else { return }
        try ModelFileTransfer.verify(destination, file: expected)
        let stored = await store.list(); XCTAssertEqual(stored, [restored])
        let names = try FileManager.default.contentsOfDirectory(atPath: downloads.directory(restored).path)
        XCTAssertFalse(names.contains { $0.hasPrefix("arrival-") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
        XCTAssertTrue(downloads.diagnosticSnapshot().isEmpty)
        let hash = try ModelFileTransfer.hash(destination), count = try ModelFileTransfer.byteCount(destination)
        arrivalProcessAttachment(["phase": "finish", "completed": true, "preparedPID": marker.preparedPID,
            "processIdentifier": pid, "checkpointBytes": marker.checkpointBytes, "priorOwner": marker.priorOwner.uuidString,
            "modelID": restored.id.uuidString, "completeBytes": count, "completeSHA256": hash,
            "durableReadyMetadata": true, "remainingArrivalNames": names.filter { $0.hasPrefix("arrival-") }])
        try FileManager.default.removeItem(at: root)
    }
    private func arrivalProcessAttachment(_ observations: [String: Any]) {
        let value: [String: Any] = ["purpose": "native-persisted-arrival-across-observed-process-restart", "observations": observations,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations": ["Two hosted XCTest phases use distinct real app processes and a test-owned durable root. The fixture leaves a synthetic 4 MiB plus 11-byte completed response and manually writes a 1 MiB plus 3-byte prefix while task enumeration is held.", "Stage publication and next-process restore use actual ModelDownloads/ModelDownloadArrival/ModelFileTransfer. This is not an OS-timed copy interruption, automatic background launch, suspended daemon transfer, actual model export/inference, gesture, quality or A2 result. The first process's exit cause requires external evidence."]]
        let attachment = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "native-arrival-process.json"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
