import XCTest
import UIKit
import SwiftUI
import OpenWeightsCore
@testable import OpenWeights

private final class NativeWeakImportedRuntime {
    weak var value: NativeObservedRuntime?
    init(_ value: NativeObservedRuntime) { self.value = value }
}

extension ProductTests {
    @MainActor func testNativeOwnedMLXFolderImportAndChat() async throws { try await nativeOwnedFolder(format:.mlx) }
    @MainActor func testNativeOwnedExecuTorchMLXFolderImportAndChat() async throws { try await nativeOwnedFolder(format:.executorchMLX,selected:NativeCompiledArtifact.mlxDelegate()) }
    @MainActor func testNativeOwnedCompiledFolderImportAndChat() async throws { try await nativeOwnedFolder(format:.xnnpack) }
    @MainActor func testNativeOwnedQwen25CompiledFolderImportAndChat() async throws { try await nativeOwnedFolder(format:.xnnpack, selected:NativeCompiledArtifact.qwen25()) }
    @MainActor private func nativeOwnedFolder(format:ModelFolderFormat, selected:LocalModel? = nil) async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-folder-import-" + UUID().uuidString)
        let source=root.appendingPathComponent(format == .mlx ? "Qwen3-MLX" : selected?.family == "qwen25" ? "Qwen2.5-XNNPACK" : "Qwen3-XNNPACK")
        let suite=root.lastPathComponent,defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        let libraryFile=root.appendingPathComponent("models.json"),library=try ModelLibrary(file:libraryFile)
        let downloads=ModelDownloads(root:root.appendingPathComponent("Models"),library:library,sessionIdentifier:"org.experimentalmachines.folder."+UUID().uuidString)
        let idle=UIApplication.shared.isIdleTimerDisabled;UIApplication.shared.isIdleTimerDisabled=true
        var completed=false,actions:[String]=[],copiedBytes:Int64=0, firstAnswer=""
        defer {
            UIApplication.shared.isIdleTimerDisabled=idle
            downloads.cancelAllTransfers();defaults.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)
            folderImportEvidence(["purpose":"native-owned-"+format.rawValue+"-folder-import-and-chat","completed":completed,"actions":actions,"copiedBytes":copiedBytes,"selectedFamily":selected?.family ?? "qwen3","firstAnswer":firstAnswer,
                "limitations":["Uses the real pinned cached model through an isolated same-sandbox source folder and actual owned byte copies. No external provider, picker gesture or OS suspension claim.","Source fixture hard-links weights only to avoid a second staging copy. Imported weights must have a different inode, survive source removal, and load through the actual product runtime. No performance or general family/quality claim."]])
        }
        let pinned=try XCTUnwrap(selected ?? HubClient.pinnedCatalogue().first { $0.backend == (format == .mlx ? .mlx : .xnnpack) })
        let cached=cachedDirectory(artifact:format == .mlx ? "mlx" : format == .executorchMLX ? "executorch-mlx" : "executorch",revision:try XCTUnwrap(pinned.revision))
        for file in pinned.files {
            let original=try file.destination(in:cached),staged=try file.destination(in:source)
            try ModelDownloads.verify(original,file:file)
            try FileManager.default.createDirectory(at:staged.deletingLastPathComponent(),withIntermediateDirectories:true)
            if file.path.hasSuffix(".safetensors") || file.path.hasSuffix(".pte") { try FileManager.default.linkItem(at:original,to:staged) }
            else { try FileManager.default.copyItem(at:original,to:staged) }
        }
        await downloads.importFolder(source,format:format)
        XCTAssertNil(downloads.error);XCTAssertNil(downloads.importingName)
        var model=try XCTUnwrap(downloads.models.first);XCTAssertEqual(model.state,.ready);XCTAssertEqual(model.backend,pinned.backend);XCTAssertEqual(model.family,pinned.family)
        XCTAssertEqual(Set(model.files.map(\.path)),Set(pinned.files.map(\.path)))
        for file in model.files {
            let expected=try XCTUnwrap(pinned.files.first { $0.path == file.path })
            XCTAssertEqual(file.sha256,expected.sha256);XCTAssertEqual(file.bytes,expected.bytes)
            let owned=try file.destination(in:downloads.directory(model));try ModelDownloads.verify(owned,file:file)
            let ownedInode=try FileManager.default.attributesOfItem(atPath:owned.path)[.systemFileNumber] as? NSNumber
            let sourceInode=try FileManager.default.attributesOfItem(atPath:source.appendingPathComponent(file.path).path)[.systemFileNumber] as? NSNumber
            XCTAssertNotEqual(ownedInode,sourceInode);copiedBytes += file.bytes ?? 0
        }
        try FileManager.default.removeItem(at:source)
        actions.append("full-size-components-hashed-and-owned-as-distinct-files-source-removed")
        let reopened=try ModelLibrary(file:libraryFile);let rows=await reopened.list();XCTAssertEqual(rows,[model])
        model.settings.temperature=0;model.settings.repeatPenalty=1;model.settings.outputTokens=32
        try await downloads.saveSettings(model)
        weak var loadedRuntime:NativeObservedRuntime?
        let factory:(LocalModel) throws -> any ChatRuntime = { model in
            let observed=NativeObservedRuntime(try RuntimeFactory.make(model));loadedRuntime=observed;return observed
        }
        var chat:ChatController?=ChatController(store:try ConversationStore(file:root.appendingPathComponent("chats.json")),downloads:downloads,defaults:defaults,runtimeFactory:factory)
        await chat?.load(model);XCTAssertNil(chat?.error);XCTAssertEqual(chat?.loadedModel?.id,model.id)
        chat?.draft=format == .executorchMLX ? "My project is Cedar. Reply with only the project name." : "Reply with exactly Cedar.";await chat?.send();try await waitUntil(seconds:90) { chat?.busy == false }
        XCTAssertNil(chat?.error);var saved=try XCTUnwrap(chat?.current);XCTAssertEqual(saved.messages.count,2);XCTAssertTrue(["Cedar", "Cedar."].contains(saved.messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""), saved.messages.last?.content ?? "")
        firstAnswer=try XCTUnwrap(saved.messages.last?.content)
        if selected?.family == "qwen25" { XCTAssertTrue(["Cedar","Cedar."].contains(firstAnswer.trimmingCharacters(in:.whitespacesAndNewlines)),firstAnswer) }
        actions.append("actual-product-adapter-load-and-local-chat-after-source-removal")
        folderImportEvidence(["purpose":"native-folder-import-before-controller-reopen","completed":false,"selectedFamily":model.family ?? "","copiedBytes":copiedBytes,"firstAnswer":firstAnswer,"runtimeTrace":loadedRuntime?.snapshot() ?? [:],"artifact":NativeAgentArtifact.evidence(selected ?? pinned)])
        if format == .executorchMLX {
            chat?.draft="What is my project? Reply with only the project name.";await chat?.send()
            try await waitUntil(seconds:90) { chat?.busy == false };XCTAssertNil(chat?.error)
            saved=try XCTUnwrap(chat?.current);XCTAssertEqual(saved.messages.last?.content.trimmingCharacters(in:.whitespacesAndNewlines),"Cedar")
            let streams=try XCTUnwrap(loadedRuntime?.snapshot()["streams"] as? [[String:Any]])
            let reply=try XCTUnwrap(streams.last?["reply"] as? [String:Any])
            XCTAssertGreaterThan(try XCTUnwrap(reply["cachedTokens"] as? Int),0)
            folderImportEvidence(["purpose":"native-executorch-mlx-controller-retained-turn","runtimeTrace":loadedRuntime?.snapshot() ?? [:]])
            actions.append("actual-controller-second-turn-recalls-Cedar-with-nonzero-cache")
        }
        let previous=NativeWeakImportedRuntime(try XCTUnwrap(loadedRuntime))
        // Reopening represents replacement of the first controller. Keeping both
        // loaded at once allocates a second large compiled model in this fixture.
        chat?.cancel();chat=nil
        try await waitUntil(seconds:3) { previous.value == nil };XCTAssertNil(previous.value)
        actions.append("first-runtime-wrapper-releases-before-reopened-controller-load")
        let restored=ChatController(store:try ConversationStore(file:root.appendingPathComponent("chats.json")),downloads:downloads,defaults:defaults,runtimeFactory:factory)
        await restored.open(saved);XCTAssertNil(restored.error);XCTAssertEqual(restored.current?.messages,saved.messages);XCTAssertEqual(restored.loadedModel?.id,model.id)
        actions.append("model-metadata-and-conversation-survive-store-controller-reopen")
        if format == .executorchMLX {
            restored.draft="What is my project? Reply with only the project name.";await restored.send()
            try await waitUntil(seconds:90) { !restored.busy };XCTAssertNil(restored.error)
            XCTAssertEqual(restored.current?.messages.last?.content.trimmingCharacters(in:.whitespacesAndNewlines),"Cedar")
            folderImportEvidence(["purpose":"native-executorch-mlx-controller-reopen-recall","runtimeTrace":loadedRuntime?.snapshot() ?? [:]])
            actions.append("reopened-controller-recalls-Cedar-through-new-runtime-and-warmed-history")
            let image=try await NativeMountedView.capture(NavigationStack { ModelSettingsScreen(model:model,downloads:downloads,chat:restored) },size:CGSize(width:390,height:1000),style:.dark)
            let attachment=XCTAttachment(image:image);attachment.name="ExecuTorch MLX actual model settings";attachment.lifetime = .keepAlways;add(attachment)
        }
        if format == .mlx {
            let image=try await NativeMountedView.capture(NavigationStack { ModelsScreen(downloads:downloads,chat:restored) },size:CGSize(width:390,height:1000),style:.dark)
            let attachment=XCTAttachment(image:image);attachment.name="Imported MLX model in actual library";attachment.lifetime = .keepAlways;add(attachment)
        }
        completed=true
    }
    @MainActor func testNativeModelFolderImportStopAndRecovery() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-folder-stop-"+UUID().uuidString),source=root.appendingPathComponent("MLX-source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        for (path,text) in [("config.json","{\"model_type\":\"qwen3\"}"),("tokenizer.json","{}"),("tokenizer_config.json","{}"),("model.safetensors","fixture weights")] { try Data(text.utf8).write(to:source.appendingPathComponent(path)) }
        let library=try ModelLibrary(file:root.appendingPathComponent("models.json")),downloads=ModelDownloads(root:root.appendingPathComponent("Models"),library:library)
        let held=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
        defer { release.signal();try? FileManager.default.removeItem(at:root) }
        DispatchQueue.global().async {
            var error:NSError?
            NSFileCoordinator(filePresenter:nil).coordinate(writingItemAt:source,options:[],error:&error) { _ in held.signal();_ = release.wait(timeout:.now()+20) }
            done.signal()
        }
        let acquired=await Task.detached { held.wait(timeout:.now()+3) == .success }.value;XCTAssertTrue(acquired)
        let pending=Task { @MainActor in await downloads.importFolder(source,format:.mlx) }
        try await waitUntil(seconds:3) { downloads.importingName != nil };try await Task.sleep(nanoseconds:150_000_000)
        XCTAssertTrue(downloads.models.isEmpty);downloads.cancelFolderImport()
        try await waitUntil(seconds:3) { downloads.importingName == nil };await pending.value
        XCTAssertNil(downloads.error);XCTAssertTrue(downloads.models.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:downloads.root.path))
        release.signal();let released=await Task.detached { done.wait(timeout:.now()+3) == .success }.value;XCTAssertTrue(released)
        await downloads.importFolder(source,format:.mlx);XCTAssertNil(downloads.error);XCTAssertEqual(downloads.models.count,1)
        let model=try XCTUnwrap(downloads.models.first);for file in model.files { try ModelDownloads.verify(file.destination(in:downloads.directory(model)),file:file) }
        folderImportEvidence(["purpose":"native-model-folder-stop-and-import-recovery","completed":true,"limitations":["Controlled same-sandbox coordinated writer and tiny MLX file fixtures. Actual Stop method cancels the provider wait; no mid-weight-copy gesture or external provider claim. Tiny weights are not loaded as a model."]])
    }
    private func folderImportEvidence(_ value:[String:Any]) {
        let a=XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        a.name=value["purpose"] as? String ?? "Model folder import";a.lifetime = .keepAlways;add(a)
    }
}
