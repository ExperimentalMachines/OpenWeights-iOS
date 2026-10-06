import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif
import OpenWeightsCore

@MainActor final class ModelDownloads: NSObject, ObservableObject, URLSessionDownloadDelegate {
    typealias ChunkCommit = @Sendable (URL, URL, HTTPURLResponse, Int64, ModelFile) throws -> Void
    @Published private(set) var models: [LocalModel] = []
    @Published private(set) var progress: [UUID: Double] = [:]
    @Published private(set) var importingName: String?
    @Published var error: String?
    nonisolated let root: URL
    nonisolated private static let arrivalOwner = UUID()
    private let library: ModelLibrary
    private let sessionIdentifier: String
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var committing: Set<String> = []
    private var commitWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private let chunkCommit: ChunkCommit
    typealias TaskListing = @MainActor (URLSession) async -> [URLSessionTask]
    private let taskListing: TaskListing
    private let sessionConfiguration: URLSessionConfiguration?
    private var restoration: Task<Void, Never>?
    private var restored = false
    private var bootstrapping = false
    private var recoveringTasks = true
    private enum DelegateEvent {
        case arrival(URLSessionDownloadTask, URL, HTTPURLResponse)
        case failure(URLSessionTask, Error)
        case progress(URLSessionDownloadTask, Int64)
        case finished
    }
    private var delegateEvents: [DelegateEvent] = []
    private var processingEvents = false
    private lazy var session: URLSession = {
        let configuration = sessionConfiguration ?? URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private var backgroundCompletion: (() -> Void)?
    private var pendingArrivals = 0
    private var eventsFinished = false
    private let chunkBytes: Int64
    private let isBackground: @MainActor () -> Bool
    private var folderImport: Task<ImportedModelFolder, Error>?

    init(root: URL, library: ModelLibrary, sessionIdentifier: String = "org.experimentalmachines.openweights.models",
         chunkBytes: Int64 = 32 * 1024 * 1024, chunkCommit: @escaping ChunkCommit = ModelDownloads.commitChunk,
         sessionConfiguration: URLSessionConfiguration? = nil,
         taskListing: @escaping TaskListing = { await $0.allTasks },
         isBackground: @escaping @MainActor () -> Bool = ModelDownloads.systemIsBackground) {
        precondition(chunkBytes > 0)
        self.root = root; self.library = library; self.sessionIdentifier = sessionIdentifier; self.chunkBytes = chunkBytes; self.chunkCommit = chunkCommit
        self.sessionConfiguration = sessionConfiguration; self.taskListing = taskListing; self.isBackground = isBackground; super.init()
    }
    static func systemIsBackground() -> Bool {
#if canImport(UIKit)
        UIApplication.shared.applicationState == .background
#else
        false
#endif
    }
    func restore() async {
        if let restoration { await restoration.value; return }
        guard !restored else { return }
        let work = Task { @MainActor in await self.bootstrap() }
        restoration = work
        await work.value
        restoration = nil
    }
    private func bootstrap() async {
        bootstrapping = true
        models = await library.list()
        // Reconcile only prior-process arrivals before connecting the daemon.
        // Current-process stages can still be waiting in our delegate event queue.
        for model in models {
            let directory = directory(model)
            do { try await Task.detached { try ModelDownloadArrival.recover(in: directory, model: model, excludingOwner: Self.arrivalOwner) }.value }
            catch { await fail(model.id, error: error) }
        }
        let existing = await taskListing(session)
        for task in existing {
            guard let download = task as? URLSessionDownloadTask, recover(download) else { task.cancel(); continue }
#if OW_BACKGROUND_DOWNLOAD_VALIDATION
            BackgroundDownloadValidation.record("bootstrap-task-reattached", modelID: descriptor(download)?.id,
                fields: ["taskIdentifier": download.taskIdentifier, "range": download.originalRequest?.value(forHTTPHeaderField: "Range") ?? "",
                    "receivedBytes": download.countOfBytesReceived, "expectedBytes": download.countOfBytesExpectedToReceive])
#endif
        }
        restored = true
        await drainEvents()
        // Files move out of the delegate's temporary URL before asynchronous validation.
        // A completed task can be absent from allTasks but still have pending delegate
        // events. Let those events claim their range before creating replacement tasks.
        if backgroundCompletion == nil || eventsFinished { await continueRestoredDownloads() }
        bootstrapping = false
        finishEventsIfReady()
    }
    private func continueRestoredDownloads() async {
        for model in models where model.state == .downloading {
            do { try await continueDownload(model) } catch { self.error = error.localizedDescription }
        }
    }
    private func descriptor(_ task: URLSessionTask) -> (key: String, id: UUID, path: String, offset: Int64)? {
        let parts = (task.taskDescription ?? "").split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, let id = UUID(uuidString: parts[0]), let offset = Int64(parts[2]), offset >= 0,
              (try? ModelFile.validatePath(parts[1])) != nil else { return nil }
        return (id.uuidString + ":" + parts[1], id, parts[1], offset)
    }
    private func recover(_ task: URLSessionDownloadTask) -> Bool {
        guard let info = descriptor(task), let model = models.first(where: { $0.id == info.id }), model.state == .downloading,
              let file = model.files.first(where: { $0.path == info.path }), file.url == task.originalRequest?.url,
              let destination = try? file.destination(in: directory(model)), !committing.contains(info.key),
              !FileManager.default.fileExists(atPath: destination.path),
              ((try? ModelFileTransfer.byteCount(destination.appendingPathExtension("partial"))) ?? 0) == info.offset else { return false }
        if let current = tasks[info.key] { return current.taskIdentifier == task.taskIdentifier }
        tasks[info.key] = task
        return true
    }
    func directory(_ model: LocalModel) -> URL { root.appendingPathComponent(model.id.uuidString, isDirectory: true) }
    func install(_ model: LocalModel) async {
        do {
            guard !models.contains(where: { $0.repository == model.repository && $0.revision == model.revision && $0.entryFile == model.entryFile && $0.backend == model.backend && $0.files.map(\.path) == model.files.map(\.path) }) else {
                throw ModelError.unsupported("This artifact is already in your library. Resume or retry it there.")
            }
            for file in model.files { _ = try file.destination(in: directory(model)) }
            try await library.save(model); models = await library.list()
            try await continueDownload(model)
        } catch { self.error = error.localizedDescription }
    }
    func save(_ model: LocalModel) async throws { try await library.save(model); models = await library.list() }
    func saveSettings(_ model: LocalModel) async throws { try await library.saveSettings(model); models = await library.list() }
    func resume(_ model: LocalModel) async {
        do { var next = model; next.state = .downloading; next.failure = nil; try await save(next); try await continueDownload(next) }
        catch { self.error = error.localizedDescription }
    }
    func pause(_ model: LocalModel) async {
        do {
            var next = model; next.state = .paused; try await save(next)
            for (key, task) in tasks where key.hasPrefix(model.id.uuidString + ":") {
                // Only completed, validated ranges are durable. Discard the in-flight range.
                task.cancel()
                tasks.removeValue(forKey: key)
            }
            // An accepted range may already be copying off the main actor. Its owned
            // checkpoint must stop changing before Pause returns or Remove deletes it.
            await waitForCommits(model.id)
        } catch { self.error = error.localizedDescription }
    }
    private func waitForCommits(_ id: UUID) async {
        guard committing.contains(where: { $0.hasPrefix(id.uuidString + ":") }) else { return }
        await withCheckedContinuation { commitWaiters[id, default: []].append($0) }
    }
    func commitArrival(_ staged: URL, destination: URL, response: HTTPURLResponse, offset: Int64,
                       file: ModelFile, modelID: UUID) throws -> Task<Void, Error> {
        let key = modelID.uuidString + ":" + file.path
        guard committing.insert(key).inserted else { throw ModelError.unsupported("This model file already has an active arrival.") }
        let operation = chunkCommit
        // Register synchronously before yielding, so Pause cannot miss a queued copy.
        return Task { @MainActor in
            defer {
                committing.remove(key)
                if !committing.contains(where: { $0.hasPrefix(modelID.uuidString + ":") }) {
                    for waiter in commitWaiters.removeValue(forKey: modelID) ?? [] { waiter.resume() }
                }
            }
            try await Task.detached { try operation(staged, destination, response, offset, file) }.value
        }
    }
    func remove(_ model: LocalModel) async throws {
        await pause(model)
        // Commit the tombstone before deleting bytes so a failed metadata write keeps a usable model.
        try await library.delete(model.id); models = await library.list()
        if FileManager.default.fileExists(atPath: directory(model).path) { try FileManager.default.removeItem(at: directory(model)) }
    }
    func importGGUF(_ source: URL, projector: URL? = nil) async {
        var ownedDirectory: URL?
        do {
            guard GGUFFileName.exclusion(source.lastPathComponent) == nil else { throw ModelError.unsupported("Select a complete base GGUF file.") }
            if let projector {
                guard projector.lastPathComponent.lowercased().hasPrefix("mmproj"), projector.pathExtension.lowercased() == "gguf",
                      source.lastPathComponent != projector.lastPathComponent else { throw ModelError.unsupported("Select the matching mmproj GGUF separately from its base model.") }
            }
            var model = LocalModel(name: source.deletingPathExtension().lastPathComponent + (projector == nil ? "" : " + projector"), backend: .llamaMetal,
                entryFile: source.lastPathComponent, files: [ModelFile(path: source.lastPathComponent)] + (projector.map { [ModelFile(path: $0.lastPathComponent)] } ?? []))
            ownedDirectory = directory(model)
            try FileManager.default.createDirectory(at: directory(model), withIntermediateDirectories: true)
            for (index, url) in ([source] + (projector.map { [$0] } ?? [])).enumerated() {
                let path = url.resolvingSymlinksInPath().path
                let appOwned = [URL(fileURLWithPath: NSHomeDirectory()), FileManager.default.temporaryDirectory].contains {
                    let root = $0.resolvingSymlinksInPath().path
                    return path == root || path.hasPrefix(root + "/")
                }
                let imported = try await ModelImport.copyGGUF(from: url, to: model.files[index].destination(in: directory(model)),
                    access: appOwned ? .coordinated : .securityScoped)
                model.files[index].sha256 = imported.sha256; model.files[index].bytes = imported.bytes
            }
            model.state = .ready; try await save(model); self.error = nil
        } catch {
            self.error = error.localizedDescription
            if let ownedDirectory, FileManager.default.fileExists(atPath: ownedDirectory.path) {
                do { try FileManager.default.removeItem(at: ownedDirectory) }
                catch { self.error = (self.error ?? "Import failed.") + " The incomplete owned copy could not be removed: " + error.localizedDescription }
            }
        }
    }
    func cancelFolderImport() { folderImport?.cancel() }
    func importFolder(_ source: URL, format: ModelFolderFormat) async {
        guard importingName == nil else { error = "Wait for the current model import or stop it first."; return }
        importingName = source.lastPathComponent; error = nil
        defer { importingName = nil; folderImport = nil }
        var ownedDirectory: URL?
        do {
            let backend: ModelBackend = format == .mlx ? .mlx : format == .executorchMLX ? .executorchMLX : .xnnpack
            var model = LocalModel(name: source.lastPathComponent, backend: backend,
                entryFile: "", files: [])
            let destination = directory(model)
            let path = source.resolvingSymlinksInPath().path
            let appOwned = [URL(fileURLWithPath: NSHomeDirectory()), FileManager.default.temporaryDirectory].contains {
                let root = $0.resolvingSymlinksInPath().path; return path == root || path.hasPrefix(root + "/")
            }
            let operation = Task { try await ModelFolderImport.copy(from: source, to: destination, format: format,
                access: appOwned ? .coordinated : .securityScoped) }
            folderImport = operation
            let imported = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            ownedDirectory = destination
            try Task.checkCancellation()
            if operation.isCancelled { throw CancellationError() }
            model.entryFile = imported.entryFile; model.family = imported.family; model.files = imported.files
            model.state = .ready
            try await save(model)
        } catch {
            self.error = error is CancellationError ? nil : error.localizedDescription
            if let ownedDirectory {
                do { try FileManager.default.removeItem(at: ownedDirectory) }
                catch { self.error = "The incomplete model copy could not be removed: " + error.localizedDescription }
            }
        }
    }
    func handleBackgroundEvents(completion: @escaping () -> Void) {
        backgroundCompletion = completion; eventsFinished = false; recoveringTasks = true
        // Background launches do not require a scene. Share the same restoration
        // operation with foreground startup before consuming the session's events.
        Task { @MainActor in await restore() }
    }
    func cancelAllTransfers() { session.invalidateAndCancel(); tasks.removeAll() }
    func diagnosticSnapshot() -> [[String: Any]] {
        var values: [[String: Any]] = tasks.values.map { task in
            ["state": task.state.rawValue, "receivedBytes": task.countOfBytesReceived,
             "expectedBytes": task.countOfBytesExpectedToReceive,
             "range": task.originalRequest?.value(forHTTPHeaderField: "Range") ?? "",
             "responseStatus": (task.response as? HTTPURLResponse)?.statusCode ?? 0]
        }
#if canImport(UIKit)
        for index in values.indices { values[index]["applicationState"] = UIApplication.shared.applicationState.rawValue }
#endif
        return values
    }
    func committedBytes(_ model: LocalModel) -> Int64 {
        model.files.reduce(0) { sum, file in
            guard let destination = try? file.destination(in: directory(model)) else { return sum }
            let partial = destination.appendingPathExtension("partial")
            let saved = FileManager.default.fileExists(atPath: destination.path) ? destination : partial
            return sum + ((try? ModelFileTransfer.byteCount(saved)) ?? 0)
        }
    }

    private func continueDownload(_ original: LocalModel) async throws {
        guard let model = models.first(where: { $0.id == original.id }), model.state == .downloading else { return }
        for file in model.files {
            let destination = try file.destination(in: directory(model))
            if FileManager.default.fileExists(atPath: destination.path) {
                do { try await Task.detached { try Self.verify(destination, file: file) }.value; continue }
                catch { try FileManager.default.removeItem(at: destination) }
            }
            let key = model.id.uuidString + ":" + file.path
            guard models.first(where: { $0.id == model.id })?.state == .downloading else { return }
            if tasks[key] != nil || committing.contains(key) { return }
            guard let url = file.url, url.scheme == "https", url.host == "huggingface.co" else { throw ModelError.unsupported("Model downloads require an HTTPS Hugging Face URL.") }
            let partial = destination.appendingPathExtension("partial")
            let offset = (try? ModelFileTransfer.byteCount(partial)) ?? 0
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            if let token = try CredentialVault.token(), !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            if let total = file.bytes, offset >= total {
                do { try await Task.detached { try Self.verify(partial, file: file) }.value }
                catch { try? FileManager.default.removeItem(at: partial); throw error }
                try FileManager.default.moveItem(at: partial, to: destination)
                return try await continueDownload(model)
            }
            request.setValue(try ModelDownloadRange.header(offset: offset, total: file.bytes,
                chunkBytes: chunkBytes, background: isBackground()), forHTTPHeaderField: "Range")
            let download = session.downloadTask(with: request)
            download.taskDescription = key + ":" + String(offset); tasks[key] = download
#if OW_BACKGROUND_DOWNLOAD_VALIDATION
            BackgroundDownloadValidation.record("task-scheduled", modelID: model.id,
                fields: ["taskIdentifier": download.taskIdentifier, "file": file.path, "range": request.value(forHTTPHeaderField: "Range") ?? ""])
#endif
            download.resume()
            return
        }
        guard var ready = models.first(where: { $0.id == model.id }), ready.state == .downloading else { return }
        ready.state = .ready; ready.failure = nil; try await save(ready); progress[model.id] = nil
    }
    nonisolated static func hash(_ url: URL) throws -> String { try ModelFileTransfer.hash(url) }
    nonisolated static func verify(_ url: URL, file: ModelFile) throws { try ModelFileTransfer.verify(url, file: file) }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let description = downloadTask.taskDescription ?? ""
        let segments = description.split(separator: ":", maxSplits: 2).map(String.init)
        guard segments.count == 3, let offset = Int64(segments[2]), offset >= 0 else { return }
        let key = segments[0] + ":" + segments[1]
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw ModelError.unsupported("Hugging Face returned an unsuccessful download response. Retry from the model library.") }
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = UUID(uuidString: parts[0]) else { throw ModelError.invalidPath(key) }
            let file = ModelFile(path: parts[1]); let directory = root.appendingPathComponent(id.uuidString)
            guard let requestURL = downloadTask.originalRequest?.url else { throw ModelError.corrupt(file.path) }
            let staged = try ModelDownloadArrival.stage(location, directory: directory, owner: Self.arrivalOwner, modelID: id,
                filePath: file.path, requestURL: requestURL, offset: offset, status: response.statusCode,
                contentRange: response.value(forHTTPHeaderField: "Content-Range"))
            // The delegate queue is serial. Dispatch preserves its event order,
            // including the final event marker, while actor work may suspend.
            DispatchQueue.main.async { self.enqueue(.arrival(downloadTask, staged, response)) }
        } catch { DispatchQueue.main.async { self.enqueue(.failure(downloadTask, error)) } }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async { self.enqueue(.progress(downloadTask, totalBytesWritten)) }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        DispatchQueue.main.async { self.enqueue(.failure(task, error)) }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { self.enqueue(.finished) }
    }
    private func enqueue(_ event: DelegateEvent) {
        delegateEvents.append(event)
        guard restored else { Task { @MainActor in await restore() }; return }
        guard !processingEvents else { return }
        Task { @MainActor in await drainEvents() }
    }
    private func drainEvents() async {
        guard !processingEvents else { return }
        processingEvents = true
        while !delegateEvents.isEmpty {
            let event = delegateEvents.removeFirst()
            switch event {
            case .arrival(let task, let staged, let response):
#if OW_BACKGROUND_DOWNLOAD_VALIDATION
                BackgroundDownloadValidation.record("delegate-arrival", modelID: descriptor(task)?.id,
                    fields: ["taskIdentifier": task.taskIdentifier, "range": response.value(forHTTPHeaderField: "Content-Range") ?? "", "status": response.statusCode])
#endif
                defer { try? ModelDownloadArrival.discard(staged) }
                if recoveringTasks, let info = descriptor(task), tasks[info.key] == nil { _ = recover(task) }
                guard let info = descriptor(task), tasks[info.key]?.taskIdentifier == task.taskIdentifier,
                      let model = models.first(where: { $0.id == info.id }), model.state == .downloading,
                      let file = model.files.first(where: { $0.path == info.path }) else {
                    try? FileManager.default.removeItem(at: staged); continue
                }
                pendingArrivals += 1; tasks[info.key] = nil
                do {
                    let destination = try file.destination(in: directory(model))
                    let arrival = try commitArrival(staged, destination: destination, response: response,
                        offset: info.offset, file: file, modelID: model.id)
                    try await arrival.value
#if OW_BACKGROUND_DOWNLOAD_VALIDATION
                    await BackgroundDownloadValidation.didCommit(modelID: model.id, filePath: file.path)
#endif
                    try await continueDownload(model)
                } catch { try? FileManager.default.removeItem(at: staged); await fail(model.id, error: error) }
                pendingArrivals -= 1
            case .failure(let task, let error):
                if recoveringTasks, let download = task as? URLSessionDownloadTask, let info = descriptor(task), tasks[info.key] == nil { _ = recover(download) }
                guard let info = descriptor(task), tasks[info.key]?.taskIdentifier == task.taskIdentifier else { continue }
                tasks[info.key] = nil; await fail(info.id, error: error)
            case .progress(let task, let received):
                if recoveringTasks, let info = descriptor(task), tasks[info.key] == nil { _ = recover(task) }
                guard let info = descriptor(task), tasks[info.key]?.taskIdentifier == task.taskIdentifier,
                      let model = models.first(where: { $0.id == info.id }), model.state == .downloading else { continue }
                let expected = model.files.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
                progress[model.id] = expected > 0 ? min(1, Double(committedBytes(model) + received) / Double(expected)) : 0
#if OW_BACKGROUND_DOWNLOAD_VALIDATION
                await BackgroundDownloadValidation.didReceive(modelID: model.id, filePath: info.path,
                    taskID: task.taskIdentifier, range: task.originalRequest?.value(forHTTPHeaderField: "Range") ?? "",
                    received: received, expected: task.countOfBytesExpectedToReceive)
#endif
            case .finished:
#if OW_BACKGROUND_DOWNLOAD_VALIDATION
                BackgroundDownloadValidation.record("delegate-finished-events")
#endif
                eventsFinished = true; recoveringTasks = false
                await continueRestoredDownloads()
            }
        }
        processingEvents = false
        finishEventsIfReady()
    }
    private func finishEventsIfReady() {
        if restored && !bootstrapping && !processingEvents && delegateEvents.isEmpty && eventsFinished && pendingArrivals == 0 {
            let completion = backgroundCompletion; backgroundCompletion = nil; completion?()
        }
    }
    private func fail(_ id: UUID, error: Error) async {
        guard var model = models.first(where: { $0.id == id }), model.state != .paused else { return }
        model.state = .failed; model.failure = error.localizedDescription
        do { try await save(model) } catch { self.error = error.localizedDescription }
    }
    nonisolated static func commitChunk(_ staged: URL, destination: URL, response: HTTPURLResponse, offset: Int64, file: ModelFile) throws {
        try ModelFileTransfer.commitChunk(staged, destination: destination, status: response.statusCode,
                                         contentRange: response.value(forHTTPHeaderField: "Content-Range"), offset: offset, file: file)
    }
}
