import XCTest
import UIKit
import SwiftUI
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    @MainActor func testNativeUsageMeasurementsAcrossAdapters() async throws {
        let catalogue = try HubClient.pinnedCatalogue()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-usage-adapters-" + UUID().uuidString)
        let ledger = try UsageStore(file: root.appendingPathComponent("usage.json"))
        let messages = [["role":"system","content":"Answer briefly."], ["role":"user","content":"Name one fruit."]]
        var observations: [[String:Any]] = [], completed = false, installed: [LocalModel] = []
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle; try? FileManager.default.removeItem(at: root)
            let attachment = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: [
                "purpose":"native-usage-measurements-four-adapters", "completed":completed, "observations":observations,
                "limitations":["Pinned artifacts and one short prompt per backend, each fresh then system-prefix warmed. Metrics mapping and persistence checks, not controlled performance or model-quality comparisons.",
                    "GGUF and MLX decode pairs exclude the first generated token. ExecuTorch has no split here and records only elapsed generation time. Standalone warm work outside generation is not counted."]
            ],options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Four adapter usage measurements"; attachment.lifetime = .keepAlways; add(attachment)
        }
        for backend in [ModelBackend.llamaCPU,.llamaMetal,.mlx,.xnnpack] {
            var model = try XCTUnwrap(catalogue.first { $0.backend == (backend == .llamaCPU ? .llamaMetal : backend) })
            model.backend = backend; model.settings.temperature = 0; model.settings.topP = 1
            model.settings.repeatPenalty = 1; model.settings.outputTokens = 16; model.settings.thinking = false
            let kind = backend == .mlx ? "mlx" : backend == .xnnpack ? "executorch" : "gguf"
            let directory = cachedDirectory(artifact:kind,revision:try XCTUnwrap(model.revision))
            for file in model.files { try ModelDownloads.verify(file.destination(in:directory),file:file) }
            model.state = .ready; installed.append(model)
            let runtime = try RuntimeFactory.make(model); try await runtime.load(model:model,directory:directory)
            let count = try await runtime.promptSize(messages:messages,settings:model.settings,tools:[])
            for warmed in [false,true] {
                await runtime.reset()
                if warmed { try await runtime.warm(messages:[messages[0]],settings:model.settings) }
                var result: RuntimeReply?
                for try await event in runtime.stream(messages:messages,settings:model.settings) { if case .reply(let reply) = event { result = reply } }
                let reply = try XCTUnwrap(result), usage = try XCTUnwrap(reply.usage)
                XCTAssertFalse(reply.cancelled); XCTAssertFalse(reply.content.isEmpty)
                XCTAssertEqual(usage.generatedTokens,reply.generatedTokens); XCTAssertEqual(usage.cachedTokens,reply.cachedTokens)
                XCTAssertEqual(usage.promptTokens + usage.cachedTokens,count.tokens)
                XCTAssertGreaterThan(usage.generatedTokens,0); XCTAssertGreaterThan(usage.inferenceMilliseconds,0)
                if warmed { XCTAssertGreaterThan(usage.cachedTokens,0) } else { XCTAssertEqual(usage.cachedTokens,0) }
                if backend == .xnnpack {
                    XCTAssertNil(usage.prefillMilliseconds); XCTAssertNil(usage.decodeMilliseconds); XCTAssertNil(usage.decodeTokens)
                } else {
                    if backend == .llamaCPU || backend == .llamaMetal { XCTAssertEqual(usage.prefillIncludesCompute,true) }
                    XCTAssertGreaterThan(try XCTUnwrap(usage.prefillMilliseconds),0)
                    XCTAssertGreaterThanOrEqual(try XCTUnwrap(usage.decodeMilliseconds),0)
                    XCTAssertEqual(usage.decodeTokens,max(0,reply.generatedTokens - 1))
                }
                let row = UsageRecord(modelID:model.id,modelName:model.name,backend:backend,measurements:usage,weights:UsageWeights(model:model))
                XCTAssertNotNil(row.weights)
                try await ledger.record(row); try await ledger.record(row)
                let reopen = try UsageStore(file:root.appendingPathComponent("usage.json")), rows = await reopen.list()
                XCTAssertEqual(rows.last,row)
                observations.append(["backend":backend.rawValue,"warmed":warmed,"answer":reply.content,
                    "artifact":NativeAgentArtifact.evidence(model),"promptTokens":usage.promptTokens,"cachedTokens":usage.cachedTokens,
                    "generatedTokens":usage.generatedTokens,"inferenceMilliseconds":usage.inferenceMilliseconds,
                    "prefillIncludesCompute":usage.prefillIncludesCompute as Any? ?? NSNull(),
                    "prefillMilliseconds":usage.prefillMilliseconds as Any? ?? NSNull(),
                    "decodeMilliseconds":usage.decodeMilliseconds as Any? ?? NSNull(),"decodeTokens":usage.decodeTokens as Any? ?? NSNull()])
            }
            runtime.cancel(); await runtime.reset()
        }
        let summary = await ledger.summary(); XCTAssertEqual(summary.totals.passes,8); XCTAssertEqual(summary.perModel.count,4)
        let rows = await ledger.list()
        for backend in [ModelBackend.llamaCPU,.llamaMetal,.mlx,.xnnpack] {
            let calibration = ThroughputEstimates(records:rows,installed:installed,backend:backend)
            if backend == .xnnpack { XCTAssertNil(calibration.prefill); XCTAssertNil(calibration.decode) }
            else {
                let decode = try XCTUnwrap(calibration.decode), prefill = try XCTUnwrap(calibration.prefill)
                let totals = try XCTUnwrap(summary.perModel.first { $0.backend == backend }).totals
                XCTAssertEqual(decode.measuredTokensPerSecond,totals.decodeTokensPerSecond)
                XCTAssertEqual(prefill.measuredTokensPerSecond,totals.prefillTokensPerSecond)
                XCTAssertEqual(decode.predict(weightBytes:decode.weights.bytes*2,backend:backend),decode.measuredTokensPerSecond/2)
                XCTAssertNil(decode.predict(weightBytes:decode.weights.bytes,backend:backend == .mlx ? .llamaMetal : .mlx))
            }
        }
        completed = observations.count == 8
    }

    @MainActor func testNativeUsageControllerStorageAndDashboard() async throws {
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-usage-product-" + UUID().uuidString)
        let suite = "native.usage." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        let libraryFile = root.appendingPathComponent("models.json"), ledgerFile = root.appendingPathComponent("usage.json")
        let library = try ModelLibrary(file:libraryFile), ledger = try UsageStore(file:ledgerFile)
        let downloads = ModelDownloads(root:root.appendingPathComponent("Models"),library:library,sessionIdentifier:"native.usage.downloads."+UUID().uuidString)
        let chat = ChatController(store:try ConversationStore(file:root.appendingPathComponent("conversations.json")),downloads:downloads,defaults:defaults,usage:ledger)
        var observations: [[String:Any]] = [], completed = false
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            chat.prepareForInactivity(); downloads.cancelAllTransfers(); UIApplication.shared.isIdleTimerDisabled = idle
            defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root)
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:[
                "purpose":"native-product-usage-ledger-storage-dashboard", "completed":completed,
                "observations":observations,"artifact":NativeAgentArtifact.evidence(pinned),
                "limitations":["Actual production import, controller, ledger and dashboard snapshot APIs. Direct public API calls, not user gestures or app-process termination.",
                    "Native view is hosted for evidence. Dynamic Type, VoiceOver, native navigation and broader memory-fit/model predictions remain unverified.",
                    "GGUF memory is weights plus estimated F16 KV only. It omits runtime buffers/recurrent state and does not guarantee fit."]
            ],options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Product usage and storage"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let source = cachedDirectory(artifact:"gguf",revision:try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source,file:try XCTUnwrap(pinned.files.first)); await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first); model.backend = .llamaCPU
        model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1; model.settings.outputTokens = 16
        try await downloads.saveSettings(model); await chat.load(model); XCTAssertNil(chat.error)
        chat.draft = "Name one fruit."; await chat.send(); try await waitUntil(seconds:60) { !chat.busy }
        XCTAssertNil(chat.error); XCTAssertNil(chat.usageError)
        let summary = await ledger.summary(); XCTAssertEqual(summary.totals.passes,1); XCTAssertGreaterThan(summary.totals.generatedTokens,0)
        let stored = try XCTUnwrap(chat.current), answer = try XCTUnwrap(stored.messages.last { $0.role == .assistant })
        XCTAssertEqual(answer.status,.complete)
        let directory = downloads.directory(model)
        try Data(repeating:1,count:17).write(to:directory.appendingPathComponent("arrival-owned-staging"))
        try Data(repeating:2,count:9).write(to:downloads.root.appendingPathComponent("orphan-test"))
        let dashboard = DashboardController(); await dashboard.refresh(chat:chat,downloads:downloads)
        let snapshot = try XCTUnwrap(dashboard.storage), row = try XCTUnwrap(snapshot.rows.first)
        XCTAssertEqual(row.declaredFileBytes,pinned.files[0].bytes)
        XCTAssertEqual(row.incompleteBytes,17); XCTAssertEqual(snapshot.unlistedBytes,9)
        XCTAssertEqual(snapshot.ownedBytes,try XCTUnwrap(pinned.files[0].bytes)+26)
        XCTAssertEqual(row.metadata?.f16KVBytes(context:2048),234881024)
        XCTAssertEqual(row.weights,UsageWeights(model:model)); XCTAssertEqual(snapshot.modelsWithKnownWeights(downloads.models),downloads.models)
        XCTAssertEqual(dashboard.summary,summary); XCTAssertEqual(dashboard.conversationCount,1)
        let rows = await ledger.list(), calibration = ThroughputEstimates(records:dashboard.usageRecords,installed:downloads.models,backend:.llamaCPU)
        XCTAssertEqual(dashboard.usageRecords,rows); XCTAssertEqual(rows.first?.weights,UsageWeights(model:model))
        XCTAssertEqual(calibration.decode?.measuredTokensPerSecond,summary.totals.decodeTokensPerSecond)
        XCTAssertEqual(calibration.prefill?.measuredTokensPerSecond,summary.totals.prefillTokensPerSecond)
        XCTAssertGreaterThan(try XCTUnwrap(dashboard.headroomBytes),0); XCTAssertGreaterThan(try XCTUnwrap(dashboard.freeStorageBytes),0)
        observations.append(["stage":"actual-product-before-delete","answer":answer.content,"passes":summary.totals.passes,
            "generatedTokens":summary.totals.generatedTokens,"freshPromptTokens":summary.totals.promptTokens,
            "ownedModelBytes":snapshot.ownedBytes,"partialOrStagingBytes":row.incompleteBytes,"unlistedBytes":snapshot.unlistedBytes,
            "headroomBytes":dashboard.headroomBytes ?? -1,"freeStorageBytes":dashboard.freeStorageBytes ?? -1])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene:scene)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        for style in [UIUserInterfaceStyle.light,.dark] {
            // A Charts render can retain the previous trait's resolved colors
            // during an immediate UIKit style flip. Host each actual appearance
            // separately and allow its view task/render to finish before capture.
            window.overrideUserInterfaceStyle = style
            let hosted = UIHostingController(rootView:NavigationStack { DashboardScreen(chat:chat,downloads:downloads) }
                .font(OWTheme.interface()).tint(OWTheme.text).foregroundStyle(OWTheme.text)
                .preferredColorScheme(style == .light ? .light : .dark))
            window.rootViewController = hosted; window.makeKeyAndVisible(); hosted.view.layoutIfNeeded()
            try await Task.sleep(for:.seconds(1)); hosted.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds:hosted.view.bounds).image { _ in hosted.view.drawHierarchy(in:hosted.view.bounds,afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image); attachment.name = "Usage dashboard \(style == .light ? "light" : "dark")"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let branch = try await chat.store.branch(stored.id,through:answer.id)
        try await chat.store.delete(stored.id); try await chat.store.delete(branch.id)
        // This owned fixture performs no more inference after removal. Model
        // deletion is called directly, not through the loaded-model UI guard.
        chat.prepareForInactivity(); try await downloads.remove(model)
        let reopened = try UsageStore(file:ledgerFile), after = await reopened.summary()
        XCTAssertEqual(after,summary)
        await dashboard.refresh(chat:chat,downloads:downloads); XCTAssertEqual(dashboard.conversationCount,0)
        XCTAssertEqual(dashboard.summary,summary); XCTAssertEqual(dashboard.storage?.ownedBytes,9)
        observations.append(["stage":"deleted-chat-branch-and-model-reopened-ledger","passes":after.totals.passes,
            "generatedTokens":after.totals.generatedTokens,"conversations":dashboard.conversationCount,"remainingModelFolderBytes":dashboard.storage?.ownedBytes ?? -1])
        completed = after == summary && dashboard.conversationCount == 0
    }
}
