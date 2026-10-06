import Darwin
import XCTest
@testable import OpenWeightsCore

final class ModelFolderImportTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func mlx(_ root: URL) throws {
        for (name, text) in [("config.json", "{\"model_type\":\"qwen3\"}"), ("tokenizer.json", "{}"), ("tokenizer_config.json", "{}"), ("model.safetensors", "fixture weights"), ("README.md", "unused"), (".private", "hidden")] {
            try Data(text.utf8).write(to: root.appendingPathComponent(name))
        }
    }
    private func compiled(_ root: URL, backend: String = "xnnpack", context: Int = 2048, validHash: Bool = true, sourceModel: String = "Qwen/Qwen3-0.6B") throws {
        let entry = root.appendingPathComponent("xnnpack/model.pte")
        try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("compiled fixture".utf8).write(to: entry); try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
        let hash = validHash ? try ModelFileTransfer.hash(entry) : String(repeating: "0", count: 64)
        let value: [String: Any] = ["runtime":"executorch", "backend":backend, "source_model":sourceModel, "variants":[["file":"model.pte", "context":context, "size_bytes":16, "sha256":hash]]]
        try JSONSerialization.data(withJSONObject:value).write(to:entry.deletingLastPathComponent().appendingPathComponent("config.json"))
    }
    private func compiledMLX(_ root: URL, version: String = "1.5.0", enabled: Bool = true,
                             context: Double = 2048, sequence: Double = 2048, dynamic: Bool = true,
                             cache: Bool = true, validHash: Bool = true, source: String = "Qwen/Qwen3-0.6B") throws {
        let weights = root.appendingPathComponent("model.pte")
        try Data("compiled MLX fixture".utf8).write(to:weights)
        try Data("{}".utf8).write(to:root.appendingPathComponent("tokenizer.json"))
        let hash = validHash ? try ModelFileTransfer.hash(weights) : String(repeating:"0",count:64)
        let value: [String: Any] = ["versions":["executorch":version],"sourceRepo":source,
            "sourceRevision":String(repeating:"a",count:40),"artifactSHA256":hash,
            "exportConfiguration":["backend":["mlx":["enabled":enabled]],
                "export":["max_context_length":context,"max_seq_length":sequence],
                "model":["enable_dynamic_shape":dynamic,"use_kv_cache":cache]]]
        try JSONSerialization.data(withJSONObject:value).write(to:root.appendingPathComponent("export-provenance.json"))
    }
    func testCompiledMLXOwnedCopyUsesObservedSizeAndDeclaredHash() async throws {
        let parent=try folder(); defer { try? FileManager.default.removeItem(at:parent) }
        let source=parent.appendingPathComponent("source"),target=parent.appendingPathComponent("owned")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true);try compiledMLX(source)
        let value=try await ModelFolderImport.copy(from:source,to:target,format:.executorchMLX)
        XCTAssertEqual(value.family,"qwen3");XCTAssertEqual(value.entryFile,"model.pte")
        XCTAssertEqual(Set(value.files.map(\.path)),Set(["model.pte","tokenizer.json","export-provenance.json"]))
        let weights=try XCTUnwrap(value.files.first { $0.path == "model.pte" })
        XCTAssertEqual(weights.bytes,Int64(Data("compiled MLX fixture".utf8).count))
        XCTAssertEqual(weights.sha256,try ModelFileTransfer.hash(source.appendingPathComponent("model.pte")))
        XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath:source.appendingPathComponent("model.pte").path)[.systemFileNumber] as? NSNumber,
            try FileManager.default.attributesOfItem(atPath:target.appendingPathComponent("model.pte").path)[.systemFileNumber] as? NSNumber)
        try FileManager.default.removeItem(at:source)
        for file in value.files { try ModelFileTransfer.verify(file.destination(in:target),file:file) }
    }
    func testCompiledMLXRejectsIncompatibleFactsAndCorruptWeightsWithoutOwnedResidue() async throws {
        let parent=try folder();defer { try? FileManager.default.removeItem(at:parent) }
        let mutations: [(URL) throws -> Void] = [
            { try self.compiledMLX($0,version:"1.4.0") }, { try self.compiledMLX($0,enabled:false) },
            { try self.compiledMLX($0,context:4096) }, { try self.compiledMLX($0,context:2048.5) },
            { try self.compiledMLX($0,sequence:2048.5) }, { try self.compiledMLX($0,dynamic:false) },
            { try self.compiledMLX($0,cache:false) }, { try self.compiledMLX($0,validHash:false) },
            { try self.compiledMLX($0,source:"Qwen/Qwen2.5-1.5B-Instruct") },
            { try self.compiledMLX($0);try Data("extra".utf8).write(to:$0.appendingPathComponent("extra.pte")) },
            { try self.compiledMLX($0);try Data("external".utf8).write(to:$0.appendingPathComponent("weights.ptd")) },
            { try self.compiledMLX($0);try FileManager.default.removeItem(at:$0.appendingPathComponent("tokenizer.json")) },
            { try self.compiledMLX($0);try Data("changed".utf8).write(to:$0.appendingPathComponent("model.pte")) }
        ]
        for (index,mutation) in mutations.enumerated() {
            let source=parent.appendingPathComponent("source-\(index)"),target=parent.appendingPathComponent("owned-\(index)")
            try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true);try mutation(source)
            do { _=try await ModelFolderImport.copy(from:source,to:target,format:.executorchMLX);XCTFail("Incompatible case \(index) admitted") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
        }
    }
    func testMLXOwnedComponentsHashesAndSourceRemoval() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let source=root.appendingPathComponent("source"),target=root.appendingPathComponent("owned")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true);try mlx(source)
        let value=try await ModelFolderImport.copy(from:source,to:target,format:.mlx,access:.coordinated)
        XCTAssertEqual(value.entryFile,"config.json");XCTAssertEqual(value.family,"qwen3");XCTAssertEqual(value.files.map(\.path),["config.json","model.safetensors","tokenizer.json","tokenizer_config.json"])
        try FileManager.default.removeItem(at:source)
        for file in value.files { try ModelFileTransfer.verify(file.destination(in:target),file:file) }
    }
    func testIndexedMLXShardsAndMissingOrEscapingShardRefusal() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };try mlx(root)
        let shard=root.appendingPathComponent("shards/one.safetensors");try FileManager.default.createDirectory(at:shard.deletingLastPathComponent(),withIntermediateDirectories:true);try Data("shard".utf8).write(to:shard)
        let index=root.appendingPathComponent("model.safetensors.index.json")
        try Data("{\"weight_map\":{\"layer\":\"shards/one.safetensors\"}}".utf8).write(to:index)
        let target=root.appendingPathComponent("owned");let value=try await ModelFolderImport.copy(from:root,to:target,format:.mlx)
        XCTAssertTrue(value.files.contains { $0.path == "shards/one.safetensors" });XCTAssertFalse(value.files.contains { $0.path == "model.safetensors" })
        for path in ["missing.safetensors","../outside.safetensors"] {
            try Data("{\"weight_map\":{\"layer\":\"\(path)\"}}".utf8).write(to:index)
            let failed=root.appendingPathComponent(UUID().uuidString)
            do { _=try await ModelFolderImport.copy(from:root,to:failed,format:.mlx);XCTFail("Missing/escaping shard accepted") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath:failed.path))
        }
    }
    func testCompiledExportFactsHashAndExplicitBackendAdmission() async throws {
        let parent=try folder();defer { try? FileManager.default.removeItem(at:parent) };let root=parent.appendingPathComponent("source");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);try compiled(root)
        let target=parent.appendingPathComponent("owned");let value=try await ModelFolderImport.copy(from:root,to:target,format:.xnnpack)
        XCTAssertEqual(value.entryFile,"xnnpack/model.pte");XCTAssertEqual(value.family,"qwen3")
        for file in value.files { try ModelFileTransfer.verify(file.destination(in:target),file:file) }
        for (backend,context,hash) in [("coreml",2048,true),("xnnpack",4096,true),("xnnpack",2048,false)] {
            try compiled(root,backend:backend,context:context,validHash:hash);let failed=parent.appendingPathComponent(UUID().uuidString)
            do { _=try await ModelFolderImport.copy(from:root,to:failed,format:.xnnpack);XCTFail("Unsupported/corrupt export accepted") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath:failed.path))
        }
    }
    func testLinksSpecialFilesAndExistingDestinationRemainUntouched() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };try mlx(root)
        let preserved=root.appendingPathComponent("preserved");try FileManager.default.createDirectory(at:preserved,withIntermediateDirectories:true);let marker=preserved.appendingPathComponent("keep");try Data("keep".utf8).write(to:marker)
        do { _=try await ModelFolderImport.copy(from:root,to:preserved,format:.mlx);XCTFail("Existing folder replaced") } catch {}
        XCTAssertEqual(try Data(contentsOf:marker),Data("keep".utf8))
        let weights=root.appendingPathComponent("model.safetensors");try FileManager.default.removeItem(at:weights)
        let outside=root.appendingPathComponent("outside");try Data("outside".utf8).write(to:outside)
        try FileManager.default.createSymbolicLink(at:weights,withDestinationURL:outside)
        let target=root.appendingPathComponent("failed")
        do { _=try await ModelFolderImport.copy(from:root,to:target,format:.mlx);XCTFail("Linked weights accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path));XCTAssertEqual(try Data(contentsOf:outside),Data("outside".utf8))
        try FileManager.default.removeItem(at:weights);XCTAssertEqual(mkfifo(weights.path,mode_t(0o600)),0)
        do { _=try await ModelFolderImport.copy(from:root,to:target,format:.mlx);XCTFail("FIFO weights accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
    }
    func testQwen25OwnedImportAndUnsupportedProtocolRefusal() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try compiled(source, sourceModel: "Qwen/Qwen2.5-1.5B-Instruct")
        let value = try await ModelFolderImport.copy(from: source, to: root.appendingPathComponent("owned"), format: .xnnpack)
        XCTAssertEqual(value.family, "qwen25"); XCTAssertEqual(value.entryFile, "xnnpack/model.pte")
        for declared in ["Qwen/Qwen2.5-1.5B", "Qwen/Qwen2.5-Coder-1.5B-Instruct", "Qwen/Qwen3.5-2B"] {
            try compiled(source, sourceModel: declared)
            let target = root.appendingPathComponent(UUID().uuidString)
            do { _ = try await ModelFolderImport.copy(from: source, to: target, format: .xnnpack); XCTFail("Unsupported protocol accepted") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }
    func testTwoSupportedCompiledFamiliesRequireExplicitVariantSelection() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try compiled(source)
        let second = source.appendingPathComponent("second"); try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try compiled(second, sourceModel: "Qwen/Qwen2.5-1.5B-Instruct")
        let target = root.appendingPathComponent("owned")
        do { _ = try await ModelFolderImport.copy(from: source, to: target, format: .xnnpack); XCTFail("Ambiguous export accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testCancelledCoordinatedFolderWaitCleansAndNextImportRecovers() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };try mlx(root)
        let held=expectation(description:"Writer holds folder"),done=expectation(description:"Writer released")
        let release=DispatchSemaphore(value:0);defer { release.signal() }
        DispatchQueue.global().async {
            var error:NSError?
            NSFileCoordinator(filePresenter:nil).coordinate(writingItemAt:root,options:[],error:&error) { _ in held.fulfill();release.wait() }
            XCTAssertNil(error);done.fulfill()
        }
        await fulfillment(of:[held],timeout:3)
        let target=root.appendingPathComponent("owned"),finished=expectation(description:"Cancelled reader finished")
        let task=Task { () -> Bool in
            defer { finished.fulfill() }
            do { _=try await ModelFolderImport.copy(from:root,to:target,format:.mlx,access:.coordinated);return false } catch is CancellationError { return true } catch { return false }
        }
        try await Task.sleep(nanoseconds:100_000_000);task.cancel();await fulfillment(of:[finished],timeout:3)
        let cancelled=await task.value;XCTAssertTrue(cancelled);XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
        release.signal();await fulfillment(of:[done],timeout:3)
        _=try await ModelFolderImport.copy(from:root,to:target,format:.mlx,access:.coordinated)
    }
}
