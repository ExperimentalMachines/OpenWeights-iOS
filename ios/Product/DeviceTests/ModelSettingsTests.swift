import XCTest
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    private func settingsReply(_ runtime: any ChatRuntime, messages: [[String:String]], settings: ModelSettings) async throws -> RuntimeReply {
        var reply: RuntimeReply?
        for try await event in runtime.stream(messages:messages,settings:settings) {
            if case .reply(let value) = event { reply = value }
        }
        return try XCTUnwrap(reply)
    }
    @MainActor func testNativeSharedSettingsReloadAndGreedyFilterControls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-native-" + UUID().uuidString)
        let suite = "org.experimentalmachines.openweights.settings-native." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        let libraryFile = root.appendingPathComponent("models.json")
        let downloads = ModelDownloads(root:root.appendingPathComponent("Models"),library:try ModelLibrary(file:libraryFile),sessionIdentifier:suite)
        let memory = MemoryController(store:try MemoryStore(file:root.appendingPathComponent("memory.json")),defaults:defaults)
        memory.readEnabled = false; memory.writeEnabled = false
        let chat = ChatController(store:try ConversationStore(file:root.appendingPathComponent("conversations.json")),downloads:downloads,memory:memory,defaults:defaults)
        var observations: [[String:Any]] = []; var completed = false
        defer {
            chat.prepareForInactivity(); downloads.cancelAllTransfers(); defaults.removePersistentDomain(forName:suite)
            try? FileManager.default.removeItem(at:root)
            let value: [String:Any] = ["purpose":"native-shared-model-settings-reload-and-top-k-one-controls", "completed":completed,
                "observations":observations, "operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations":["Uses real pinned GGUF CPU and Metal adapters and an owned paused metadata profile. The paused profile is never loaded.",
                    "Top K 1 controls compare against greedy decoding on one fixed prompt after reset. This does not establish general model quality, sampler distributions or speed.",
                    "No MLX/XNNPACK inference, notification permission, UI gesture or rendered-accessibility claim."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Native shared settings and filters"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let source = cachedDirectory(artifact:"gguf",revision:try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source,file:try XCTUnwrap(pinned.files.first)); await downloads.importGGUF(source)
        var a = try XCTUnwrap(downloads.models.first)
        a.backend = .llamaCPU; a.settings.temperature = 0; a.settings.outputTokens = 64
        a.settings.topP = 1; a.settings.repeatPenalty = 1; a.settings.thinking = false
        try await downloads.save(a); await chat.load(a); XCTAssertNil(chat.error)
        var b = LocalModel(name:"Owned pending settings profile",backend:.llamaMetal,entryFile:"pending.gguf",files:[ModelFile(path:"pending.gguf")])
        b.state = .paused; b.settings.contextTokens = 4096; b.settings.threads = 2
        try await downloads.save(b)
        b.settings.temperature = 0.7; b.settings.outputTokens = 64; b.settings.topP = 1
        b.settings.topK = 1; b.settings.minP = 0.2; b.settings.repeatPenalty = 1
        try await chat.saveModelSettings(b)
        XCTAssertEqual(chat.loadedModel?.id,a.id); XCTAssertEqual(chat.loadedModel?.backend,.llamaCPU)
        XCTAssertEqual(chat.loadedModel?.settings,a.settings.sharingGeneration(from:b.settings))
        let reopened = try ModelLibrary(file:libraryFile), models = await reopened.list()
        XCTAssertEqual(models.first { $0.id == b.id }?.state,.paused)
        XCTAssertEqual(models.first { $0.id == b.id }?.settings.contextTokens,4096)
        XCTAssertEqual(models.first { $0.id == a.id }?.settings.topK,1)
        observations.append(["stage":"other-profile-save-reloads-current-real-CPU", "currentIDUnchanged":chat.loadedModel?.id == a.id,
            "currentContext":chat.loadedModel?.settings.contextTokens ?? 0, "otherContext":4096, "topK":1, "minP":0.2])
        let before = try Data(contentsOf:libraryFile)
        var invalid = b; invalid.settings.outputTokens = invalid.settings.contextTokens
        do { try await chat.saveModelSettings(invalid); XCTFail("Invalid settings were saved") } catch {}
        XCTAssertEqual(try Data(contentsOf:libraryFile),before); XCTAssertEqual(chat.loadedModel?.id,a.id)
        invalid.settings.outputTokens = 2048
        do { try await chat.saveModelSettings(invalid); XCTFail("Settings incompatible with the current model were saved") } catch {}
        XCTAssertEqual(try Data(contentsOf:libraryFile),before); XCTAssertEqual(chat.loadedModel?.settings.topK,1)
        let messages = [["role":"system","content":"Answer clearly and briefly."], ["role":"user","content":"What is 1 + 1? Reply with only the number."]]
        for backend in [ModelBackend.llamaCPU,.llamaMetal] {
            var model = a; model.backend = backend; model.settings = a.settings.sharingGeneration(from:b.settings)
            let runtime = try RuntimeFactory.make(model); try await runtime.load(model:model,directory:downloads.directory(a))
            var greedy = model.settings; greedy.temperature = 0
            let control = try await settingsReply(runtime,messages:messages,settings:greedy)
            await runtime.reset()
            let filtered = try await settingsReply(runtime,messages:messages,settings:model.settings)
            XCTAssertFalse(control.cancelled); XCTAssertFalse(filtered.cancelled)
            XCTAssertFalse(control.content.isEmpty); XCTAssertEqual(filtered.content,control.content)
            observations.append(["stage":"top-k-one-matches-reset-greedy", "backend":backend.rawValue,
                "temperature":model.settings.temperature, "topK":1, "minP":0.2,
                "greedy":control.content, "filtered":filtered.content])
        }
        completed = true
    }
}
