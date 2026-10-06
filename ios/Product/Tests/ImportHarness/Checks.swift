import Foundation
import OpenWeightsCore

struct ImportFailure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}
func require(_ value: Bool, _ message: String) throws { if !value { throw ImportFailure(message) } }
func awaitSignal(_ semaphore: DispatchSemaphore) -> Bool { semaphore.wait(timeout: .now() + 3) == .success }

@main struct ImportChecks {
    @MainActor static func verifyPauseDuringCommit(root: URL, successful: Bool) async throws {
        let folder = root.appendingPathComponent("commit-" + UUID().uuidString)
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let library = try ModelLibrary(file: folder.appendingPathComponent("models.json"))
        let downloads = ModelDownloads(root: folder.appendingPathComponent("Models"), library: library,
            chunkCommit: { staged, destination, response, offset, file in
                held.signal()
                guard release.wait(timeout: .now() + 3) == .success else { throw ImportFailure("Controlled commit was not released") }
                try ModelDownloads.commitChunk(staged, destination: destination, response: response, offset: offset, file: file)
            })
        let file = ModelFile(path: "model.gguf", bytes: 262144)
        let model = LocalModel(name: "Controlled model", backend: .llamaCPU, entryFile: file.path, files: [file])
        try await downloads.save(model)
        let directory = downloads.directory(model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent("arrival")
        try Data(repeating: 11, count: 131072).write(to: staged)
        let destination = try file.destination(in: directory)
        let response = HTTPURLResponse(url: URL(string: "https://huggingface.co/org/model")!, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": successful ? "bytes 0-131071/262144" : "bytes 1-131072/262144"])!
        let arrival = try downloads.commitArrival(staged, destination: destination, response: response, offset: 0, file: file, modelID: model.id)
        let acquired = await Task.detached { awaitSignal(held) }.value
        try require(acquired, "Controlled arrival did not enter the copy operation")
        var pausesFinished = 0
        let first = Task { @MainActor in await downloads.pause(model); pausesFinished += 1 }
        let second = Task { @MainActor in await downloads.pause(model); pausesFinished += 1 }
        let started = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(nanoseconds: 150_000_000)
        try require(ProcessInfo.processInfo.systemUptime - started < 2, "Pause blocked the main actor")
        try require(downloads.models.first?.state == .paused && pausesFinished == 0, "Pause returned before the active commit finished")
        release.signal()
        var failed = false
        do { try await arrival.value } catch { failed = true }
        await first.value; await second.value
        try require(pausesFinished == 2 && downloads.models.first?.state == .paused, "Commit completion failed to release all Pause waiters")
        try require(failed == !successful, "Controlled commit did not reach its expected success/failure")
        try require(!FileManager.default.fileExists(atPath: staged.path), "Arrival cleanup was incomplete when Pause returned")
        let checkpoint = downloads.committedBytes(model)
        try require(checkpoint == (successful ? 131072 : 0), "Pause checkpoint was not the completed accepted range")
        try await Task.sleep(nanoseconds: 50_000_000)
        try require(downloads.committedBytes(model) == checkpoint, "Owned bytes changed after Pause returned")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canonical-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ModelLibrary(file: root.appendingPathComponent("models.json"))
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: library)
        var passed: [String] = []
        let bad = root.appendingPathComponent("bad.gguf")
        try Data("not a model".utf8).write(to: bad)
        await downloads.importGGUF(bad)
        try require(downloads.models.isEmpty && downloads.error != nil, "A bad import was committed to the model library.")
        try require(try FileManager.default.contentsOfDirectory(atPath: downloads.root.path).isEmpty,
                    "A failed import left an incomplete owned directory.")
        passed.append("bad-magic-rejected-without-metadata-or-incomplete-owned-copy")
        let source = root.appendingPathComponent("source.gguf")
        let bytes = Data("GGUF".utf8) + Data(repeating: 9, count: 2 * 1024 * 1024 + 11)
        try bytes.write(to: source)
        let link = root.appendingPathComponent("link.gguf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await downloads.importGGUF(link)
        try require(downloads.models.isEmpty && downloads.error != nil, "A source link was imported.")
        passed.append("source-link-rejected-by-canonical-controller")

        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), writerDone = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DispatchQueue.global().async {
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: source, options: .forReplacing, error: &error) { _ in
                held.signal(); _ = release.wait(timeout: .now() + 10)
            }
            writerDone.signal()
        }
        let acquired = await Task.detached { awaitSignal(held) }.value
        try require(acquired, "Fixture writer could not acquire its file.")
        let started = ProcessInfo.processInfo.systemUptime
        let importing = Task { @MainActor in await downloads.importGGUF(source) }
        try await Task.sleep(nanoseconds: 150_000_000)
        try require(ProcessInfo.processInfo.systemUptime - started < 2 && downloads.models.isEmpty,
                    "A waiting import blocked the main actor or read an uncoordinated source.")
        passed.append("main-actor-remains-responsive-during-coordinated-import-wait")
        importing.cancel()
        await importing.value
        try require(downloads.error != nil && downloads.models.isEmpty, "Cancelled import committed model metadata.")
        try require(try FileManager.default.contentsOfDirectory(atPath: downloads.root.path).isEmpty,
                    "Cancelled controller import kept incomplete bytes.")
        passed.append("cancelled-provider-wait-cleans-owned-copy-without-model-metadata")
        release.signal()
        let released = await Task.detached { awaitSignal(writerDone) }.value
        try require(released, "Fixture writer did not finish.")

        await downloads.importGGUF(source)
        try require(downloads.error == nil && downloads.models.count == 1, "Next import did not recover after cancellation.")
        let model = downloads.models[0]
        let destination = try model.files[0].destination(in: downloads.directory(model))
        try require(model.state == .ready && model.files[0].bytes == Int64(bytes.count), "Imported model size/state were not recorded.")
        try ModelDownloads.verify(destination, file: model.files[0])
        try FileManager.default.removeItem(at: source)
        try require(try Data(contentsOf: destination) == bytes, "Owned copy depended on the source file's lifetime.")
        passed.append("recovered-import-records-hash-size-and-independent-owned-bytes")
        let reopened = try ModelLibrary(file: root.appendingPathComponent("models.json"))
        let restored = await reopened.list()
        try require(restored == [model], "Imported model metadata did not survive library reopen.")
        passed.append("ready-model-import-metadata-survives-reopen")
        let pairSource = root.appendingPathComponent("paired.gguf"), projector = root.appendingPathComponent("mmproj-paired.gguf")
        try bytes.write(to:pairSource); try Data("bad projector".utf8).write(to:projector)
        let directoriesBefore = try FileManager.default.contentsOfDirectory(atPath:downloads.root.path)
        await downloads.importGGUF(pairSource,projector:projector)
        try require(downloads.error != nil && downloads.models.count == 1 && (try FileManager.default.contentsOfDirectory(atPath:downloads.root.path)) == directoriesBefore,"Failed projector import kept partial metadata or owned bytes")
        passed.append("bad-projector-removes-entire-owned-pair-and-preserves-existing-model")
        try bytes.write(to:projector); await downloads.importGGUF(pairSource,projector:projector)
        try require(downloads.error == nil && downloads.models.count == 2,"Valid base-projector pair import failed")
        let paired = downloads.models[0].entryFile == "paired.gguf" ? downloads.models[0] : downloads.models[1]
        try require(paired.files.count == 2 && paired.state == .ready,"Pair was not committed atomically ready")
        try FileManager.default.removeItem(at:pairSource); try FileManager.default.removeItem(at:projector)
        for file in paired.files { try ModelDownloads.verify(file.destination(in:downloads.directory(paired)),file:file) }
        let pairLibrary = try ModelLibrary(file:root.appendingPathComponent("models.json"))
        try require(await pairLibrary.list().contains(paired),"Pair metadata failed library reopen")
        passed.append("owned-base-projector-pair-hashes-survive-source-removal-and-library-reopen")
        try await verifyPauseDuringCommit(root: root, successful: true)
        passed.append("pause-waits-for-accepted-arrival-without-blocking-main-actor-and-releases-all-waiters-with-stable-checkpoint")
        try await verifyPauseDuringCommit(root: root, successful: false)
        passed.append("failed-arrival-cleans-stage-and-releases-all-pause-waiters-without-changing-paused-metadata")
        let folderSource = root.appendingPathComponent("mlx-source")
        try FileManager.default.createDirectory(at: folderSource, withIntermediateDirectories:true)
        for (path,text) in [("config.json","{\"model_type\":\"qwen3\"}"),("tokenizer.json","{}"),("tokenizer_config.json","{}"),("model.safetensors","weights"),("README.md","unused")] {
            try Data(text.utf8).write(to:folderSource.appendingPathComponent(path))
        }
        let holdFolder=DispatchSemaphore(value:0),releaseFolder=DispatchSemaphore(value:0),folderWriterDone=DispatchSemaphore(value:0)
        defer { releaseFolder.signal() }
        DispatchQueue.global().async {
            var error:NSError?
            NSFileCoordinator(filePresenter:nil).coordinate(writingItemAt:folderSource,options:[],error:&error) { _ in
                holdFolder.signal();_ = releaseFolder.wait(timeout:.now()+10)
            }
            folderWriterDone.signal()
        }
        let folderHeld=await Task.detached { awaitSignal(holdFolder) }.value
        try require(folderHeld,"Controlled model folder writer was not acquired")
        let beforeModels=downloads.models, beforeDirectories=Set(try FileManager.default.contentsOfDirectory(atPath:downloads.root.path))
        let folderTask=Task { @MainActor in await downloads.importFolder(folderSource,format:.mlx) }
        try await Task.sleep(nanoseconds:150_000_000)
        try require(downloads.importingName == folderSource.lastPathComponent && downloads.models == beforeModels,"Folder import blocked the main actor or committed while a writer held the folder")
        await downloads.importFolder(folderSource,format:.mlx)
        try require(downloads.error != nil && downloads.importingName != nil,"Overlapping import replaced the running import")
        passed.append("folder-import-wait-keeps-main-actor-responsive-and-refuses-overlap")
        downloads.cancelFolderImport();await folderTask.value
        try require(downloads.importingName == nil && downloads.error == nil && downloads.models == beforeModels,"Stop import kept busy state, error or model metadata")
        try require(Set(try FileManager.default.contentsOfDirectory(atPath:downloads.root.path)) == beforeDirectories,"Stop folder import left owned bytes")
        releaseFolder.signal();let folderReleased=await Task.detached { awaitSignal(folderWriterDone) }.value
        try require(folderReleased,"Folder writer did not release")
        passed.append("explicit-stop-cancels-coordinated-folder-wait-and-keeps-prior-library")
        await downloads.importFolder(folderSource,format:.mlx)
        try require(downloads.error == nil && downloads.importingName == nil && downloads.models.count == beforeModels.count+1,"MLX folder import did not recover")
        guard let mlx=await library.list().first(where:{$0.backend == .mlx}) else { throw ImportFailure("Imported MLX model missing") }
        try require(mlx.state == .ready && mlx.family == "qwen3" && mlx.entryFile == "config.json" && mlx.files.count == 4,"MLX metadata or component selection changed")
        try FileManager.default.removeItem(at:folderSource)
        for file in mlx.files { try ModelDownloads.verify(file.destination(in:downloads.directory(mlx)),file:file) }
        let folderReopen=try ModelLibrary(file:root.appendingPathComponent("models.json"))
        try require(await folderReopen.list().contains(mlx),"MLX model metadata did not reopen")
        passed.append("MLX-folder-hashed-owned-components-survive-source-removal-and-library-reopen")
        let compiledSource=root.appendingPathComponent("compiled-source"),weight=compiledSource.appendingPathComponent("xnnpack/model.pte")
        try FileManager.default.createDirectory(at:weight.deletingLastPathComponent(),withIntermediateDirectories:true)
        let weightBytes=Data("compiled fixture".utf8);try weightBytes.write(to:weight);try Data("{}".utf8).write(to:compiledSource.appendingPathComponent("tokenizer.json"))
        let config:[String:Any] = ["runtime":"executorch","backend":"xnnpack","source_model":"Qwen/Qwen3-0.6B","variants":[["file":"model.pte","context":2048,"size_bytes":weightBytes.count,"sha256":try ModelDownloads.hash(weight)]]]
        try JSONSerialization.data(withJSONObject:config).write(to:weight.deletingLastPathComponent().appendingPathComponent("config.json"))
        await downloads.importFolder(compiledSource,format:.xnnpack)
        try require(downloads.error == nil,"Compiled folder was refused")
        guard let compiled=await library.list().first(where:{$0.backend == .xnnpack}) else { throw ImportFailure("Compiled model missing") }
        try require(compiled.entryFile == "xnnpack/model.pte" && compiled.family == "qwen3" && compiled.settings.contextTokens == 2048 && compiled.files.count == 3,"Compiled export was misrouted")
        try FileManager.default.removeItem(at:compiledSource)
        for file in compiled.files { try ModelDownloads.verify(file.destination(in:downloads.directory(compiled)),file:file) }
        passed.append("compiled-folder-preserves-nested-entry-top-level-tokenizer-declared-hash-and-explicit-backend")
        try FileManager.default.createDirectory(at:weight.deletingLastPathComponent(),withIntermediateDirectories:true)
        try weightBytes.write(to:weight);try Data("{}".utf8).write(to:compiledSource.appendingPathComponent("tokenizer.json"))
        var smolConfig=config;smolConfig["source_model"]="HuggingFaceTB/SmolLM2-135M-Instruct"
        try JSONSerialization.data(withJSONObject:smolConfig).write(to:weight.deletingLastPathComponent().appendingPathComponent("config.json"))
        await downloads.importFolder(compiledSource,format:.xnnpack)
        try require(downloads.error == nil,"SmolLM2 folder was refused")
        guard let smol=await library.list().first(where:{$0.family == "smollm2"}) else { throw ImportFailure("SmolLM2 import missing") }
        try require(smol.entryFile == "xnnpack/model.pte" && smol.backend == .xnnpack && smol.state == .ready && smol.files.count == 3,"SmolLM2 imported export was misrouted")
        try FileManager.default.removeItem(at:compiledSource)
        for file in smol.files { try ModelDownloads.verify(file.destination(in:downloads.directory(smol)),file:file) }
        try require(await ModelLibrary(file:root.appendingPathComponent("models.json")).list().contains(smol),"SmolLM2 import metadata did not reopen")
        passed.append("smollm2-folder-explicit-family-owned-hashes-and-reopen-survive-source-removal")
        try FileManager.default.createDirectory(at:weight.deletingLastPathComponent(),withIntermediateDirectories:true)
        try weightBytes.write(to:weight);try Data("{}".utf8).write(to:compiledSource.appendingPathComponent("tokenizer.json"))
        var llamaConfig=config;llamaConfig["source_model"]="meta-llama/Llama-3.2-1B-Instruct"
        try JSONSerialization.data(withJSONObject:llamaConfig).write(to:weight.deletingLastPathComponent().appendingPathComponent("config.json"))
        await downloads.importFolder(compiledSource,format:.xnnpack)
        try require(downloads.error == nil,"Llama 3.2 folder was refused")
        guard let llama=await library.list().first(where:{$0.family == "llama32"}) else { throw ImportFailure("Llama 3.2 import missing") }
        try require(llama.entryFile == "xnnpack/model.pte" && llama.backend == .xnnpack && llama.state == .ready && llama.files.count == 3,"Llama 3.2 imported export was misrouted")
        try FileManager.default.removeItem(at:compiledSource)
        for file in llama.files { try ModelDownloads.verify(file.destination(in:downloads.directory(llama)),file:file) }
        try require(await ModelLibrary(file:root.appendingPathComponent("models.json")).list().contains(llama),"Llama 3.2 import metadata did not reopen")
        passed.append("llama32-folder-explicit-family-owned-hashes-and-reopen-survive-source-removal")
        let failedFolder=root.appendingPathComponent("metadata-failure"),failedFile=failedFolder.appendingPathComponent("models.json")
        let failedLibrary=try ModelLibrary(file:failedFile)
        try FileManager.default.createDirectory(at:failedFile,withIntermediateDirectories:true)
        let failedDownloads=ModelDownloads(root:failedFolder.appendingPathComponent("Models"),library:failedLibrary)
        let validSource=root.appendingPathComponent("final-mlx-source")
        try FileManager.default.createDirectory(at:validSource,withIntermediateDirectories:true)
        for (path,text) in [("config.json","{\"model_type\":\"qwen3\"}"),("tokenizer.json","{}"),("tokenizer_config.json","{}"),("model.safetensors","weights")] { try Data(text.utf8).write(to:validSource.appendingPathComponent(path)) }
        await failedDownloads.importFolder(validSource,format:.mlx)
        try require(failedDownloads.models.isEmpty && failedDownloads.error != nil && failedDownloads.importingName == nil,"Failed metadata write published a ready model")
        try require(try FileManager.default.contentsOfDirectory(atPath:failedDownloads.root.path).isEmpty,"Failed metadata write retained copied model bytes")
        passed.append("failed-folder-metadata-commit-cleans-full-copy-and-preserves-idle-library")
        let proof: [String: Any] = ["status": "canonical-model-downloads-import-host-verified", "passedChecks": passed,
            "limitations": ["Uses the actual ModelDownloads source with local coordinated folders and a small GGUF-header fixture. Two pause controls inject a held commit operation, then run actual chunk validation/file append and Pause waiting.",
                             "Does not prove inference, full-size imports, external iOS file-provider grants, touch navigation or app suspension.",
                             "No network download is performed by this import harness."]]
        try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
