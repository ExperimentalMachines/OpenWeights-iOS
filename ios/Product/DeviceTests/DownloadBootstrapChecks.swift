import Foundation
import OpenWeightsCore
#if canImport(OpenWeights)
@testable import OpenWeights
#endif

// A completed daemon task may no longer appear in allTasks when its delegate
// arrival is delivered. Substitute that boundary, while using the real controller.
private final class BootstrapDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    let identifier: Int
    let descriptor: String
    let request: URLRequest
    let receivedResponse: URLResponse
    private(set) var cancelled = false
    init(id: Int, modelID: UUID, path: String, offset: Int64, url: URL, response: URLResponse) {
        identifier = id; descriptor = modelID.uuidString + ":" + path + ":" + String(offset)
        request = URLRequest(url: url); receivedResponse = response; super.init()
    }
    override var taskIdentifier: Int { identifier }
    override var taskDescription: String? { get { descriptor } set {} }
    override var originalRequest: URLRequest? { request }
    override var response: URLResponse? { receivedResponse }
    override var state: URLSessionTask.State { .completed }
    override func cancel() { cancelled = true }
}
private actor BootstrapGate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiting.append($0) } } }
    func release() { open = true; for waiter in waiting { waiter.resume() }; waiting = [] }
}
@MainActor enum DownloadBootstrapChecks {
    private static func require(_ value: Bool, _ text: String) throws {
        if !value { throw ModelError.unsupported("Background bootstrap control: " + text) }
    }
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ModelError.unsupported("Background bootstrap control timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    static func run(root: URL) async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var passed: [String] = []
        let url = URL(string: "https://huggingface.co/fixture/model/resolve/pin/model.gguf")!
        let bytes = Data("GGUF-controlled-complete-arrival".utf8)
        let seed = root.appendingPathComponent("hash-seed"); try bytes.write(to: seed)
        let file = ModelFile(path: "xnnpack/model.pte", bytes: Int64(bytes.count), sha256: try ModelFileTransfer.hash(seed), url: url)
        let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes 0-\(bytes.count - 1)/\(bytes.count)"])!
        let library = try ModelLibrary(file: root.appendingPathComponent("models.json"))
        let model = LocalModel(name: "Early completed task", backend: .llamaCPU, entryFile: file.path, files: [file])
        try await library.save(model)
        let gate = BootstrapGate()
        var taskListings = 0
        let commitEntered = DispatchSemaphore(value: 0), releaseCommit = DispatchSemaphore(value: 0)
        defer { releaseCommit.signal() }
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: library,
            chunkCommit: { staged, destination, response, offset, file in
                commitEntered.signal()
                guard releaseCommit.wait(timeout: .now() + 5) == .success else { throw ModelError.unsupported("Held commit was not released") }
                try ModelDownloads.commitChunk(staged, destination: destination, response: response, offset: offset, file: file)
            }, sessionConfiguration: .ephemeral, taskListing: { _ in taskListings += 1; await gate.wait(); return [] })
        defer { downloads.cancelAllTransfers() }
        var completions = 0
        downloads.handleBackgroundEvents { completions += 1 }
        let firstRestore = Task { @MainActor in await downloads.restore() }
        let secondRestore = Task { @MainActor in await downloads.restore() }
        try await waitUntil { taskListings == 1 }
        let temporary = root.appendingPathComponent("delegate-temporary-file"); try bytes.write(to: temporary)
        let task = BootstrapDownloadTask(id: 41, modelID: model.id, path: file.path, offset: 0, url: url, response: response)
        let eventSession = URLSession(configuration: .ephemeral)
        defer { eventSession.invalidateAndCancel() }
        downloads.urlSession(eventSession, downloadTask: task, didWriteData: Int64(bytes.count), totalBytesWritten: Int64(bytes.count), totalBytesExpectedToWrite: Int64(bytes.count))
        downloads.urlSession(eventSession, downloadTask: task, didFinishDownloadingTo: temporary)
        downloads.urlSessionDidFinishEvents(forBackgroundURLSession: eventSession)
        try await Task.sleep(nanoseconds: 75_000_000)
        let destination = try file.destination(in: downloads.directory(model))
        let stages = try FileManager.default.contentsOfDirectory(atPath: downloads.directory(model).path)
        try require(stages.filter { $0.hasPrefix("arrival-") && $0.hasSuffix(".data") }.count == 1
            && stages.filter { $0.hasPrefix("arrival-") && $0.hasSuffix(".json") }.count == 1
            && !FileManager.default.fileExists(atPath: temporary.path), "Early delegate temporary file/body descriptor was not retained as an owned stage")
        try require(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path), "Nested destination parent was not created before file commit")
        try require(completions == 0 && !FileManager.default.fileExists(atPath: destination.path), "Completion or file commit escaped held task restoration")
        try require(taskListings == 1, "Scene/background restoration enumerated tasks more than once")
        passed.append("early-arrival-owned-before-return-and-held-until-coalesced-metadata-task-restoration")
        await gate.release()
        let entered = await Task.detached { commitEntered.wait(timeout: .now() + 3) == .success }.value
        try require(entered && completions == 0, "Background completion ran before held checksum/file commit finished")
        passed.append("background-completion-waits-for-accepted-file-validation-and-metadata-commit")
        releaseCommit.signal()
        await firstRestore.value; await secondRestore.value
        try await waitUntil { completions == 1 }
        try ModelFileTransfer.verify(destination, file: file)
        let readyState = await library.list().first?.state
        try require(downloads.models.first?.state == .ready && readyState == .ready, "Recovered arrival did not durably become ready")
        try require(try Data(contentsOf: destination) == bytes && downloads.diagnosticSnapshot().isEmpty, "Recovered completed task duplicated a replacement transfer or changed bytes")
        try require(!FileManager.default.contentsOfDirectory(atPath: downloads.directory(model).path).contains(where: { $0.hasPrefix("arrival-") }), "Completed arrival left staged bytes")
        passed.append("completed-task-absent-from-enumeration-recovers-by-validated-descriptor-and-full-pinned-hash")
        await downloads.restore(); downloads.urlSessionDidFinishEvents(forBackgroundURLSession: eventSession)
        try await Task.sleep(nanoseconds: 50_000_000)
        try require(completions == 1 && taskListings == 1, "Restore/final-marker replay repeated bootstrap or completion")
        passed.append("repeated-scene-restore-and-finish-marker-do-not-repeat-work-or-completion")

        for rejectedState in [LocalModel.State.paused, .ready] {
            let folder = root.appendingPathComponent(rejectedState.rawValue)
            let stored = try ModelLibrary(file: folder.appendingPathComponent("models.json"))
            var rejected = model; rejected.id = UUID(); rejected.state = rejectedState; try await stored.save(rejected)
            let manager = ModelDownloads(root: folder.appendingPathComponent("Models"), library: stored,
                sessionConfiguration: .ephemeral, taskListing: { _ in [] })
            defer { manager.cancelAllTransfers() }
            var finished = 0; manager.handleBackgroundEvents { finished += 1 }
            let incoming = folder.appendingPathComponent("temporary"); try bytes.write(to: incoming)
            let stale = BootstrapDownloadTask(id: 43, modelID: rejected.id, path: file.path, offset: 0, url: url, response: response)
            manager.urlSession(eventSession, downloadTask: stale, didFinishDownloadingTo: incoming)
            manager.urlSessionDidFinishEvents(forBackgroundURLSession: eventSession)
            try await waitUntil { finished == 1 }
            try require(manager.models == [rejected] && manager.committedBytes(rejected) == 0 && manager.diagnosticSnapshot().isEmpty, "Late callback changed paused/ready metadata or started a replacement transfer")
            try require(!FileManager.default.contentsOfDirectory(atPath: manager.directory(rejected).path).contains(where: { $0.hasPrefix("arrival-") }), "Rejected late callback retained its stage")
            passed.append("early-arrival-for-" + rejectedState.rawValue + "-model-is-discarded-without-state-or-byte-changes")
        }
        let failedRoot = root.appendingPathComponent("early-error"), failedStore = try ModelLibrary(file: failedRoot.appendingPathComponent("models.json"))
        var failedModel = model; failedModel.id = UUID(); try await failedStore.save(failedModel)
        let failed = ModelDownloads(root: failedRoot.appendingPathComponent("Models"), library: failedStore,
            sessionConfiguration: .ephemeral, taskListing: { _ in [] })
        defer { failed.cancelAllTransfers() }
        var errorCompletions = 0; failed.handleBackgroundEvents { errorCompletions += 1 }
        let failedTask = BootstrapDownloadTask(id: 45, modelID: failedModel.id, path: file.path, offset: 0, url: url, response: response)
        failed.urlSession(eventSession, task: failedTask, didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        failed.urlSessionDidFinishEvents(forBackgroundURLSession: eventSession)
        try await waitUntil { errorCompletions == 1 }
        let durableFailure = await failedStore.list().first
        try require(failed.models.first?.state == .failed && durableFailure?.state == .failed && durableFailure?.failure != nil, "Early task error was lost before metadata restoration")
        passed.append("completed-task-error-before-restoration-persists-failure-before-background-completion")
        let staleRoot = root.appendingPathComponent("stale-tasks"), staleStore = try ModelLibrary(file: staleRoot.appendingPathComponent("models.json"))
        var activeModel = model; activeModel.id = UUID(); try await staleStore.save(activeModel)
        let current = BootstrapDownloadTask(id: 51, modelID: activeModel.id, path: file.path, offset: 0, url: url, response: response)
        let invalid = [
            BootstrapDownloadTask(id: 52, modelID: UUID(), path: file.path, offset: 0, url: url, response: response),
            BootstrapDownloadTask(id: 53, modelID: activeModel.id, path: "unknown.gguf", offset: 0, url: url, response: response),
            BootstrapDownloadTask(id: 54, modelID: activeModel.id, path: file.path, offset: 1, url: url, response: response),
            BootstrapDownloadTask(id: 55, modelID: activeModel.id, path: file.path, offset: 0, url: URL(string: "https://huggingface.co/fixture/different")!, response: response)
        ]
        let retained = ModelDownloads(root: staleRoot.appendingPathComponent("Models"), library: staleStore,
            sessionConfiguration: .ephemeral, taskListing: { _ in invalid + [current] })
        defer { retained.cancelAllTransfers() }
        var staleCompletions = 0; retained.handleBackgroundEvents { staleCompletions += 1 }
        await retained.restore()
        try require(invalid.allSatisfy { $0.cancelled } && !current.cancelled && retained.diagnosticSnapshot().count == 1,
            "Task enumeration accepted an unknown model/file, changed checkpoint or different original URL")
        passed.append("recovered-task-enumeration-rejects-unknown-model-file-url-and-checkpoint-without-replacing-current-task")
        let staleFile = staleRoot.appendingPathComponent("temporary"); try bytes.write(to: staleFile)
        let previous = BootstrapDownloadTask(id: 50, modelID: activeModel.id, path: file.path, offset: 0, url: url, response: response)
        retained.urlSession(eventSession, downloadTask: previous, didFinishDownloadingTo: staleFile)
        retained.urlSessionDidFinishEvents(forBackgroundURLSession: eventSession)
        try await waitUntil { staleCompletions == 1 }
        try require(retained.models.first?.state == .downloading && retained.committedBytes(activeModel) == 0 && retained.diagnosticSnapshot().count == 1,
            "Late prior task replaced the current download or committed its stale range")
        try require(!FileManager.default.contentsOfDirectory(atPath: retained.directory(activeModel).path).contains(where: { $0.hasPrefix("arrival-") }),
            "Rejected prior task left staged bytes")
        passed.append("late-completed-prior-task-is-discarded-without-overwriting-current-task-or-owned-range")
        return ["passedChecks": passed, "taskListings": taskListings, "backgroundCompletions": completions,
            "completeBytes": bytes.count, "completeSHA256": try ModelFileTransfer.hash(destination),
            "earlyErrorCompletions": errorCompletions,
            "limitations": ["Actual ModelDownloads and ModelFileTransfer with synthetic completed tasks, pinned small bytes, held enumeration and commit operations. URLSession is ephemeral and performs no network requests.", "Direct ordered delegate delivery exercises startup/commit coordination. It does not establish OS background relaunch, suspended networking, foreground gestures, full-model inference or energy/performance."]]
    }
}
