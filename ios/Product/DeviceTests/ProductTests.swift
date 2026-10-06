import XCTest
import Network
import SwiftUI
import Combine
import OpenWeightsCore
@testable import OpenWeights

@MainActor final class ProductTests: XCTestCase {
    func testNativePinnedGGUFHeaderAndCurrentMemoryHeadroom() async throws {
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        var completed = false; var observations: [String: Any] = [:]
        defer { attach(["purpose": "native-pinned-gguf-header-architecture-and-memory-preview", "completed": completed,
            "observations": observations, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations": ["Public partial header request without stored credentials. No full model download or published checksum validation in this test.", "App memory headroom is advisory. The cache calculation excludes runtime buffers and recurrent state. This test does not establish that a model will fit or exercise touch navigation."]]) }
        let model = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let source = try HubGGUFRangeSource(model: model, useStoredCredential: false)
        let metadata = try await GGUFHeaderParser(source: source).parse()
        let names = Set(OWRuntimeSession.registeredArchitectureNames())
        XCTAssertTrue(names.contains("qwen3")); XCTAssertTrue(names.contains("llama"))
        XCTAssertFalse(names.contains("unknown")); XCTAssertFalse(names.contains("clip"))
        XCTAssertNil(metadata.standaloneIssue(registeredArchitectures: names))
        XCTAssertEqual(metadata.architecture, "qwen3"); XCTAssertEqual(metadata.blocks, 28)
        XCTAssertEqual(metadata.f16KVBytes(context: 2048), 234881024)
        XCTAssertLessThanOrEqual(metadata.fetchedBytes, 262144)
        let total = await source.totalBytes; XCTAssertEqual(total, 396705472)
        let headroom = OWRuntimeSession.availableMemoryBytes().int64Value
        XCTAssertGreaterThan(headroom, 0)
        let free = try FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        let preview = GGUFMemoryPreview(metadata: metadata, weightBytes: total, context: 2048, headroomBytes: headroom, storageBytes: free)
        XCTAssertEqual(preview.weightsAndKVBytes, 631586496)
        XCTAssertEqual(preview.headroomBytes, headroom)
        observations = ["repository": model.repository ?? "", "revision": model.revision ?? "", "file": model.entryFile,
            "headerFetchedBytes": metadata.fetchedBytes, "fileBytes": total ?? 0, "architecture": metadata.architecture,
            "registeredArchitectureCount": names.count, "trainingContext": metadata.trainingContext,
            "weightsAndF16KVAt2048Bytes": preview.weightsAndKVBytes ?? -1, "currentAppHeadroomBytes": headroom,
            "freeStorageBytes": free ?? -1, "exceedsCurrentHeadroom": preview.exceedsCurrentHeadroom]
        completed = metadata.architecture == "qwen3" && preview.weightsAndKVBytes == 631586496 && headroom > 0
    }
    func testNativeDiscoveryControllerPagingFailureAndRetry() async throws {
        let transport = DiscoveryFixtureTransport()
        let controller = DiscoveryController(client: HubDiscoveryClient(transport: transport))
        var query = HubQuery(); query.runtimes = [.gguf]; query.text = "Cedar"
        var completed = false
        defer { attach(["purpose": "native-discovery-controller-paging-failure-retry", "completed": completed,
            "repositories": controller.models.map(\.id), "hasMore": controller.hasMore,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations": ["Actual native controller with injected Hub responses. No external requests, touch navigation, model download, loading or inference."]]) }
        func idle() async throws {
            for _ in 0..<200 {
                if !controller.busy && !controller.loadingMore { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("Discovery controller did not become idle")
            throw URLError(.timedOut)
        }
        controller.search(query); try await idle()
        XCTAssertEqual(controller.models.map(\.id), ["org/first"]); XCTAssertTrue(controller.hasMore)
        controller.loadMore(); controller.loadMore(); try await idle()
        XCTAssertNotNil(controller.error); XCTAssertEqual(controller.models.map(\.id), ["org/first"])
        XCTAssertTrue(controller.hasMore)
        controller.retry(); try await idle()
        XCTAssertNil(controller.error); XCTAssertEqual(controller.models.map(\.id), ["org/first", "org/second"])
        XCTAssertFalse(controller.hasMore)
        let requests = await transport.requests; XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(URLComponents(url: requests[2], resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value, "native-next")
        completed = controller.error == nil && controller.models.count == 2 && !controller.hasMore && requests.count == 3
    }

    func testNativeLiveHubDiscoveryAndPinnedMetadata() async throws {
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let transport = HubAPITransport(useStoredCredential: false)
        let client = HubDiscoveryClient(transport: transport)
        var query = HubQuery(); query.runtimes = [.gguf]; query.sort = .downloads
        var completed = false; var observations: [[String: Any]] = []
        defer { attach(["purpose": "native-public-hub-discovery-paging-filters-pinned-metadata", "completed": completed,
            "observations": observations, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations": ["Actual public Hugging Face API without stored credentials. No gated access, touch navigation, download, memory-fit, model loading or inference."]]) }
        let first = try await client.search(query, limit: 2)
        XCTAssertEqual(first.models.count, 2); XCTAssertEqual(first.cursors.count, 1)
        let second = try await client.search(query, cursors: first.cursors, limit: 2)
        XCTAssertEqual(second.models.count, 2)
        XCTAssertTrue(Set(first.models.map(\.id)).isDisjoint(with: second.models.map(\.id)))
        observations.append(["first": first.models.map(\.id), "second": second.models.map(\.id)])
        query.author = "LiquidAI"; query.text = "LFM"; query.task = .chat; query.hideGated = true; query.maximumParametersBillions = 2; query.organisationsOnly = true
        let filtered = try await client.search(query, limit: 2)
        XCTAssertFalse(filtered.models.isEmpty)
        XCTAssertTrue(filtered.models.allSatisfy { $0.owner == "LiquidAI" && !$0.gated && $0.pipelineTag == "text-generation" })
        XCTAssertTrue(filtered.models.allSatisfy { $0.namedParametersBillions.map { $0 <= 2 } ?? true })
        let model = try XCTUnwrap(filtered.models.first)
        let details = try await HubClient.details(model.id, transport: transport)
        XCTAssertEqual(details.sha.count, 40); XCTAssertTrue(details.siblings.contains { $0.rfilename.hasSuffix(".gguf") })
        observations.append(["filtered": filtered.models.map(\.id), "repository": details.id, "revision": details.sha, "fileCount": details.siblings.count])
        completed = first.models.count == 2 && second.models.count == 2 && !filtered.models.isEmpty && details.sha.count == 40
    }

    func testNativeLargePageFramingAndToolDisclosure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        var completed = false; var observations: [[String: Any]] = []
        defer { attach(["purpose": "native-product-large-text-page-controlled-framing", "completed": completed,
            "observations": observations, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations": ["Owned fixture wire bytes use the actual decoder/extractor/tools and native filesystem. Resolver and connector are injected, with no external fixture request.", "No model inference, touch navigation or general-page compatibility claim."]]) }
        for framing in ["length", "chunked", "close"] {
            let client = PublicWebClient(resolver: LargePageFixtureResolver(), connector: LargePageFixtureConnector(framing: framing))
            let document = try await client.fetch("https://example.com/large-page", maximumBody: WebPageText.maximumBytes)
            XCTAssertEqual(document.response.body.count, WebPageText.maximumBytes)
            XCTAssertFalse(document.response.bodyIsComplete)
            let tools = WebTools(client: client)
            var settings = WebToolSettings(); settings.fetchEnabled = true
            let find = AgentToolCall(id: "find", name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/large-page\",\"find\":\"Galena\"}")
            let found = await tools.execute(find, settings: settings)
            XCTAssertFalse(found.rejected); XCTAssertTrue(found.untrustedText)
            XCTAssertTrue(found.text.contains("This is a page prefix"))
            XCTAssertTrue(found.text.contains("Nothing on that page matches"))
            await tools.beginTurn(carriesUntrustedText: false)
            let save = AgentToolCall(id: "save", name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/large-page\",\"save_to\":\"\(framing).txt\"}")
            let saved = await tools.execute(save, settings: settings, workspace: workspace)
            observations.append(["framing": framing, "returnedBytes": document.response.body.count,
                "bodyIsComplete": document.response.bodyIsComplete, "findResult": found.text,
                "saveResult": saved.text, "savedRejected": saved.rejected])
            XCTAssertFalse(saved.rejected, saved.text)
            guard !saved.rejected else { return }
            let content = try String(contentsOf: root.appendingPathComponent(framing + ".txt"), encoding: .utf8)
            XCTAssertTrue(content.hasPrefix("[Read stopped at the 512 KiB limit"))
            XCTAssertTrue(content.contains("Saved text was shortened"))
            XCTAssertLessThanOrEqual(content.utf8.count, WebPageText.maximumBytes)
            XCTAssertTrue(content.contains("Cedar")); XCTAssertFalse(content.contains("Galena"))
            observations[observations.count - 1]["savedFileSHA256"] = try ModelFileTransfer.hash(root.appendingPathComponent(framing + ".txt"))
            observations[observations.count - 1]["savedFileBytes"] = content.utf8.count
        }
        completed = true
    }

    func testNativeLiveLargeTextPagePrefix() async throws {
        let log = LargePageTransportLog()
        let connector = ApplePublicWebConnector(observe: { log.append($0) })
        let client = PublicWebClient(connector: connector)
        let address = "https://www.rfc-editor.org/rfc/rfc9110.html"
        var completed = false; var evidence: [String: Any] = [:]
        defer { attach(["purpose": "native-product-live-large-text-page-prefix", "completed": completed,
            "evidence": evidence, "transportEvents": log.snapshot, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations": ["Actual public DNS, Network/TLS and readable-prefix extraction on this one RFC page. Body completion is intentionally not verified beyond the prefix.", "No general website, compression, model inference, UI or energy claim."]]) }
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let document = try await client.fetch(address, maximumBody: WebPageText.maximumBytes, timeout: 60)
        let text = try WebPageText.extract(document)
        evidence = ["address": document.address.url.absoluteString, "status": document.response.status,
            "headers": document.response.headers, "returnedBytes": document.response.body.count,
            "bodyIsComplete": document.response.bodyIsComplete, "readableCharacters": text.utf16.count,
            "containsExpectedTitle": text.contains("HTTP Semantics")]
        XCTAssertEqual(document.response.status, 200)
        XCTAssertEqual(document.response.body.count, WebPageText.maximumBytes)
        XCTAssertFalse(document.response.bodyIsComplete)
        XCTAssertTrue(text.contains("HTTP Semantics"))
        guard document.response.status == 200, document.response.body.count == WebPageText.maximumBytes,
              !document.response.bodyIsComplete, text.contains("HTTP Semantics") else { return }
        completed = true
    }

    func testNativeWebWatchRepeatedFetch() async throws { try await verifyNativeWebWatch(live: true) }
    func testNativeWebWatchChangedFinding() async throws { try await verifyNativeWebWatch(live: false) }
    private func verifyNativeWebWatch(live: Bool) async throws {
        let suite = "openweights.real-web-watch-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let clock = WebWatchFixtureClock(), connector = WebWatchFixtureConnector(live: live)
        let resolver: any PublicWebResolving = live ? SystemPublicWebResolver() : WebWatchFixtureResolver()
        let web = WebController(defaults: defaults, client: PublicWebClient(resolver: resolver, connector: connector))
        web.fetchEnabled = true; web.searchEnabled = false; web.mediaEnabled = false
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")), sessionIdentifier: suite)
        let watchFile = root.appendingPathComponent("watches.json"), conversationFile = root.appendingPathComponent("conversations.json")
        let store = try WatchStore(file: watchFile), watches = WatchController(store: store, defaults: defaults, clock: { clock.now })
        let observed = WebWatchObservedRuntime()
        let chat = ChatController(store: try ConversationStore(file: conversationFile), downloads: downloads, watches: watches, web: web, defaults: defaults, runtimeFactory: { _ in observed })
        watches.bind(chat)
        var completed = false; var actions: [String] = []; var checks: [[String: Any]] = []; var modelRecord: [String: Any] = [:]
        defer {
            chat.cancel(); watches.setForeground(false)
            attach(["purpose": live ? "native-product-real-web-watch-live-iana" : "native-product-real-web-watch-controlled-change", "completed": completed, "actionsReached": actions,
                    "checks": checks, "runtimeTrace": observed.snapshot(), "model": modelRecord, "controllerError": chat.error ?? watches.error ?? "", "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                    "limitations": ["Real pinned GGUF CPU inference through canonical watch/chat/web controllers. Live variant uses real IANA DNS/TLS, controlled variant replaces only page resolution/transport to prove a changed result.", "The controller clock advances 61 seconds between checks. XCTest stays foreground while calling the CPU background entry point. This does not prove OS-granted background execution, notifications, touch navigation, energy or general model quality."]])
        }
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true; defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let source = cachedDirectory(artifact: "gguf", revision: try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source, file: try XCTUnwrap(pinned.files.first)); await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first); model.backend = .llamaCPU
        model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1; model.settings.outputTokens = 192; model.settings.thinking = false
        try await downloads.save(model); await chat.load(model)
        XCTAssertNil(chat.error); XCTAssertTrue(chat.supportsTools); guard chat.error == nil, chat.supportsTools else { return }
        modelRecord = ["repository": pinned.repository ?? "", "revision": pinned.revision ?? "", "entryFile": pinned.entryFile,
                       "sha256": pinned.files.first?.sha256 ?? "", "bytes": pinned.files.first?.bytes ?? 0, "backend": model.backend.rawValue,
                       "temperature": model.settings.temperature, "topP": model.settings.topP, "repeatPenalty": model.settings.repeatPenalty, "outputTokens": model.settings.outputTokens, "contextTokens": model.settings.contextTokens, "threads": model.settings.threads]
        chat.draft = "Reply with Cedar."; await chat.send(); try await waitUntil(seconds: 120) { !chat.busy }
        XCTAssertNil(chat.error); let conversation = try XCTUnwrap(chat.current); actions.append("verified-cpu-model-and-preexisting-chat")
        let address = live ? "https://www.iana.org/domains/reserved" : "https://example.com/watch-status"
        let task = live ? "Use fetch_url to read https://www.iana.org/domains/reserved with find set to example.com on every check. Reply with just one reserved example domain from the fetched result." : "Use fetch_url to read https://example.com/watch-status on every check. Reply with the current status identifier from the fetched page. A previous finding may be stale."
        let authorization = try XCTUnwrap(watches.webAuthorization(pages: address, queries: ""))
        let watch = try await store.start(task: task, everyMinutes: 1, at: clock.now.addingTimeInterval(-61), webAuthorization: authorization)
        for index in 0..<2 {
            if index == 1 { clock.now = clock.now.addingTimeInterval(61); if !live { await connector.changeIdentifier() } }
            let before = await connector.observations().count, traceStart = observed.snapshot().count
            let conditionsBefore = nativeDeviceConditions()
            let ran = await watches.runBackground(UUID()); let savedValue = await store.watch(watch.id); let saved = try XCTUnwrap(savedValue)
            let conditionsAfter = nativeDeviceConditions()
            let requests = Array((await connector.observations()).dropFirst(before)), trace = Array(observed.snapshot().dropFirst(traceStart))
            let expected = live ? "example.com" : index == 0 ? "Saffron" : "Cobalt"
            let finding = saved.lastSummary ?? ""
            checks.append(["index": index, "expected": expected, "finding": finding, "ran": ran, "runs": saved.runs, "outcome": saved.history.last?.outcome.rawValue ?? "", "runSummary": saved.history.last?.summary ?? "", "conditionsBefore": conditionsBefore, "conditionsAfter": conditionsAfter, "changed": saved.history.last?.changed ?? false, "exchanges": requests.map(\.json), "trace": trace])
            XCTAssertTrue(ran); XCTAssertEqual(saved.runs, index + 1); XCTAssertEqual(saved.history.last?.outcome, .checked); XCTAssertNil(saved.claim)
            XCTAssertFalse(requests.isEmpty, "The real model did not fetch a fresh source on this check.")
            XCTAssertTrue(requests.allSatisfy { $0.address == address && $0.status == 200 && $0.bytes > 0 })
            XCTAssertTrue(finding.localizedCaseInsensitiveContains(expected), finding)
            XCTAssertEqual(saved.history.last?.changed, index == 0 || !live)
            XCTAssertEqual(chat.current, conversation); XCTAssertNil(chat.pendingToolApproval); XCTAssertNil(chat.checkingWatchID); XCTAssertFalse(chat.busy); XCTAssertEqual(chat.contextUsed, 0)
            guard ran, saved.runs == index + 1, saved.history.last?.outcome == .checked, !requests.isEmpty, finding.localizedCaseInsensitiveContains(expected), saved.history.last?.changed == (index == 0 || !live), chat.current == conversation else { return }
            let reopened = try WatchStore(file: watchFile); let durable = await reopened.watch(watch.id)
            XCTAssertEqual(durable, saved); XCTAssertEqual(durable?.webAuthorization, authorization)
            if index == 0 { actions.append("first-real-model-fetch-finding-and-durable-authorized-watch") }
            else { actions.append(live ? "second-real-model-live-fetch-after-prior-finding-with-unchanged-verdict" : "second-real-model-fresh-controlled-page-replaces-old-finding-and-reports-change") }
            _ = await watches.runBackground(UUID()); let once = await store.watch(watch.id); XCTAssertEqual(once?.runs, index + 1)
        }
        await watches.pause(watch.id)
        let reopened = try WatchStore(file: watchFile); let paused = await reopened.watch(watch.id); XCTAssertEqual(paused?.state, .paused)
        chat.draft = "Reply briefly with Cedar again."; await chat.send(); try await waitUntil(seconds: 120) { !chat.busy }
        XCTAssertNil(chat.error); XCTAssertEqual(chat.current?.messages.last?.status, .complete)
        guard chat.error == nil, chat.current?.messages.last?.status == .complete else { return }
        actions.append("no-early-repeat-pause-reopen-and-ordinary-chat-recovery"); completed = true
    }

    func testWatchWebAuthorizationRoundTrip() async throws {
        var completed = false; var actions: [String] = []
        let suite = "openweights.watch-web-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        defer { attach(["purpose": "native-product-watch-web-authorization", "completed": completed, "actionsReached": actions,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations": ["Real IANA requests through canonical controllers with persisted exact-source authorization. Direct calls do not prove model tool choice.", "Programmatic native editor snapshots do not prove touch editing, keyboard or accessibility. No OS-granted background scheduling claim."]]) }
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true; defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let web = WebController(defaults: defaults); web.fetchEnabled = true; web.mediaEnabled = false; web.searchEnabled = false
        let file = root.appendingPathComponent("watches.json")
        let store = try WatchStore(file: file)
        let watches = WatchController(store: store, defaults: defaults)
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")), sessionIdentifier: suite)
        let chat = ChatController(store: try ConversationStore(file: root.appendingPathComponent("conversations.json")), downloads: downloads, watches: watches, web: web, defaults: defaults)
        watches.bind(chat)
        let authorization = try XCTUnwrap(watches.webAuthorization(pages: "www.iana.org/domains/reserved", queries: ""))
        let created = await watches.create(task: "Check the IANA reserved domain page", everyMinutes: 15, webAuthorization: authorization); XCTAssertTrue(created)
        let savedWatches = await store.list(); let watch = try XCTUnwrap(savedWatches.first)
        let reopened = try WatchStore(file: file); let restoredValue = await reopened.watch(watch.id); let restored = try XCTUnwrap(restoredValue)
        XCTAssertEqual(restored.webAuthorization, authorization); actions.append("editor-source-builder-and-approved-watch-persistence-reopen")
        let call = AgentToolCall(id: "repeat-iana", name: "fetch_url", argumentsJSON: "{\"url\":\"https://www.iana.org/domains/reserved\",\"find\":\"example.com\"}")
        for _ in 0..<2 {
            await web.beginTurn(carriesUntrustedText: true, carriesPrivateData: true)
            let found = await web.execute(call, mode: .auto, approval: nil, workspace: nil, unattended: true, watchAuthorization: restored.webAuthorization)
            XCTAssertFalse(found.rejected, found.text); XCTAssertTrue(found.text.contains("example.com")); guard !found.rejected else { return }
        }
        actions.append("approved-exact-iana-source-repeated-after-prior-private-untrusted-findings")
        let other = AgentToolCall(id: "other", name: "fetch_url", argumentsJSON: "{\"url\":\"https://www.iana.org/domains/reserved?private=secret\"}")
        let denied = await web.execute(other, mode: .auto, approval: nil, workspace: nil, unattended: true, watchAuthorization: authorization)
        XCTAssertTrue(denied.rejected); XCTAssertTrue(denied.text.contains("not approved"))
        let save = AgentToolCall(id: "save", name: "fetch_url", argumentsJSON: "{\"url\":\"https://www.iana.org/domains/reserved\",\"save_to\":\"page.txt\"}")
        let noSave = await web.execute(save, mode: .auto, approval: nil, workspace: nil, unattended: true, watchAuthorization: authorization); XCTAssertTrue(noSave.rejected)
        web.fetchEnabled = false
        let disabled = await web.execute(call, mode: .auto, approval: nil, workspace: nil, unattended: true, watchAuthorization: authorization); XCTAssertTrue(disabled.rejected)
        actions.append("unapproved-query-string-unattended-save-and-disabled-switch-still-refused")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for scheme in [ColorScheme.light, .dark] {
            let host = UIHostingController(rootView: NavigationStack { WatchEditor(watches: watches, existing: restored) }.environment(\.colorScheme, scheme))
            let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 390, height: 844); window.rootViewController = host; window.isHidden = false
            host.view.frame = window.bounds; host.view.layoutIfNeeded(); try await Task.sleep(nanoseconds: 300_000_000)
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "native-watch-web-editor-" + (scheme == .light ? "light" : "dark"); attachment.lifetime = .keepAlways; add(attachment); window.isHidden = true
        }
        actions.append("native-watch-editor-light-dark-snapshots-retained")
        let edited = await watches.edit(watch.id, task: "Deliver a local reminder", everyMinutes: 15); XCTAssertTrue(edited)
        let revokedValue = await store.watch(watch.id); let revoked = try XCTUnwrap(revokedValue); XCTAssertNil(revoked.webAuthorization)
        web.fetchEnabled = true; await web.beginTurn(carriesUntrustedText: true, carriesPrivateData: true)
        let noGrant = await web.execute(call, mode: .auto, approval: nil, workspace: nil, unattended: true, watchAuthorization: revoked.webAuthorization); XCTAssertTrue(noGrant.rejected)
        actions.append("edited-watch-revokes-durable-source-permission-and-prior-findings-no-longer-authorize-egress")
        completed = true
    }

    func testFetchCompatibilityRoundTrip() async throws {
        var completed = false; var actions: [String] = []; var decoderCases: [[String: Any]] = []
        let suite = "openweights.fetch-compatibility-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        defer { attach(["purpose": "native-product-fetch-compatibility", "completed": completed, "actionsReached": actions, "decoderCases": decoderCases,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations": ["Real IANA HTTPS requests through canonical WebController and controlled exact approvals. Shared-folder persistence uses an app-owned temporary folder, not an external Files provider.", "Captured JDK Charset probes have nine agreements and one declared unpaired UTF-32 surrogate difference. They do not prove every codec or malformed sequence.", "Direct controller calls do not establish model tool emission, native touch navigation or OS file-provider grants. Separate agent tests retain real GGUF acceptance checks."]]) }
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true; defer { UIApplication.shared.isIdleTimerDisabled = idle }
        decoderCases = try await verifyFetchDecoderFixtures().map(\.json); XCTAssertEqual(decoderCases.count, 10); XCTAssertEqual(decoderCases.filter { $0["matchesJava"] as? Bool == true }.count, 9)
        actions.append("native-decoder-replays-captured-jdk-fixtures-with-declared-surrogate-difference")
        let web = WebController(defaults: defaults); web.fetchEnabled = true; web.mediaEnabled = false; web.searchEnabled = false
        await web.beginTurn(carriesUntrustedText: false)
        let call = AgentToolCall(id: "compat-find", name: "fetch_url", argumentsJSON: "{\"link\":\"<www.iana.org/domains/reserved.>\",\"pattern\":\"example\"}")
        let denied = await web.execute(call, mode: .ask, approval: nil, workspace: nil); XCTAssertTrue(denied.rejected)
        let canonical = AgentToolCall(id: call.id, name: call.name, argumentsJSON: "{\"url\":\"https://www.iana.org/domains/reserved\",\"find\":\"example\"}")
        let wrong = await web.execute(call, mode: .ask, approval: ApprovedToolCall(displayedCall: canonical), workspace: nil); XCTAssertTrue(wrong.rejected)
        let ticket = ApprovedToolCall(displayedCall: call)
        let found = await web.execute(call, mode: .ask, approval: ticket, workspace: nil)
        XCTAssertFalse(found.rejected); XCTAssertTrue(found.untrustedText); XCTAssertTrue(found.text.contains("Requested: https://www.iana.org/domains/reserved")); XCTAssertTrue(found.text.lowercased().contains("matching \"example\""))
        guard !found.rejected else { return }; actions.append("exact-raw-alias-approval-normalizes-and-finds-live-iana-text")
        let replay = await web.execute(call, mode: .ask, approval: ticket, workspace: nil); XCTAssertTrue(replay.rejected)
        actions.append("approval-for-canonicalized-call-cannot-approve-alias-and-consumed-ticket-cannot-replay")
        let workspace = try Workspace(root: root)
        let save = AgentToolCall(id: "compat-save", name: "fetch_url", argumentsJSON: "{\"input\":\"www.iana.org/domains/reserved\",\"saveTo\":\"iana.txt\"}")
        let saved = await web.execute(save, mode: .ask, approval: ApprovedToolCall(displayedCall: save), workspace: workspace)
        XCTAssertFalse(saved.rejected); let bytes = try Data(contentsOf: root.appendingPathComponent("iana.txt")); XCTAssertFalse(bytes.isEmpty); XCTAssertLessThanOrEqual(bytes.count, WebPageText.maximumBytes)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("IANA")); actions.append("approved-input-saveTo-alias-saves-complete-readable-iana-page")
        let wall = AgentToolCall(id: "compat-wall", name: "fetch_url", argumentsJSON: "{\"address\":\"ph.linkedin.com/in/cedar\"}")
        let refused = await web.execute(wall, mode: .ask, approval: ApprovedToolCall(displayedCall: wall), workspace: nil)
        XCTAssertTrue(refused.rejected); XCTAssertTrue(refused.text.contains("requires signing in")); actions.append("known-sign-in-wall-produces-explicit-unavailable-result")
        completed = true
    }

    func testSearchProxyRoundTrip() async throws {
        var completed = false; var actions: [String] = []
        let suite = "openweights.proxy-device-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let vault = AppleSearchProxyCredentialStore(service: "org.experimentalmachines.openweights.proxy-test." + UUID().uuidString)
        defer { try? vault.save(nil, for: nil) }
        defer { attach(["purpose": "native-product-scoped-search-proxy", "completed": completed, "actionsReached": actions,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations": ["Owned loopback CONNECT and SOCKS5 fixtures with synthetic credentials. Origin TLS uses the same public badssl IP for valid and mismatched host controls.", "HTTPS proxy mismatch is refused. A successful trusted HTTPS proxy and remote proxy services remain untested.", "Programmatic light/dark settings snapshots do not verify touch editing, keyboard behavior, scrolling or VoiceOver. No model-inference performance claim."]]) }
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let result = try await verifyProxyTransport(); XCTAssertEqual(result.checks.count, 13); actions += result.checks
        let credentials = try SearchProxyCredentials(username: "fixture", password: "fixture-password")
        let endpoint = try SearchProxyEndpoint("http://proxy.example:8080")
        let web = WebController(defaults: defaults, proxyCredentials: vault)
        try web.saveProxy(address: endpoint.description, credentials: credentials)
        XCTAssertEqual(try vault.read(for: endpoint), credentials)
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains(credentials.password))
        let reopened = WebController(defaults: defaults, proxyCredentials: vault)
        XCTAssertEqual(reopened.proxyAddress, endpoint.description); XCTAssertTrue(reopened.proxyHasCredentials)
        do { _ = try vault.read(for: SearchProxyEndpoint("http://other.example:8080")); XCTFail("Credential was readable for another proxy."); return }
        catch is PublicWebError { actions.append("real-keychain-credential-bound-to-one-proxy-address") }
        try reopened.saveProxy(address: endpoint.description, keepSavedCredentials: true)
        actions.append("real-keychain-save-read-and-controller-settings-reopen-without-plaintext-preferences")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for scheme in [ColorScheme.light, .dark] {
            let host = UIHostingController(rootView: Form { SearchProxyControls(web: reopened) }.environment(\.colorScheme, scheme))
            let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 390, height: 844); window.rootViewController = host; window.isHidden = false
            host.view.frame = window.bounds; host.view.layoutIfNeeded(); try await Task.sleep(nanoseconds: 300_000_000)
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "native-search-proxy-settings-" + (scheme == .light ? "light" : "dark"); attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
        actions.append("light-dark-proxy-controls-snapshots-retained-with-empty-credential-fields")
        try reopened.saveProxy(address: ""); XCTAssertNil(try vault.read(for: endpoint)); XCTAssertTrue(reopened.proxyAddress.isEmpty); XCTAssertFalse(reopened.proxyHasCredentials)
        actions.append("explicit-proxy-removal-deletes-real-keychain-credential")
        completed = true
    }

    func testNativeMediaAgentRoundTrip() async throws {
        var completed = false; var actions: [String] = []; var displayed: [String] = []; var providerObservations: [[String: Any]] = []; var cachedPreviews = 0
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("product-media-agent-" + UUID().uuidString)
        let suite = "openweights.media-agent-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let cache = MediaPreviewCache(root: root.appendingPathComponent("Media")); let web = WebController(defaults: defaults, mediaCache: cache)
        let files = WorkspaceController(bookmarkFile: root.appendingPathComponent("workspace.bookmark"), defaults: defaults); files.mode = .ask
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")), sessionIdentifier: "org.experimentalmachines.openweights.media-agent-tests." + UUID().uuidString)
        let chat = ChatController(store: try ConversationStore(file: root.appendingPathComponent("conversations.json")), downloads: downloads, files: files, web: web, defaults: defaults)
        defer {
            chat.cancel()
            attach(["purpose": "native-product-media-agent", "completed": completed, "actionsReached": actions, "displayedApprovalArguments": displayed,
                    "providerObservations": providerObservations, "cachedPreviews": cachedPreviews, "controllerError": chat.error ?? "", "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                    "limitations": ["Real pinned GGUF, DuckDuckGo provider and public thumbnail requests. Exact approval is driven through the controller.",
                                    "Live image and clip availability are recorded separately. Programmatic SwiftUI snapshots do not prove touch navigation, browser handoff or VoiceOver.",
                                    "Pictures remain unavailable if the live image endpoint refuses its request. No camera/photo-library or multimodal input claim."]])
        }
        XCTAssertTrue(web.mediaEnabled); XCTAssertTrue(web.definitions.contains { $0.name == "show_pictures" })
        web.mediaEnabled = false; XCTAssertFalse(WebController(defaults: defaults).mediaEnabled)
        web.mediaEnabled = true; web.searchEnabled = false
        XCTAssertTrue(web.definitions.contains { $0.name == "show_pictures" }); actions.append("pictures-default-on-and-independent-named-switch-persists")
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true; defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let provider = DuckDuckGoMediaProvider()
        for kind in [MediaResultKind.images, .videos] {
            let hits = try await provider.search(query: "red panda", kind: kind)
            providerObservations.append(["kind": kind.rawValue, "answered": hits != nil, "hits": (hits ?? []).map { ["title": $0.title, "thumbnail": $0.thumbnailURL, "source": $0.sourceURL] }])
            if let hits { XCTAssertLessThanOrEqual(hits.count, 8) }
        }
        actions.append("actual-image-and-clip-provider-availability-recorded-separately")
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let source = cachedDirectory(artifact: "gguf", revision: try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source, file: try XCTUnwrap(pinned.files.first)); await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first); model.settings.temperature = 0; model.settings.repeatPenalty = 1; model.settings.outputTokens = 192; model.settings.thinking = false
        try await downloads.save(model); await chat.load(model); XCTAssertNil(chat.error); XCTAssertTrue(chat.supportsTools)
        guard chat.error == nil, chat.supportsTools else { return }
        chat.draft = "Use show_pictures with query exactly red panda and kind exactly videos. Show the clip thumbnails, then briefly say that they are ready. Use no other tools."
        await chat.send(); try await waitUntil(seconds: 120) { chat.pendingToolApproval != nil || !chat.busy }
        let request = try XCTUnwrap(chat.pendingToolApproval, chat.error ?? "No picture-query approval appeared.")
        let arguments = try JSONSerialization.jsonObject(with: Data(request.displayedCall.argumentsJSON.utf8)) as? [String: String]
        XCTAssertEqual(request.displayedCall.name, "show_pictures"); XCTAssertEqual(arguments?["query"], "red panda"); XCTAssertEqual(arguments?["kind"], "videos")
        XCTAssertFalse(chat.current?.messages.contains { $0.mediaEvidence != nil } == true); XCTAssertTrue(chat.pendingToolApprovalContext?.contains("thumbnails") == true)
        guard request.displayedCall.name == "show_pictures", arguments?["query"] == "red panda", arguments?["kind"] == "videos" else { return }
        displayed.append(request.displayedCall.argumentsJSON); actions.append("real-model-requested-exact-query-and-kind-before-query-and-preview-approval")
        chat.answerToolApproval(approved: true, ticketID: request.ticketID); try await waitUntil(seconds: 180) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertFalse(chat.busy); XCTAssertNil(chat.error); guard !chat.busy, chat.error == nil else { return }
        let result = try XCTUnwrap(chat.current?.messages.first { $0.toolName == "show_pictures" }); let evidence = try XCTUnwrap(result.mediaEvidence, result.content)
        XCTAssertEqual(result.status, .complete); XCTAssertEqual(result.toolUntrustedText, true); XCTAssertEqual(evidence.kind, .videos); XCTAssertEqual(evidence.query, "red panda")
        XCTAssertFalse(evidence.hits.isEmpty); XCTAssertLessThanOrEqual(evidence.hits.count, 8)
        for hit in evidence.hits {
            if let key = hit.previewKey, let bytes = await cache.cached(key) {
                cachedPreviews += 1; XCTAssertLessThanOrEqual(bytes.count, MediaPreviewCache.maximumPreview)
                let image = try XCTUnwrap(UIImage(data: bytes)); XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), CGFloat(MediaPreviewCache.maximumPixels))
            }
        }
        XCTAssertGreaterThan(cachedPreviews, 0); guard cachedPreviews > 0, result.status == .complete else { return }
        let answer = try XCTUnwrap(chat.current?.messages.last); XCTAssertEqual(answer.role, .assistant); XCTAssertEqual(answer.status, .complete); XCTAssertFalse(answer.content.isEmpty)
        actions.append("approved-live-clip-results-cached-bounded-jpeg-previews-and-model-answer-completed")
        let store = try ConversationStore(file: root.appendingPathComponent("conversations.json")); let conversation = try await store.conversation(try XCTUnwrap(chat.current?.id))
        XCTAssertEqual(conversation.messages.first { $0.toolName == "show_pictures" }?.mediaEvidence, evidence)
        web.mediaEnabled = false
        for hit in evidence.hits { if let key = hit.previewKey { let cached = await cache.cached(key); XCTAssertNotNil(cached) } }
        actions.append("durable-media-sources-reopened-and-local-cache-remains-readable-with-tool-off")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for scheme in [ColorScheme.light, .dark] {
            let host = UIHostingController(rootView: MessageRow(message: result, mediaCache: cache).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(OWTheme.canvas).environment(\.colorScheme, scheme))
            let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 390, height: 340); window.rootViewController = host; window.isHidden = false
            host.view.frame = window.bounds; host.view.layoutIfNeeded(); try await Task.sleep(nanoseconds: 300_000_000)
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "native-media-carousel-" + (scheme == .light ? "light" : "dark"); attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
        actions.append("light-and-dark-swiftui-carousel-snapshots-retained-with-no-new-media-requests")
        completed = true
    }

    func testNativeWebSearchRoundTrip() async throws {
        var completed = false; var actions: [String] = []; var displayed: [String] = []
        var providerObservations: [[String: Any]] = []
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("product-web-search-" + UUID().uuidString)
        let suite = "openweights.web-search-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let web = WebController(defaults: defaults)
        let files = WorkspaceController(bookmarkFile: root.appendingPathComponent("workspace.bookmark"), defaults: defaults)
        files.mode = .ask
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")), sessionIdentifier: "org.experimentalmachines.openweights.web-search-tests." + UUID().uuidString)
        let chat = ChatController(store: try ConversationStore(file: root.appendingPathComponent("conversations.json")), downloads: downloads, files: files, web: web, defaults: defaults)
        defer {
            chat.cancel()
            attach(["purpose": "native-product-web-search", "completed": completed, "actionsReached": actions,
                    "displayedApprovalArguments": displayed, "providerObservations": providerObservations,
                    "controllerError": chat.error ?? "", "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                    "limitations": ["Real pinned GGUF, live search providers and product controllers. Approval uses the controller, not touch navigation.",
                                    "Provider availability is recorded separately from parsing captured fixtures. No energy, UI accessibility or background-delivery claim."]])
        }
        XCTAssertTrue(web.searchEnabled); XCTAssertFalse(web.fetchEnabled); XCTAssertFalse(web.documentation)
        XCTAssertEqual(web.searchEngines, [.duckduckgo, .brave, .yahoo]); XCTAssertEqual(web.resultCount, 3)
        web.mediaEnabled = false
        actions.append("android-search-defaults-and-fetch-default-off")
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let providers = WebSearchProviders()
        for engine in [SearchEngine.duckduckgo, .brave, .yahoo, .context7] {
            let query = engine == .context7 ? "react hooks" : "iana reserved example domains"
            let hits = try await providers.search(engine, query: query)
            providerObservations.append(["engine": engine.rawValue, "query": query, "answered": hits != nil,
                                         "hits": (hits ?? []).map { ["title": $0.title, "url": $0.url, "snippetCharacters": $0.snippet.count] }])
            if let hits {
                XCTAssertLessThanOrEqual(hits.count, 3)
                XCTAssertTrue(hits.allSatisfy { !$0.title.isEmpty && URL(string: $0.url)?.host != nil })
            }
        }
        actions.append("live-provider-answers-and-unavailability-recorded-without-inventing-no-results")
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let source = cachedDirectory(artifact: "gguf", revision: try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source, file: try XCTUnwrap(pinned.files.first))
        await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first)
        model.settings.temperature = 0; model.settings.repeatPenalty = 1; model.settings.outputTokens = 192; model.settings.thinking = false
        try await downloads.save(model); await chat.load(model)
        XCTAssertNil(chat.error); XCTAssertTrue(chat.supportsTools)
        guard chat.error == nil, chat.supportsTools else { return }
        chat.draft = "Use web_search with query exactly iana reserved example domains. From the search snippets name the organization that reserves example.com. Use no other tools."
        await chat.send()
        try await waitUntil(seconds: 120) { chat.pendingToolApproval != nil || !chat.busy }
        let search = try XCTUnwrap(chat.pendingToolApproval, chat.error ?? "No search approval appeared.")
        let arguments = try JSONSerialization.jsonObject(with: Data(search.displayedCall.argumentsJSON.utf8)) as? [String: String]
        XCTAssertEqual(search.displayedCall.name, "web_search"); XCTAssertEqual(arguments?["query"], "iana reserved example domains")
        XCTAssertFalse(chat.current?.messages.contains { $0.toolName == "web_search" } == true)
        guard search.displayedCall.name == "web_search", arguments?["query"] == "iana reserved example domains" else { return }
        displayed.append(search.displayedCall.argumentsJSON)
        actions.append("real-model-requested-exact-query-before-search-effect")
        chat.answerToolApproval(approved: true, ticketID: search.ticketID)
        try await waitUntil(seconds: 180) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertFalse(chat.busy); XCTAssertNil(chat.error)
        guard !chat.busy, chat.error == nil else { return }
        let result = try XCTUnwrap(chat.current?.messages.first { $0.toolName == "web_search" })
        let evidence = try XCTUnwrap(result.searchEvidence, result.content)
        XCTAssertEqual(result.status, .complete); XCTAssertEqual(result.toolUntrustedText, true)
        XCTAssertEqual(evidence.query, "iana reserved example domains"); XCTAssertFalse(evidence.hits.isEmpty)
        let answer = chat.current?.messages.last?.content.lowercased() ?? ""
        XCTAssertTrue(answer.contains("iana") || answer.contains("internet assigned numbers authority"), answer)
        guard result.status == .complete, !evidence.hits.isEmpty,
              answer.contains("iana") || answer.contains("internet assigned numbers authority") else { return }
        actions.append("approved-live-search-fed-real-model-answer-and-retained-untrusted-sources")
        let reopened = try ConversationStore(file: root.appendingPathComponent("conversations.json"))
        let conversation = try await reopened.conversation(try XCTUnwrap(chat.current?.id))
        XCTAssertEqual(conversation.messages.first { $0.toolName == "web_search" }?.searchEvidence, evidence)
        actions.append("typed-search-query-provider-and-links-survived-conversation-reopen")
        completed = true
    }

    func testNativeWebAgentRoundTrip() async throws {
        var completed = false; var actions: [String] = []; var displayed: [String] = []; var readableBytes = 0
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("product-web-agent-" + UUID().uuidString)
        let suite = "openweights.web-agent-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let web = WebController(defaults: defaults)
        web.searchEnabled = false; web.mediaEnabled = false
        let files = WorkspaceController(bookmarkFile: root.appendingPathComponent("workspace.bookmark"), defaults: defaults)
        let shared = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        await files.choose(shared); XCTAssertNil(files.error); files.mode = .ask
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")), sessionIdentifier: "org.experimentalmachines.openweights.web-agent-tests." + UUID().uuidString)
        let chat = ChatController(store: try ConversationStore(file: root.appendingPathComponent("conversations.json")), downloads: downloads, files: files, web: web, defaults: defaults)
        defer {
            chat.cancel()
            attach(["purpose": "native-product-web-agent", "completed": completed, "actionsReached": actions,
                    "displayedApprovalArguments": displayed, "savedReadableBytes": readableBytes,
                    "controllerError": chat.error ?? "", "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                    "limitations": ["Real pinned GGUF, public IANA requests and product controllers. Approval is driven through the controller, not touch navigation.",
                                    "Search providers, images, arbitrary page compatibility, external file providers and OS background delivery are not verified."]])
        }
        XCTAssertFalse(web.fetchEnabled); XCTAssertTrue(web.definitions.isEmpty)
        web.fetchEnabled = true
        XCTAssertTrue(WebController(defaults: defaults).fetchEnabled)
        actions.append("fetch-default-off-and-named-switch-persists")
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let source = cachedDirectory(artifact: "gguf", revision: try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source, file: try XCTUnwrap(pinned.files.first))
        await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first)
        model.settings.temperature = 0; model.settings.repeatPenalty = 1; model.settings.outputTokens = 192; model.settings.thinking = false
        try await downloads.save(model); await chat.load(model)
        XCTAssertNil(chat.error); XCTAssertTrue(chat.supportsTools)
        guard chat.error == nil, chat.supportsTools else { return }
        chat.draft = "Use fetch_url to read https://www.iana.org/domains/reserved with find set to example.com. From the fetched text name one reserved example domain. Use no other tools."
        await chat.send()
        try await waitUntil(seconds: 120) { chat.pendingToolApproval != nil || !chat.busy }
        let fetch = try XCTUnwrap(chat.pendingToolApproval, chat.error ?? "No fetch approval appeared.")
        XCTAssertEqual(fetch.displayedCall.name, "fetch_url")
        let fetchArgs = try JSONSerialization.jsonObject(with: Data(fetch.displayedCall.argumentsJSON.utf8)) as? [String: String]
        XCTAssertEqual(fetchArgs?["url"], "https://www.iana.org/domains/reserved")
        XCTAssertEqual(fetchArgs?["find"], "example.com")
        guard fetch.displayedCall.name == "fetch_url", fetchArgs?["url"] == "https://www.iana.org/domains/reserved", fetchArgs?["find"] == "example.com" else { return }
        displayed.append(fetch.displayedCall.argumentsJSON); actions.append("real-model-requested-exact-public-url-and-find-before-approval")
        chat.answerToolApproval(approved: true, ticketID: fetch.ticketID)
        try await waitUntil(seconds: 120) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertFalse(chat.busy); XCTAssertNil(chat.error)
        guard !chat.busy, chat.error == nil else { return }
        let read = try XCTUnwrap(chat.current?.messages.first { $0.toolName == "fetch_url" })
        XCTAssertEqual(read.status, .complete); XCTAssertEqual(read.toolUntrustedText, true)
        XCTAssertTrue(read.content.contains("Read: https://www.iana.org/domains/reserved")); XCTAssertTrue(read.content.contains("example.com"))
        XCTAssertTrue(chat.current?.messages.last?.content.contains("example.com") == true)
        guard read.status == .complete, read.content.contains("example.com"), chat.current?.messages.last?.content.contains("example.com") == true else { return }
        actions.append("approved-real-https-fetch-search-and-model-answer-with-untrusted-provenance")
        await chat.newConversation()
        chat.draft = "Use fetch_url with url https://www.iana.org/domains/reserved and save_to page.txt. Save the readable page into that file, then tell me it was saved."
        await chat.send()
        try await waitUntil(seconds: 120) { chat.pendingToolApproval != nil || !chat.busy }
        let save = try XCTUnwrap(chat.pendingToolApproval, chat.error ?? "No page-save approval appeared.")
        let saveArgs = try JSONSerialization.jsonObject(with: Data(save.displayedCall.argumentsJSON.utf8)) as? [String: String]
        XCTAssertEqual(save.displayedCall.name, "fetch_url"); XCTAssertEqual(saveArgs?["save_to"], "page.txt")
        XCTAssertEqual(saveArgs?["url"], "https://www.iana.org/domains/reserved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("page.txt").path))
        guard save.displayedCall.name == "fetch_url", saveArgs?["save_to"] == "page.txt", saveArgs?["url"] == "https://www.iana.org/domains/reserved" else { return }
        displayed.append(save.displayedCall.argumentsJSON); chat.answerToolApproval(approved: true, ticketID: save.ticketID)
        try await waitUntil(seconds: 120) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertFalse(chat.busy); XCTAssertNil(chat.error)
        guard !chat.busy, chat.error == nil else { return }
        let saved = try String(contentsOf: shared.appendingPathComponent("page.txt"), encoding: .utf8)
        readableBytes = saved.utf8.count
        XCTAssertTrue(saved.contains("example.com")); XCTAssertFalse(saved.contains("<script")); XCTAssertLessThanOrEqual(readableBytes, WebPageText.maximumBytes)
        let reopened = try ConversationStore(file: root.appendingPathComponent("conversations.json"))
        let conversation = try await reopened.conversation(try XCTUnwrap(chat.current?.id))
        XCTAssertTrue(conversation.messages.contains { $0.toolName == "fetch_url" && $0.status == .complete && $0.content.contains("Saved") })
        actions.append("approved-real-page-saved-as-readable-text-and-tool-result-reopened")
        completed = true
    }

    func testPublicWebTransportRoundTrip() async throws {
        var completed = false; var actions: [String] = []; var bytes = 0; var tlsError: Int32?
        defer {
            attach(["purpose": "native-product-public-web-transport", "completed": completed,
                    "actionsReached": actions, "publicPageBytes": bytes, "mismatchTLSError": tlsError.map { Int($0) } ?? 0,
                    "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                    "limitations": ["Tests the actual DNS/Network/TLS transport on public IANA and badssl endpoints without credentials or cookies.",
                                    "The negative certificate fixture must be refused with a TLS error, not one specific OS error code.",
                                    "Does not verify full web-tool integration, switches/approval, search providers, text extraction, media or touch navigation."]])
        }
        let priorIdle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = priorIdle }
        let document = try await PublicWebClient().fetch("https://www.iana.org/domains/reserved", maximumBody: 262_144, timeout: 60)
        XCTAssertEqual(document.response.status, 200)
        XCTAssertTrue(String(decoding: document.response.body, as: UTF8.self).contains("IANA"))
        guard document.response.status == 200, String(decoding: document.response.body, as: UTF8.self).contains("IANA") else { return }
        bytes = document.response.body.count; actions.append("real-public-https-read-with-system-trust")
        let resolver = SystemPublicWebResolver()
        let valid = try await resolver.resolve(host: "badssl.com", timeout: 15)
        let mismatch = try await resolver.resolve(host: "wrong.host.badssl.com", timeout: 15)
        let ip = try XCTUnwrap(valid.first { mismatch.contains($0) })
        XCTAssertTrue(PublicWebIP.isPublic(ip))
        let connector = ApplePublicWebConnector()
        let control = try await connector.exchange(address: PublicWebAddress("https://badssl.com/"), ip: ip, timeout: 20, maximumBody: 262_144)
        XCTAssertEqual(control.status, 200); guard control.status == 200 else { return }
        actions.append("valid-certificate-control-on-same-checked-public-ip")
        do {
            _ = try await connector.exchange(address: PublicWebAddress("https://wrong.host.badssl.com/"), ip: ip, timeout: 20, maximumBody: 65_536)
            XCTFail("The hostname-mismatch certificate fixture was accepted."); return
        } catch let error as NWError {
            guard case .tls(let code) = error else { throw error }
            tlsError = code; actions.append("invalid-hostname-certificate-refused-without-page-content")
        }
        do { _ = try await PublicWebClient().fetch("https://127.0.0.1/"); XCTFail("Private address admitted."); return }
        catch is PublicWebError { actions.append("private-literal-refused-before-network") }
        let ips = try await resolver.resolve(host: "www.iana.org", timeout: 15)
        let publicIP = try XCTUnwrap(ips.first)
        let task = Task { try await connector.exchange(address: PublicWebAddress("https://www.iana.org/domains/reserved"), ip: publicIP, timeout: 10, maximumBody: 262_144) }
        try await Task.sleep(nanoseconds: 10_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled operation returned content."); return }
        catch is CancellationError { actions.append("network-operation-cancelled-without-content") }
        completed = true
    }
    private func collectRuntime(_ runtime: any ChatRuntime, messages: [[String: String]], settings: ModelSettings) async throws -> RuntimeReply {
        var reply: RuntimeReply?
        for try await event in runtime.stream(messages: messages, settings: settings) {
            if case .reply(let value) = event { XCTAssertNil(reply); reply = value }
        }
        return try XCTUnwrap(reply)
    }
    func testNativeMLXWarmingMatchesFresh() async throws {
        var model = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .mlx })
        let directory = cachedDirectory(artifact: "mlx", revision: try XCTUnwrap(model.revision))
        for file in model.files { try ModelDownloads.verify(file.destination(in: directory), file: file) }
        model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1
        model.settings.thinking = false; model.settings.outputTokens = 32
        let history = [["role": "system", "content": "Remember the corrected project facts. " + String(repeating: "The following conversation concerns one short briefing. ", count: 100)],
                       ["role": "user", "content": "Cedar is in Porto with budget 620 and vegetarian food."],
                       ["role": "assistant", "content": "Saved Cedar, Porto, 620 and vegetarian."],
                       ["role": "user", "content": "Correction: Cedar is now in Osaka with budget 730. Keep vegetarian."],
                       ["role": "assistant", "content": "Saved Cedar, Osaka, 730 and vegetarian."]]
        let messages = history + [["role": "user", "content": "Return the current project, city, budget and diet in one short sentence."]]
        var runtime: ProductMLXRuntime? = ProductMLXRuntime()
        var completed = false
        var evidence: [String: Any] = ["purpose": "native-product-mlx-warming", "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                                      "limitations": ["Greedy synthetic recall on the pinned Qwen3 4-bit artifact. No latency, energy or general quality claim.",
                                                      "Does not verify other MLX families, warming cancellation, UI navigation or OS suspension."]]
        defer { runtime?.cancel(); evidence["completed"] = completed; attach(evidence) }
        let previousIdle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        try await runtime!.load(model: model, directory: directory)
        let count = try await runtime!.promptSize(messages: messages, settings: model.settings, tools: [])
        XCTAssertTrue(count.exact); XCTAssertLessThanOrEqual(count.tokens + model.settings.outputTokens, model.settings.contextTokens)
        let fresh = try await collectRuntime(runtime!, messages: messages, settings: model.settings)
        XCTAssertFalse(fresh.cancelled); XCTAssertEqual(fresh.cachedTokens, 0)
        await runtime!.reset(); try await runtime!.warm(messages: history, settings: model.settings)
        let warmed = try await collectRuntime(runtime!, messages: messages, settings: model.settings)
        XCTAssertFalse(warmed.cancelled); XCTAssertEqual(warmed.content, fresh.content)
        XCTAssertGreaterThan(warmed.cachedTokens, 512); XCTAssertLessThan(warmed.cachedTokens, count.tokens)
        evidence["fresh"] = fresh.content; evidence["warmed"] = warmed.content; evidence["cachedTokens"] = warmed.cachedTokens
        await runtime!.reset()
        let reset = try await collectRuntime(runtime!, messages: messages, settings: model.settings)
        XCTAssertEqual(reset.cachedTokens, 0); XCTAssertEqual(reset.content, fresh.content)
        runtime = nil
        runtime = ProductMLXRuntime(); try await runtime!.load(model: model, directory: directory)
        try await runtime!.warm(messages: history, settings: model.settings)
        let reopened = try await collectRuntime(runtime!, messages: messages, settings: model.settings)
        XCTAssertEqual(reopened.content, fresh.content); XCTAssertEqual(reopened.cachedTokens, warmed.cachedTokens)
        evidence["reopened"] = reopened.content
        completed = !fresh.content.isEmpty && fresh.content == warmed.content && fresh.content == reset.content && fresh.content == reopened.content && warmed.cachedTokens > 512 && reopened.cachedTokens == warmed.cachedTokens
    }
    func testNativeExecuTorchCountAndAdmission() async throws {
        var model = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .xnnpack })
        let directory = cachedDirectory(artifact: "executorch", revision: try XCTUnwrap(model.revision))
        for file in model.files { try ModelDownloads.verify(file.destination(in: directory), file: file) }
        model.settings.temperature = 0; model.settings.thinking = false; model.settings.outputTokens = 32
        let runtime = ProductExecuTorchRuntime()
        var evidence: [String: Any] = ["purpose": "native-product-executorch-count-admission", "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                                      "limitations": ["Pinned Qwen3 XNNPACK export only. Does not verify other families, summary quality, UI navigation or iPhone warming cancellation latency."]]
        var completed = false
        defer { runtime.cancel(); evidence["completed"] = completed; attach(evidence) }
        let previousIdle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        try await runtime.load(model: model, directory: directory)
        let counter = try OWExecuTorchTokenizer(path: directory.appendingPathComponent("tokenizer.json").path)
        for limit in [1919, 1920, 1921, 2047, 2048, 2049] {
            XCTAssertEqual(try counter.countPrompt(String(repeating: " a", count: limit)).intValue, limit)
        }
        let history = [["role": "system", "content": "Reply briefly. " + String(repeating: "The project needs one short written briefing. ", count: 60)],
                       ["role": "user", "content": "Project Cedar. City Porto. Budget 620. Vegetarian food."],
                       ["role": "assistant", "content": "Saved Cedar, Porto, 620 and vegetarian."]]
        let messages = history + [["role": "user", "content": "Return the project, city, budget and diet in one short sentence."]]
        let size = try await runtime.promptSize(messages: messages, settings: model.settings, tools: [])
        XCTAssertTrue(size.exact)
        XCTAssertEqual(size.tokens, try counter.countPrompt(qwenPrompt(messages, thinking: false)).intValue)
        let reply = try await collectRuntime(runtime, messages: messages, settings: model.settings)
        XCTAssertFalse(reply.cancelled); XCTAssertFalse(reply.content.isEmpty)
        XCTAssertEqual(reply.contextUsed, size.tokens + reply.generatedTokens)
        await runtime.reset(); try await runtime.warm(messages: history, settings: model.settings)
        let warmed = try await collectRuntime(runtime, messages: messages, settings: model.settings)
        XCTAssertEqual(warmed.content, reply.content); XCTAssertGreaterThan(warmed.cachedTokens, 128)
        XCTAssertEqual(warmed.promptContent, "<think>\n\n</think>\n\n" + warmed.content)
        var growing = messages + [["role": "assistant", "content": try XCTUnwrap(warmed.promptContent)]]
        var comparisonsMatch = true
        for query in ["Return Cedar only.", "Correction: the city is Osaka and budget 730. Return all four current facts.", "Return the current city and budget only."] {
            growing.append(["role": "user", "content": query])
            let retained = try await collectRuntime(runtime, messages: growing, settings: model.settings)
            XCTAssertGreaterThan(retained.cachedTokens, 0)
            await runtime.reset()
            let fresh = try await collectRuntime(runtime, messages: growing, settings: model.settings)
            XCTAssertEqual(fresh.cachedTokens, 0); XCTAssertEqual(retained.content, fresh.content)
            XCTAssertEqual(retained.contextUsed, fresh.contextUsed)
            comparisonsMatch = comparisonsMatch && retained.cachedTokens > 0 && fresh.cachedTokens == 0 && retained.content == fresh.content && retained.contextUsed == fresh.contextUsed
            growing.append(["role": "assistant", "content": try XCTUnwrap(fresh.promptContent)])
        }
        let tooLarge = [["role": "user", "content": String(repeating: " a", count: 2048)]]
        var events = 0; var refused = false
        do { for try await _ in runtime.stream(messages: tooLarge, settings: model.settings) { events += 1 } }
        catch { refused = true }
        XCTAssertTrue(refused); XCTAssertEqual(events, 0)
        let recovered = try await collectRuntime(runtime, messages: messages, settings: model.settings)
        XCTAssertEqual(recovered.content, reply.content)
        evidence["promptTokens"] = size.tokens; evidence["generatedTokens"] = reply.generatedTokens; evidence["reply"] = reply.content
        evidence["warmCachedTokens"] = warmed.cachedTokens; evidence["growingMessages"] = growing.count
        completed = size.exact && !reply.cancelled && !reply.content.isEmpty && warmed.content == reply.content && warmed.cachedTokens > 128 && comparisonsMatch && refused && events == 0 && recovered.content == reply.content
    }
    func testWatchStateRoundTrip() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("product-watch-" + UUID().uuidString).appendingPathComponent("watches.json")
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let now = Date()
        let store = try WatchStore(file: location, at: now)
        let watch = try await store.start(task: "Check the saved report", everyMinutes: 1, at: now)
        let pending = try await store.begin(watch.id, at: watch.nextDueAt); let ticket = try XCTUnwrap(pending)
        _ = try await store.pause(watch.id)
        let late = try await store.record(ticket, outcome: .checked, summary: "Stale answer", at: now.addingTimeInterval(70), changed: true)
        XCTAssertNil(late)
        _ = try await store.resume(watch.id, at: now.addingTimeInterval(80))
        let claimed = try await store.begin(watch.id, at: now.addingTimeInterval(140)); XCTAssertNotNil(claimed)
        let reopened = try WatchStore(file: location, at: now.addingTimeInterval(200))
        let saved = await reopened.watch(watch.id); let recovered = try XCTUnwrap(saved)
        XCTAssertNil(recovered.claim); XCTAssertEqual(recovered.runs, 0); XCTAssertEqual(recovered.history.last?.outcome, .skipped)
        let edited = try await reopened.edit(watch.id, task: "Check the updated report", everyMinutes: 10, at: now.addingTimeInterval(210))
        XCTAssertEqual(edited.nextDueAt, now.addingTimeInterval(810)); XCTAssertEqual(edited.expiresAt, watch.expiresAt)
        attach(["purpose": "native-product-watch-state-round-trip", "completed": late == nil && recovered.claim == nil && recovered.runs == 0 && recovered.history.last?.outcome == .skipped && edited.nextDueAt == now.addingTimeInterval(810),
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations": ["Deterministic native storage checks only. Does not verify notification permissions, background-task execution, model inference, UI navigation or OS suspension."]])
    }
    func testNativeWatchModelRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("product-watch-model-" + UUID().uuidString)
        let suite = "openweights.watch-model-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")),
            sessionIdentifier: "org.experimentalmachines.openweights.watch-model-tests." + UUID().uuidString)
        let store = try WatchStore(file: root.appendingPathComponent("watches.json"))
        let watches = WatchController(store: store, defaults: defaults)
        let usageFile = root.appendingPathComponent("usage.json"), usage = try UsageStore(file: usageFile)
        let chat = ChatController(store: try ConversationStore(file: root.appendingPathComponent("conversations.json")), downloads: downloads, watches: watches, defaults: defaults, usage: usage)
        watches.bind(chat)
        var completed = false; var actions: [String] = []; var finding = ""; var usageObservations: [[String:Any]] = []
        defer {
            chat.cancel(); watches.setForeground(false)
            attach(["purpose": "native-product-watch-model-round-trip", "completed": completed, "actionsReached": actions,
                "finding": finding, "usageAccounting":usageObservations, "error": chat.error ?? watches.error ?? "", "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations": ["Uses the real GGUF CPU adapter and controller background entry point while XCTest is in the foreground.",
                    "Does not prove OS-granted background time, notification permission/delivery, suspension, touch controls or other model families."]])
        }
        let previousIdle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let source = cachedDirectory(artifact: "gguf", revision: try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source, file: try XCTUnwrap(pinned.files.first))
        await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first)
        model.backend = .llamaCPU; model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1
        model.settings.outputTokens = 128; model.settings.thinking = false
        try await downloads.save(model); await chat.load(model)
        XCTAssertNil(chat.error); guard chat.error == nil else { return }
        actions.append("verified-gguf-import-and-cpu-load")
        chat.draft = "Reply with Cedar."; await chat.send(); try await waitUntil(seconds: 120) { !chat.busy }
        XCTAssertNil(chat.error); let conversation = try XCTUnwrap(chat.current)
        let beforeWatchUsage = await usage.list(); XCTAssertEqual(beforeWatchUsage.count,1)
        guard chat.error == nil else { return }
        let watch = try await store.start(task: "This is a due reminder. Tell me to review Cedar now in one short sentence.", everyMinutes: 1, at: Date().addingTimeInterval(-61))
        let ran = await watches.runBackground(UUID()); let savedValue = await store.watch(watch.id); let saved = try XCTUnwrap(savedValue)
        finding = saved.lastSummary ?? ""
        XCTAssertTrue(ran); XCTAssertEqual(saved.runs, 1); XCTAssertEqual(saved.history.last?.outcome, .checked)
        XCTAssertNotNil(saved.resultNotice); XCTAssertNil(saved.claim); XCTAssertFalse(finding.isEmpty)
        XCTAssertTrue(finding.localizedCaseInsensitiveContains("Cedar")); XCTAssertEqual(chat.current, conversation)
        XCTAssertNil(chat.checkingWatchID); XCTAssertFalse(chat.busy); XCTAssertEqual(chat.contextUsed, 0)
        guard ran, saved.runs == 1, saved.history.last?.outcome == .checked, saved.claim == nil,
              saved.resultNotice != nil, finding.localizedCaseInsensitiveContains("Cedar"), chat.current == conversation else { return }
        actions.append("real-cpu-check-and-durable-result-with-isolated-chat")
        let afterWatchUsage = await usage.list(); XCTAssertEqual(afterWatchUsage.count,2)
        XCTAssertEqual(afterWatchUsage.first,beforeWatchUsage.first); XCTAssertNil(chat.usageError)
        let watchPass = try XCTUnwrap(afterWatchUsage.last)
        XCTAssertEqual(watchPass.backend,.llamaCPU); XCTAssertGreaterThan(watchPass.measurements.generatedTokens,0)
        usageObservations.append(["stage":"chat-then-due-watch","passes":afterWatchUsage.count,
            "watchGeneratedTokens":watchPass.measurements.generatedTokens,"watchFreshPromptTokens":watchPass.measurements.promptTokens])
        _ = await watches.runBackground(UUID())
        let once = await store.watch(watch.id); XCTAssertEqual(once?.runs, 1)
        let earlyUsage = await usage.list(); XCTAssertEqual(earlyUsage,afterWatchUsage)
        await watches.pause(watch.id)
        let reopened = try WatchStore(file: root.appendingPathComponent("watches.json"))
        let paused = await reopened.watch(watch.id)
        XCTAssertEqual(paused?.state, .paused); XCTAssertEqual(paused?.lastSummary, finding); XCTAssertEqual(paused?.resultNotice?.id, saved.resultNotice?.id)
        guard once?.runs == 1, paused?.state == .paused, paused?.lastSummary == finding, paused?.resultNotice?.id == saved.resultNotice?.id else { return }
        actions.append("no-early-repeat-and-paused-reopen-keeps-finding-and-notice")
        chat.draft = "Reply briefly with Cedar again."; await chat.send(); try await waitUntil(seconds: 120) { !chat.busy }
        XCTAssertNil(chat.error); XCTAssertEqual(chat.current?.messages.last?.status, .complete)
        guard chat.error == nil, chat.current?.messages.last?.status == .complete else { return }
        let finalUsage = await usage.list(); XCTAssertEqual(finalUsage.count,3)
        let reopenedUsage = try UsageStore(file:usageFile), durableUsage = await reopenedUsage.list()
        XCTAssertEqual(durableUsage,finalUsage); XCTAssertNil(chat.usageError)
        usageObservations.append(["stage":"no-early-repeat-and-chat-recovery-reopened-ledger","passes":finalUsage.count,
            "generatedTokens":finalUsage.reduce(0) { $0 + $1.measurements.generatedTokens }])
        actions.append("ordinary-chat-recovers-after-watch-context-reset"); completed = true
    }
    func testNativeAgentPromptControls() async throws {
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        var model = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let directory = cachedDirectory(artifact: "gguf", revision: try XCTUnwrap(model.revision))
        try ModelDownloads.verify(directory.appendingPathComponent(model.entryFile), file: try XCTUnwrap(model.files.first))
        model.settings.temperature = 0; model.settings.repeatPenalty = 1
        model.settings.thinking = false; model.settings.outputTokens = 192
        let runtime = NativeObservedRuntime(LlamaRuntime(gpuLayers: 99))
        try await runtime.load(model: model, directory: directory)
        var cases: [[String: Any]] = []
        defer { attach(["purpose": "native-agent-prompt-controls", "cases": cases, "runtimeTrace": runtime.snapshot(),
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations": ["Isolated prompt controls with the same pinned GGUF, resetting before every request. Not product acceptance or a performance benchmark.",
                             "Summary control uses the first failing segment only. It does not prove complete folding or corrected-fact retention."]]) }
        func run(_ name: String, _ messages: [[String: String]], _ settings: ModelSettings, _ tools: [AgentToolDefinition]) async throws {
            await runtime.reset()
            let size = try await runtime.promptSize(messages: messages, settings: settings, tools: tools)
            XCTAssertLessThanOrEqual(size.tokens + settings.outputTokens, settings.contextTokens)
            guard size.tokens + settings.outputTokens <= settings.contextTokens else { return }
            var reply: RuntimeReply?
            for try await event in runtime.stream(messages: messages, settings: settings, tools: tools) {
                if case .reply(let value) = event { reply = value }
            }
            let final = try XCTUnwrap(reply); XCTAssertFalse(final.cancelled)
            cases.append(["name": name, "promptTokens": size.tokens, "promptCountExact": size.exact,
                          "endedNormally": final.stopReason == .endOfTurn,
                          "numberedPlan": TaskPlan.read(final.content) != nil,
                          "requestedQuestion": final.toolCalls.contains { $0.name == "ask_user" },
                          "summaryFacts": ["cedar", "porto", "620", "vegetarian"].allSatisfy(final.content.lowercased().contains)])
        }
        let segment = "user:\nProject Cedar. City Porto. Budget 620. Dietary constraint vegetarian. " + String(repeating: "The project needs a short written briefing. ", count: 144) + "The "
        let label = "Next transcript segment (later segments may follow):\n"
        let system = ["role": "system", "content": ChatController.systemPrompt]
        let summaryHead = [system, ["role": "user", "content": ConversationCompactor.instruction + "\n\n" + label + segment]]
        let summaryTail = [system, ["role": "user", "content": label + segment + "\n\n" + ConversationCompactor.instruction]]
        var summarySettings = model.settings; summarySettings.temperature = 0.2; summarySettings.topP = 1; summarySettings.outputTokens = 682
        try await run("summary-original-head", summaryHead, summarySettings, [])
        try await run("summary-instruction-tail", summaryTail, summarySettings, [])
        var penalized = summarySettings; penalized.repeatPenalty = 1.1
        try await run("summary-original-head-repeat-1.1", summaryHead, penalized, [])
        var greedy = summarySettings; greedy.temperature = 0
        try await run("summary-tail-greedy", summaryTail, greedy, [])
        let summarySystem = [["role": "system", "content": ConversationCompactor.instruction], ["role": "user", "content": label + segment]]
        try await run("summary-system-greedy", summarySystem, greedy, [])
        try await run("summary-system-sampled", summarySystem, summarySettings, [])
        let mode = "Tool mode: plan. Propose a short numbered plan of two to five steps. Ask ask_user only for missing preferences or information only the user can provide. Do not ask the user to do the assigned work or provide answers you can calculate. Do not request file or memory actions."
        let task = "Make exactly two short statements in order: first calculate 2 + 2, then calculate 3 + 3. Treat them as two separate steps. No files or outside information are needed."
        let planning = "Plan this out as a short numbered list of steps, five at most, each one a single action or answer you can deliver. Use the details already in the request. Ask a question only if a required detail is genuinely missing. Do not do any steps yet."
        let goal = [system, ["role": "user", "content": planning + "\n\n" + task + "\n\n" + mode]]
        let tools = PlanningToolDefinitions.enabled(plan: nil, mode: .plan)
        try await run("goal-original", goal, model.settings, tools)
        var goalTail = goal
        goalTail[1]["content"]! += "\n\nUse the information above to write the numbered steps now. Make reasonable assumptions for optional details. Only ask for information essential to completing the request that you cannot determine yourself."
        try await run("goal-positive-tail", goalTail, model.settings, tools)
        let request = "Use ask_user to ask which city I want, with options Osaka and Porto. Wait for my answer, then give a numbered two-step travel plan for that city."
        let rawCall = "<tool_call>\n{\"name\": \"ask_user\", \"arguments\": {\"question\": \"Which city would you like to travel to?\"}}\n</tool_call>"
        let response = "The user answered the question \"Which city would you like to travel to?\": Osaka\n\nUse this answer to continue the original request. Do not ask the same question again. Ask only if a different required detail is missing."
        let travel = [system, ["role": "user", "content": request + "\n\n" + mode], ["role": "assistant", "content": rawCall], ["role": "tool", "content": response, "tool_call_id": "ask_user-0"]]
        try await run("travel-original-followup", travel, model.settings, tools)
        var travelTail = travel
        travelTail[3]["content"]! += "\n\nUse the information above to write the numbered steps now. Make reasonable assumptions for optional details. Only ask for information essential to completing the request that you cannot determine yourself."
        try await run("travel-positive-tail", travelTail, model.settings, tools)
        XCTAssertEqual(cases.count, 10)
    }
    func testNativeConversationFolding() async throws {
        let pinned = try NativeAgentArtifact.selected()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("product-context-" + UUID().uuidString)
        let suite = "openweights.context-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"),
            library: try ModelLibrary(file: root.appendingPathComponent("models.json")),
            sessionIdentifier: "org.experimentalmachines.openweights.context-tests." + UUID().uuidString)
        let conversationFile = root.appendingPathComponent("conversations.json")
        let observed = NativeObservedRuntime(LlamaRuntime(gpuLayers: 99))
        let usageFile = root.appendingPathComponent("usage.json"), usage = try UsageStore(file:usageFile)
        let chat = ChatController(store: try ConversationStore(file: conversationFile), downloads: downloads, defaults: defaults, runtimeFactory: { _ in observed }, usage:usage)
        var completed = false
        var usageObservation: [String:Any] = [:]
        defer {
            chat.cancel()
            attach(["purpose": "native-product-conversation-folding", "completed": completed,
                    "summary": chat.current?.fold?.summary ?? "", "foldedMessageCount": chat.current?.fold?.messageCount ?? 0,
                    "contextUsed": chat.contextUsed, "contextCountExact": chat.contextIsExact,
                    "reply": chat.current?.messages.last?.content ?? "", "error": chat.error ?? "",
                    "runtimeTrace": observed.snapshot(), "artifact": NativeAgentArtifact.evidence(pinned),
                    "usageAccounting":usageObservation,
                    "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                    "limitations": ["Real GGUF summary and factual continuation with a synthetic growing history.",
                                    "Does not prove other model families, MLX/PTE folding quality, UI navigation or OS suspension."]])
        }
        let priorIdle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = priorIdle }
        let source = cachedDirectory(artifact: "gguf", revision: try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source, file: try XCTUnwrap(pinned.files.first))
        await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first)
        model.settings.temperature = 0; model.settings.repeatPenalty = 1; model.settings.thinking = false; model.settings.outputTokens = 192
        try await downloads.save(model); await chat.load(model); XCTAssertNil(chat.error)
        guard chat.error == nil else { return }
        await chat.newConversation()
        var conversation = try XCTUnwrap(chat.current)
        conversation.messages = [
            StoredMessage(role: .user, content: "Project Cedar. City Porto. Budget 620. Dietary constraint vegetarian. " + String(repeating: "The project needs a short written briefing. ", count: 180)),
            StoredMessage(role: .assistant, content: "Project Cedar is in Porto with budget 620 and vegetarian food."),
            StoredMessage(role: .user, content: "Correction: the city is now Osaka and the budget is now 730. Cedar and vegetarian remain unchanged. " + String(repeating: "Keep the latest correction in the briefing. ", count: 180)),
            StoredMessage(role: .assistant, content: "The updated facts are Cedar, Osaka, 730 and vegetarian.")]
        let original = conversation.messages
        try await chat.store.save(conversation); await chat.open(conversation)
        XCTAssertNil(chat.error)
        chat.draft = "Return only the current project, city, budget and dietary constraint in one sentence."
        await chat.send()
        try await waitUntil(seconds: 240) { !chat.busy }
        XCTAssertNil(chat.error)
        XCTAssertEqual(chat.current?.fold?.messageCount, 4)
        XCTAssertEqual(Array(try XCTUnwrap(chat.current).messages.prefix(4)), original)
        let reply = try XCTUnwrap(chat.current?.messages.last?.content).lowercased()
        for expected in ["cedar", "osaka", "730", "vegetarian"] { XCTAssertTrue(reply.contains(expected), "Missing \(expected): \(reply)") }
        let reopened = try ConversationStore(file: conversationFile)
        let saved = try await reopened.conversation(try XCTUnwrap(chat.current?.id))
        XCTAssertEqual(saved.fold, chat.current?.fold); XCTAssertEqual(saved.messages, chat.current?.messages)
        let streams = try XCTUnwrap(observed.snapshot()["streams"] as? [[String:Any]])
        let returnedMetrics = try streams.compactMap { $0["usage"] as? [String:Any] }.map {
            try JSONDecoder().decode(UsageMeasurements.self,from:JSONSerialization.data(withJSONObject:$0))
        }
        let rows = await usage.list(); XCTAssertEqual(rows.map(\.measurements),returnedMetrics)
        let summaries = streams.filter { stream in
            (stream["messages"] as? [[String:String]])?.last?["content"]?.contains(ConversationCompactor.instruction) == true
        }
        XCTAssertGreaterThan(summaries.count,0); XCTAssertEqual(rows.count,summaries.count+1); XCTAssertNil(chat.usageError)
        let reopenedUsage = try UsageStore(file:usageFile), durableUsage = await reopenedUsage.list()
        XCTAssertEqual(durableUsage,rows)
        usageObservation = ["passes":rows.count,"summaryPasses":summaries.count,"ordinaryReplyPasses":1,
            "generatedTokens":rows.reduce(0) { $0+$1.measurements.generatedTokens },
            "freshPromptTokens":rows.reduce(0) { $0+$1.measurements.promptTokens },"reopenedRowsMatch":durableUsage==rows]
        completed = chat.error == nil && saved.fold?.messageCount == 4 && ["cedar", "osaka", "730", "vegetarian"].allSatisfy(reply.contains)
    }
    func testNativeGoalRoundTrip() async throws {
        let pinned = try NativeAgentArtifact.selected()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("product-goal-" + UUID().uuidString)
        let suite = "openweights.goal-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let files = WorkspaceController(bookmarkFile: root.appendingPathComponent("workspace.bookmark"), defaults: defaults)
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"),
            library: try ModelLibrary(file: root.appendingPathComponent("models.json")),
            sessionIdentifier: "org.experimentalmachines.openweights.goal-tests." + UUID().uuidString)
        let goalFile = root.appendingPathComponent("goal.json")
        let observed = NativeObservedRuntime(LlamaRuntime(gpuLayers: 99))
        let chat = ChatController(store: try ConversationStore(file: root.appendingPathComponent("conversations.json")),
            downloads: downloads, files: files, goals: try GoalStore(file: goalFile), defaults: defaults, runtimeFactory: { _ in observed })
        var completed = false
        defer {
            let question = chat.pendingUserQuestion?.text ?? ""
            chat.cancel()
            attach(["purpose": "native-product-goal", "completed": completed, "goalState": chat.workGoal?.state.rawValue ?? "none",
                    "stepsTaken": chat.workGoal?.stepsTaken ?? 0, "goalNote": chat.workGoal?.note ?? "", "error": chat.error ?? "",
                    "pendingQuestionBeforeStop": question, "runtimeTrace": observed.snapshot(), "artifact": NativeAgentArtifact.evidence(pinned),
                    "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                    "limitations": ["Real GGUF controller execution with a short arithmetic task, not general autonomous task quality.",
                                    "Does not verify goal UI navigation, OS suspension or research evidence."]])
        }
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        let source = cachedDirectory(artifact: "gguf", revision: try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source, file: try XCTUnwrap(pinned.files.first))
        await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first)
        model.settings.temperature = 0; model.settings.repeatPenalty = 1
        model.settings.outputTokens = 192; model.settings.thinking = false
        try await downloads.save(model); await chat.load(model)
        XCTAssertNil(chat.error); XCTAssertTrue(chat.supportsTools)
        guard chat.error == nil, chat.supportsTools else { return }
        await chat.startGoal("Make exactly two short statements in order: first calculate 2 + 2, then calculate 3 + 3. Treat them as two separate steps. No files or outside information are needed.")
        try await waitUntil(seconds: 240) { !chat.goalActive || chat.pendingUserQuestion != nil || chat.pendingToolApproval != nil }
        XCTAssertFalse(chat.goalActive, "The native model requested unexpected input or did not finish its bounded task.")
        XCTAssertNil(chat.error)
        XCTAssertEqual(chat.workGoal?.state, .done)
        XCTAssertEqual(chat.workGoal?.stepsTaken, 2)
        guard !chat.goalActive, chat.error == nil, chat.workGoal?.state == .done, chat.workGoal?.stepsTaken == 2 else { return }
        let messages = try XCTUnwrap(chat.current?.messages)
        let stepStarts = messages.indices.filter { messages[$0].role == .user && messages[$0].content.hasPrefix("Carry out this one step of the plan") }
        XCTAssertEqual(stepStarts.count, 2)
        guard stepStarts.count == 2 else { return }
        for (offset, start) in stepStarts.enumerated() {
            let end = offset + 1 < stepStarts.count ? stepStarts[offset + 1] : messages.count
            let answer = messages[(start + 1)..<end].filter { $0.role == .assistant }.map(\.content).joined(separator: "\n")
            XCTAssertTrue(answer.contains(offset == 0 ? "4" : "6"), "The assigned arithmetic answer was missing from its execution turn.")
            guard answer.contains(offset == 0 ? "4" : "6") else { return }
        }
        let reopened = try GoalStore(file: goalFile)
        let snapshot = await reopened.snapshot()
        XCTAssertEqual(snapshot.goal?.state, .done)
        XCTAssertEqual(snapshot.goal?.conversationID, chat.current?.id)
        XCTAssertTrue(chat.current?.plan?.isFinished == true)
        guard snapshot.goal?.state == .done, snapshot.goal?.conversationID == chat.current?.id else { return }
        completed = true
    }
    func testNativePlanQuestionRoundTrip() async throws {
        let pinned = try NativeAgentArtifact.selected()
        var actions: [String] = []
        var completed = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("product-planning-" + UUID().uuidString)
        let suite = "openweights.planning-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let files = WorkspaceController(bookmarkFile: root.appendingPathComponent("workspace.bookmark"), defaults: defaults)
        files.mode = .plan
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"),
            library: try ModelLibrary(file: root.appendingPathComponent("models.json")),
            sessionIdentifier: "org.experimentalmachines.openweights.planning-tests." + UUID().uuidString)
        let file = root.appendingPathComponent("conversations.json")
        let observed = NativeObservedRuntime(LlamaRuntime(gpuLayers: 99))
        let chat = ChatController(store: try ConversationStore(file: file), downloads: downloads, files: files, defaults: defaults, runtimeFactory: { _ in observed })
        defer {
            let question = chat.pendingUserQuestion?.text ?? ""
            chat.cancel()
            attach(["purpose": "native-product-plan-question", "completed": completed, "actionsReached": actions,
                    "pendingQuestionBeforeStop": question, "runtimeTrace": observed.snapshot(), "artifact": NativeAgentArtifact.evidence(pinned),
                    "error": chat.error ?? "", "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                    "limitations": ["Uses real cached GGUF inference and controller responses, not touch navigation.",
                                    "Does not prove autonomous goal execution, question UI rendering or OS process termination recovery."]])
        }
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        let source = cachedDirectory(artifact: "gguf", revision: try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source, file: try XCTUnwrap(pinned.files.first))
        await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first)
        model.settings.temperature = 0; model.settings.repeatPenalty = 1
        model.settings.outputTokens = 192; model.settings.thinking = false
        try await downloads.save(model); await chat.load(model)
        XCTAssertNil(chat.error); XCTAssertTrue(chat.supportsTools)
        guard chat.error == nil, chat.supportsTools else { return }
        chat.draft = "Use ask_user to ask which city I want, with options Osaka and Porto. Wait for my answer, then give a numbered two-step travel plan for that city."
        await chat.send()
        try await waitUntil(seconds: 120) { chat.pendingUserQuestion != nil || !chat.busy }
        let question = try XCTUnwrap(chat.pendingUserQuestion, chat.error ?? "The real model did not request a question.")
        XCTAssertNil(chat.pendingToolApproval)
        let beforeAnswer = try ConversationStore(file: file)
        let pending = try await beforeAnswer.conversation(try XCTUnwrap(chat.current?.id))
        XCTAssertEqual(pending.messages.last?.userQuestion?.id, question.id)
        actions.append("real-model-asked-with-durable-pending-question-and-no-action-approval")
        await chat.answerUserQuestion("Osaka", ticketID: question.id)
        try await waitUntil(seconds: 120) { !chat.busy || chat.pendingUserQuestion != nil }
        XCTAssertFalse(chat.busy); XCTAssertNil(chat.error)
        guard !chat.busy, chat.error == nil else { return }
        XCTAssertTrue(chat.current?.messages.contains { $0.role == .tool && $0.toolName == "ask_user" && $0.content == "Osaka" && $0.status == .complete } == true)
        _ = try XCTUnwrap(chat.current?.plan, "The model did not propose a bounded numbered plan after the answer.")
        actions.append("real-model-consumed-answer-and-proposed-plan")
        files.mode = .ask
        var value = try XCTUnwrap(chat.current)
        value.plan = TaskPlan(steps: [TaskStep(text: "Choose Osaka"), TaskStep(text: "Write travel plan")])
        await chat.update(value)
        chat.draft = "Osaka is chosen. Use advance with step 1 to mark Choose Osaka done, then tell me the remaining step."
        await chat.send()
        try await waitUntil(seconds: 120) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertFalse(chat.busy); XCTAssertNil(chat.pendingToolApproval); XCTAssertNil(chat.error)
        guard !chat.busy, chat.error == nil else { return }
        XCTAssertEqual(chat.current?.plan?.steps.first?.done, true)
        XCTAssertTrue(chat.current?.messages.contains { $0.toolName == "advance" && $0.status == .complete } == true)
        let reopened = try ConversationStore(file: file)
        let stored = try await reopened.conversation(try XCTUnwrap(chat.current?.id))
        XCTAssertEqual(stored.plan?.steps.first?.done, true)
        guard stored.plan?.steps.first?.done == true else { return }
        actions.append("real-model-advance-in-ask-mode-and-durable-plan-reopen")
        completed = true
    }
    func testNativeFileAgentRoundTrip() async throws {
        var actions: [String] = [], approvals: [String] = []
        var completed = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("product-file-agent-" + UUID().uuidString)
        let folder = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "openweights.file-agent-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let files = WorkspaceController(bookmarkFile: root.appendingPathComponent("workspace.bookmark"), defaults: defaults)
        await files.choose(folder)
        XCTAssertNil(files.error)
        guard files.error == nil else { return }
        files.enabled = ["write_file"]; files.mode = .ask
        let restored = WorkspaceController(bookmarkFile: root.appendingPathComponent("workspace.bookmark"), defaults: defaults)
        await restored.restore()
        XCTAssertNil(restored.error); XCTAssertEqual(restored.folderName, "Shared")
        guard restored.error == nil, restored.folderName == "Shared" else { return }
        actions.append("owned-folder-bookmark-and-switches-restored")
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"),
            library: try ModelLibrary(file: root.appendingPathComponent("models.json")),
            sessionIdentifier: "org.experimentalmachines.openweights.file-agent-tests." + UUID().uuidString)
        let chat = ChatController(store: try ConversationStore(file: root.appendingPathComponent("conversations.json")),
                                  downloads: downloads, files: restored, defaults: defaults)
        defer {
            chat.cancel()
            attach(["purpose": "native-product-file-agent", "completed": completed, "actionsReached": actions,
                    "displayedApprovalArguments": approvals, "error": chat.error ?? restored.error ?? "",
                    "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                    "limitations": ["Uses a local folder inside the app container and controller approvals, not the system picker or touch navigation.",
                                    "Does not verify third-party file providers, OS-level grant revocation or device restart."]])
        }
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let source = cachedDirectory(artifact: "gguf", revision: try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source, file: try XCTUnwrap(pinned.files.first))
        await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first)
        model.settings.temperature = 0; model.settings.repeatPenalty = 1; model.settings.outputTokens = 128; model.settings.thinking = false
        try await downloads.save(model); await chat.load(model)
        XCTAssertNil(chat.error); XCTAssertTrue(chat.supportsTools)
        guard chat.error == nil, chat.supportsTools else { return }
        chat.draft = "Use write_file to create note.txt with the exact content Cedar."
        await chat.send()
        try await waitUntil(seconds: 120) { chat.pendingToolApproval != nil || !chat.busy }
        let write = try XCTUnwrap(chat.pendingToolApproval, chat.error ?? "The model did not request a file write.")
        XCTAssertEqual(write.displayedCall.name, "write_file")
        let writeArguments = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(write.displayedCall.argumentsJSON.utf8)) as? [String: Any])
        XCTAssertEqual(writeArguments["path"] as? String, "note.txt"); XCTAssertEqual(writeArguments["content"] as? String, "Cedar")
        let note = folder.appendingPathComponent("note.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        guard write.displayedCall.name == "write_file", writeArguments["path"] as? String == "note.txt",
              writeArguments["content"] as? String == "Cedar", !FileManager.default.fileExists(atPath: note.path) else { return }
        approvals.append(write.displayedCall.argumentsJSON)
        chat.answerToolApproval(approved: true, ticketID: write.ticketID)
        try await waitUntil(seconds: 120) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertFalse(chat.busy); XCTAssertNil(chat.error)
        guard !chat.busy, chat.error == nil else { return }
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "Cedar")
        actions.append("real-model-file-write-waits-for-exact-approval-and-persists")
        restored.enabled = ["read_file"]; restored.mode = .auto
        await chat.newConversation()
        chat.draft = "Read note.txt using read_file and tell me its content."
        await chat.send()
        try await waitUntil(seconds: 120) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertFalse(chat.busy); XCTAssertNil(chat.error)
        guard !chat.busy, chat.error == nil else { return }
        XCTAssertTrue(chat.current?.messages.contains { $0.role == .tool && $0.toolName == "read_file" && $0.content == "Cedar" } == true)
        XCTAssertTrue(chat.current?.messages.last?.content.contains("Cedar") == true)
        guard chat.current?.messages.contains(where: { $0.role == .tool && $0.toolName == "read_file" && $0.content == "Cedar" }) == true,
              chat.current?.messages.last?.content.contains("Cedar") == true else { return }
        actions.append("new-chat-real-model-file-read-and-answer")
        restored.enabled = ["delete_file"]
        await chat.newConversation()
        chat.draft = "Use delete_file to delete note.txt."
        await chat.send()
        try await waitUntil(seconds: 120) { chat.pendingToolApproval != nil || !chat.busy }
        let deletion = try XCTUnwrap(chat.pendingToolApproval, chat.error ?? "The model did not request file deletion.")
        XCTAssertEqual(deletion.displayedCall.name, "delete_file")
        let deleteArguments = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(deletion.displayedCall.argumentsJSON.utf8)) as? [String: Any])
        XCTAssertEqual(deleteArguments["path"] as? String, "note.txt")
        guard deletion.displayedCall.name == "delete_file", deleteArguments["path"] as? String == "note.txt" else { return }
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
        approvals.append(deletion.displayedCall.argumentsJSON)
        chat.answerToolApproval(approved: true, ticketID: deletion.ticketID)
        try await waitUntil(seconds: 120) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertFalse(chat.busy); XCTAssertNil(chat.error)
        guard !chat.busy, chat.error == nil else { return }
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        guard !FileManager.default.fileExists(atPath: note.path) else { return }
        actions.append("cross-chat-file-delete-asks-even-in-auto")
        await restored.revoke()
        XCTAssertNil(restored.grantID); XCTAssertTrue(restored.definitions.isEmpty)
        guard restored.grantID == nil, restored.definitions.isEmpty else { return }
        actions.append("grant-revocation-removes-tools")
        completed = true
    }
    func testNativeMemoryAgentRoundTrip() async throws {
        var actions: [String] = []
        var completed = false
        var displayedArguments: [String] = []
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("product-memory-agent-" + UUID().uuidString)
        let suite = "openweights.memory-agent-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = MemoryController(store: try MemoryStore(file: root.appendingPathComponent("memory.json")), defaults: defaults)
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"),
            library: try ModelLibrary(file: root.appendingPathComponent("models.json")),
            sessionIdentifier: "org.experimentalmachines.openweights.memory-agent-tests." + UUID().uuidString)
        let chat = ChatController(store: try ConversationStore(file: root.appendingPathComponent("conversations.json")),
                                  downloads: downloads, memory: memory, defaults: defaults)
        defer {
            chat.cancel()
            attach(["purpose": "native-product-memory-agent", "completed": completed, "actionsReached": actions,
                    "displayedApprovalArguments": displayedArguments, "controllerError": chat.error ?? "",
                    "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                    "limitations": ["Uses the verified cached GGUF and real product native runtime with fixture facts.",
                                    "Approval decisions are driven through the controller, not touch navigation.",
                                    "No other agent tools or model families are verified by this test."]])
        }
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let source = cachedDirectory(artifact: "gguf", revision: try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source, file: try XCTUnwrap(pinned.files.first))
        await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first)
        model.settings.temperature = 0; model.settings.repeatPenalty = 1; model.settings.outputTokens = 128
        try await downloads.save(model)
        await chat.load(model)
        XCTAssertNil(chat.error)
        XCTAssertTrue(chat.supportsTools)
        guard chat.error == nil, chat.supportsTools else { return }
        memory.writeEnabled = true
        chat.draft = "Remember this lasting fact: My project is Cedar. Use save_memory with that exact fact."
        await chat.send()
        try await waitUntil(seconds: 120) { chat.pendingToolApproval != nil || !chat.busy }
        let save = try XCTUnwrap(chat.pendingToolApproval, chat.error ?? "No save approval was requested.")
        XCTAssertEqual(save.displayedCall.name, "save_memory")
        guard save.displayedCall.name == "save_memory" else { return }
        let before = await memory.store.list()
        XCTAssertTrue(before.isEmpty)
        guard before.isEmpty else { return }
        displayedArguments.append(save.displayedCall.argumentsJSON)
        actions.append("real-model-requested-save-without-writing-before-approval")
        chat.answerToolApproval(approved: true, ticketID: save.ticketID)
        try await waitUntil(seconds: 120) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertFalse(chat.busy, "The model requested another approval instead of finishing the save turn.")
        XCTAssertNil(chat.error)
        guard !chat.busy, chat.error == nil else { return }
        let remembered = await memory.store.list()
        let saved = try XCTUnwrap(remembered.first)
        XCTAssertEqual(remembered.count, 1)
        XCTAssertTrue(saved.text.contains("Cedar"))
        guard remembered.count == 1, saved.text.contains("Cedar") else { return }
        actions.append("approved-save-followed-by-real-answer-pass")

        memory.writeEnabled = false; memory.readEnabled = true
        await chat.newConversation()
        chat.draft = "Use read_memory to find my saved project. Reply with its name."
        await chat.send()
        try await waitUntil(seconds: 120) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertNil(chat.pendingToolApproval)
        XCTAssertNil(chat.error)
        guard !chat.busy, chat.error == nil else { return }
        let readReached = chat.current?.messages.contains { $0.role == .tool && $0.toolName == "read_memory" && $0.content.contains("Cedar") } == true
        let answered = chat.current?.messages.last?.content.contains("Cedar") == true
        XCTAssertTrue(readReached)
        XCTAssertTrue(answered)
        guard readReached && answered else { return }
        actions.append("new-conversation-read-on-demand-and-real-answer")

        memory.writeEnabled = true
        chat.draft = "Forget this exact saved fact using forget_memory: " + saved.text
        await chat.send()
        try await waitUntil(seconds: 120) { chat.pendingToolApproval != nil || !chat.busy }
        let forget = try XCTUnwrap(chat.pendingToolApproval, chat.error ?? "No deletion approval was requested.")
        XCTAssertEqual(forget.displayedCall.name, "forget_memory")
        guard forget.displayedCall.name == "forget_memory" else { return }
        displayedArguments.append(forget.displayedCall.argumentsJSON)
        chat.answerToolApproval(approved: true, ticketID: forget.ticketID)
        try await waitUntil(seconds: 120) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertFalse(chat.busy)
        XCTAssertNil(chat.error)
        guard !chat.busy, chat.error == nil else { return }
        let final = await memory.store.list()
        XCTAssertTrue(final.isEmpty)
        guard final.isEmpty else { return }
        actions.append("approved-forget-and-real-answer")
        completed = true
    }
    func testImportOwnsRegularFilesAndCleansFailedCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("product-import-boundary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = try ModelLibrary(file: root.appendingPathComponent("models.json"))
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: library)
        let bad = root.appendingPathComponent("bad.gguf")
        try Data("not a model".utf8).write(to: bad)
        await downloads.importGGUF(bad)
        XCTAssertNotNil(downloads.error)
        XCTAssertTrue(downloads.models.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: downloads.root, includingPropertiesForKeys: nil).isEmpty)
        let source = root.appendingPathComponent("source.gguf")
        let bytes = Data("GGUF import fixture".utf8)
        try bytes.write(to: source)
        let link = root.appendingPathComponent("link.gguf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await downloads.importGGUF(link)
        XCTAssertNotNil(downloads.error)
        XCTAssertTrue(downloads.models.isEmpty)
        await downloads.importGGUF(source)
        XCTAssertNil(downloads.error)
        let imported = try XCTUnwrap(downloads.models.first)
        XCTAssertEqual(imported.state, .ready)
        try FileManager.default.removeItem(at: source)
        let owned = try imported.files[0].destination(in: downloads.directory(imported))
        XCTAssertEqual(try Data(contentsOf: owned), bytes)
        try ModelDownloads.verify(owned, file: imported.files[0])
        attach(["purpose": "native-product-import-file-boundary", "completed": true,
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "actions": ["reject-bad-magic-and-remove-owned-copy", "reject-symbolic-link", "own-regular-copy-after-source-deletion", "verify-size-and-hash"],
                "limitations": ["Small magic-header fixture tests import ownership, not model inference or file-picker navigation."]])
    }
    func testSavedMemoryControllerAndToolGates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("product-memory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("memory.json")
        let controller = MemoryController(store: try MemoryStore(file: file))
        await controller.restore()
        XCTAssertTrue(controller.facts.isEmpty)
        let saved = await controller.save("My dietary rule is vegan.")
        XCTAssertTrue(saved)
        let original = try XCTUnwrap(controller.facts.first)
        let updated = await controller.save("My dietary rule is vegetarian.", replacing: original)
        XCTAssertTrue(updated)
        XCTAssertEqual(controller.facts.first?.id, original.id)
        let rejected = await controller.save(String(repeating: "x", count: 161))
        XCTAssertFalse(rejected)
        XCTAssertNotNil(controller.error)
        XCTAssertEqual(controller.facts.count, 1)

        let reopened = MemoryController(store: try MemoryStore(file: file))
        await reopened.restore()
        XCTAssertEqual(reopened.facts.first?.text, "My dietary rule is vegetarian.")
        var settings = MemoryToolSettings()
        let read = AgentToolCall(id: "read-1", name: "read_memory", argumentsJSON: "{}")
        let disabled = await reopened.tools.execute(read, settings: settings)
        XCTAssertTrue(disabled.rejected)
        settings.readEnabled = true; settings.writeEnabled = true
        let retrieved = await reopened.tools.execute(read, settings: settings)
        XCTAssertFalse(retrieved.rejected)
        XCTAssertTrue(retrieved.text.contains("vegetarian"))
        let write = AgentToolCall(id: "write-1", name: "save_memory", argumentsJSON: "{\"fact\":\"My project is Cedar.\"}")
        let unapproved = await reopened.tools.execute(write, settings: settings)
        XCTAssertTrue(unapproved.rejected)
        let approval = ApprovedToolCall(displayedCall: write)
        let approved = await reopened.tools.execute(write, settings: settings, approval: approval)
        XCTAssertFalse(approved.rejected)
        let replayed = await reopened.tools.execute(write, settings: settings, approval: approval)
        XCTAssertTrue(replayed.rejected)
        await reopened.restore()
        XCTAssertEqual(reopened.facts.count, 2)
        await reopened.delete(try XCTUnwrap(reopened.facts.first { $0.text.contains("vegetarian") }))
        XCTAssertEqual(reopened.facts.count, 1)
        await reopened.deleteAll()
        let final = try MemoryStore(file: file)
        let remaining = await final.list()
        XCTAssertTrue(remaining.isEmpty)
        attach(["purpose": "native-product-saved-memory-controller", "completed": true,
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "actions": ["save", "edit-preserving-id", "reject-too-long-without-losing-facts", "reopen",
                            "disabled-read-rejected", "enabled-read", "unapproved-write-rejected",
                            "exact-write-approved-once", "delete", "delete-all-and-reopen"],
                "limitations": ["Controller and tool-store integration, not generated agent calls or touch navigation."]])
    }
    func testModelPathInExistingDeviceContainer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = ModelFile(path: "Qwen3-0.6B-Q4_K_M.gguf")
        _ = try file.destination(in: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try file.destination(in: root)
        try Data("partial".utf8).write(to: root.appendingPathComponent(file.path + ".partial"))
        _ = try file.destination(in: root)
    }
    func testNativeFontsAndCatalogue() throws {
        for name in ["HankenGrotesk-Regular", "SchibstedGrotesk-Regular", "GeistMono-Regular"] {
            XCTAssertNotNil(UIFont(name: name, size: 16), name)
        }
        let catalogue = try HubClient.pinnedCatalogue()
        XCTAssertEqual(catalogue.count, 3)
        XCTAssertEqual(Set(catalogue.map(\.backend)), Set([.llamaMetal, .mlx, .xnnpack]))
        for model in catalogue {
            XCTAssertFalse(model.files.isEmpty)
            XCTAssertTrue(model.files.allSatisfy { $0.sha256?.count == 64 && $0.bytes != nil })
        }
    }
    func testModelVerificationRejectsCorruption() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("bad".utf8).write(to: file)
        XCTAssertThrowsError(try ModelDownloads.verify(file, file: ModelFile(path: "model", bytes: 4)))
        XCTAssertThrowsError(try ModelDownloads.verify(file, file: ModelFile(path: "model", sha256: String(repeating: "0", count: 64))))
        try ModelDownloads.verify(file, file: ModelFile(path: "model", bytes: 3, sha256: try ModelDownloads.hash(file)))
    }

    func testDownloadedGGUFChatWorkflow() async throws {
        var actions: [String] = []
        var completed = false
        var downloadInterrupted = false
        var checkpointBytes: Int64 = 0
        var transferSnapshot: [[String: Any]] = []
        var observations: [String: Any] = [:]
        var reopened: ModelDownloads?
        defer {
            let evidence: [String: Any] = ["purpose": "native-product-download-chat-workflow", "completed": completed, "actionsReached": actions,
                "downloadInterruptedAndOwnedCheckpointObserved": downloadInterrupted, "checkpointBytes": checkpointBytes,
                "transferSnapshot": transferSnapshot, "observations": observations,
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations": ["Direct product-controller integration, not touch-navigation or accessibility verification.", "Reopens paused product metadata and the download manager, not a killed app process or suspended background task.", "Runtime switching here covers GGUF Metal to CPU only.", "Stop is triggered on published streaming text. Native worker interruption before buffered computation finishes is not independently established."]]
            if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "native-product-workflow.json"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("product-flow-" + UUID().uuidString)
        defer { if completed { try? FileManager.default.removeItem(at: root) } }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Models"), withIntermediateDirectories: true)
        let libraryURL = root.appendingPathComponent("models.json")
        let library = try ModelLibrary(file: libraryURL)
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: library,
            sessionIdentifier: "org.experimentalmachines.openweights.product-tests." + UUID().uuidString)
        defer { transferSnapshot = (reopened ?? downloads).diagnosticSnapshot(); downloads.cancelAllTransfers(); reopened?.cancelAllTransfers() }
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let details = try await HubClient.details(try XCTUnwrap(pinned.repository), revision: try XCTUnwrap(pinned.revision), transport: HubAPITransport(useStoredCredential: false))
        let file = try XCTUnwrap(details.siblings.first { $0.rfilename == pinned.entryFile })
        var model = try HubClient.gguf(details, file: file)
        XCTAssertEqual(model.files.first?.sha256, pinned.files.first?.sha256)
        XCTAssertEqual(model.files.first?.bytes, pinned.files.first?.bytes)
        let source = try HubGGUFRangeSource(model: model, useStoredCredential: false)
        let metadata = try await GGUFHeaderParser(source: source).parse()
        XCTAssertNil(metadata.standaloneIssue(registeredArchitectures: Set(OWRuntimeSession.registeredArchitectureNames())))
        model.files[0].bytes = await source.totalBytes
        observations = ["repository": details.id, "revision": details.sha, "file": file.rfilename,
            "publishedSHA256": model.files[0].sha256 ?? "", "expectedBytes": model.files[0].bytes ?? -1,
            "architecture": metadata.architecture, "headerFetchedBytes": metadata.fetchedBytes]
        actions.append("select-canonical-pinned-file-and-inspect-header")
        model.settings.temperature = 0; model.settings.repeatPenalty = 1; model.settings.outputTokens = 64
        await downloads.install(model)
        try await waitUntil(seconds: 180) { downloads.committedBytes(model) > 0 || downloads.models.first?.state == .ready || downloads.models.first?.state == .failed }
        if downloads.models.first?.state == .downloading {
            await downloads.pause(try XCTUnwrap(downloads.models.first))
            let paused = await library.list()
            XCTAssertEqual(paused.first?.state, .paused)
            checkpointBytes = downloads.committedBytes(model)
            XCTAssertGreaterThan(checkpointBytes, 0)
            XCTAssertLessThan(checkpointBytes, try XCTUnwrap(model.files.first?.bytes))
            downloadInterrupted = true
            actions.append("pause-full-model-download-with-owned-checkpoint")
        }
        XCTAssertTrue(downloadInterrupted, "The test must observe a paused partial file before claiming resume verification.")
        guard downloadInterrupted else { return }
        downloads.cancelAllTransfers()
        let restored = ModelDownloads(root: downloads.root, library: try ModelLibrary(file: libraryURL),
            sessionIdentifier: "org.experimentalmachines.openweights.product-reopen-tests." + UUID().uuidString)
        reopened = restored
        await restored.restore()
        XCTAssertEqual(restored.models.first?.state, .paused)
        let restoredCheckpoint = restored.committedBytes(model)
        XCTAssertEqual(restoredCheckpoint, checkpointBytes)
        guard restoredCheckpoint == checkpointBytes else { return }
        actions.append("reopen-paused-model-metadata-and-owned-checkpoint")
        await restored.resume(try XCTUnwrap(restored.models.first))
        observations["resumeRequestRanges"] = restored.diagnosticSnapshot().map { $0["range"] as? String ?? "" }
        let resumedAtCheckpoint = restored.diagnosticSnapshot().contains { ($0["range"] as? String)?.hasPrefix("bytes=\(checkpointBytes)-") == true }
        XCTAssertTrue(resumedAtCheckpoint)
        guard resumedAtCheckpoint else { return }
        try await waitUntil(seconds: 480) { restored.models.first?.state == .ready || restored.models.first?.state == .failed }
        let installed = try XCTUnwrap(restored.models.first)
        XCTAssertEqual(installed.state, .ready, installed.failure ?? "")
        guard installed.state == .ready else { return }
        let owned = try XCTUnwrap(installed.files.first).destination(in: restored.directory(installed))
        let verifiedHash = try await Task.detached { try ModelDownloads.hash(owned) }.value
        let downloadedBytes = try ModelFileTransfer.byteCount(owned)
        XCTAssertEqual(verifiedHash, installed.files.first?.sha256)
        XCTAssertEqual(downloadedBytes, installed.files.first?.bytes)
        observations["downloadedSHA256"] = verifiedHash; observations["downloadedBytes"] = downloadedBytes
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.appendingPathExtension("partial").path))
        actions.append("download-verify-ready")
        try await exerciseChat(installed: installed, downloads: restored, root: root, actions: &actions)
        completed = actions.last == "switch-metal-to-cpu-and-send" && verifiedHash == installed.files.first?.sha256
    }

    func testCachedGGUFChatActions() async throws {
        var actions: [String] = []
        defer { attach(["purpose": "native-product-cached-gguf-chat-actions", "actionsReached": actions,
                        "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                        "limitations": ["Imports a verified benchmark cache file into a separate product-owned directory.", "No network download or touch-navigation claim."]]) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("product-import-" + UUID().uuidString)
        let library = try ModelLibrary(file: root.appendingPathComponent("models.json"))
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: library,
                                       sessionIdentifier: "org.experimentalmachines.openweights.import-tests." + UUID().uuidString)
        defer { downloads.cancelAllTransfers() }
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let source = cachedDirectory(artifact: "gguf", revision: try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source, file: try XCTUnwrap(pinned.files.first))
        await downloads.importGGUF(source)
        var imported = try XCTUnwrap(downloads.models.first)
        XCTAssertEqual(imported.state, .ready)
        XCTAssertEqual(imported.files.first?.sha256, pinned.files.first?.sha256)
        imported.settings.temperature = 0; imported.settings.repeatPenalty = 1; imported.settings.outputTokens = 64
        try await downloads.save(imported)
        actions.append("import-and-hash-pinned-gguf")
        try await exerciseChat(installed: imported, downloads: downloads, root: root, actions: &actions)
    }

    func testPinnedMLXTokenizerResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("product-resume-" + UUID().uuidString)
        let libraryURL = root.appendingPathComponent("models.json")
        let library = try ModelLibrary(file: libraryURL)
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: library,
            sessionIdentifier: "org.experimentalmachines.openweights.tokenizer-tests." + UUID().uuidString, chunkBytes: 1024 * 1024)
        var reopened: ModelDownloads?
        var actions: [String] = []
        var checkpointBytes: Int64 = 0
        defer {
            let snapshot = (reopened ?? downloads).diagnosticSnapshot()
            downloads.cancelAllTransfers(); reopened?.cancelAllTransfers()
            attach(["purpose": "native-product-pinned-tokenizer-resume", "actionsReached": actions,
                    "checkpointBytes": checkpointBytes, "transferSnapshot": snapshot,
                    "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                    "limitations": ["Transfers the pinned 11,422,654-byte MLX tokenizer in 1 MiB test chunks.", "Other model files are copied from the verified benchmark cache.", "Reopens product metadata and the download manager, not a killed app process."]])
        }
        let model = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .mlx })
        let source = cachedDirectory(artifact: "mlx", revision: try XCTUnwrap(model.revision))
        let target = downloads.directory(model)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for file in model.files where file.path != "tokenizer.json" {
            let original = try file.destination(in: source)
            try ModelDownloads.verify(original, file: file)
            try FileManager.default.copyItem(at: original, to: file.destination(in: target))
        }
        let tokenizer = try XCTUnwrap(model.files.first { $0.path == "tokenizer.json" })
        let partial = try tokenizer.destination(in: target).appendingPathExtension("partial")
        await downloads.install(model)
        try await waitUntil(seconds: 180) { ((try? ModelFileTransfer.byteCount(partial)) ?? 0) > 0 || downloads.models.first?.state == .failed }
        XCTAssertNotEqual(downloads.models.first?.state, .failed, downloads.models.first?.failure ?? "")
        await downloads.pause(try XCTUnwrap(downloads.models.first))
        checkpointBytes = try ModelFileTransfer.byteCount(partial)
        XCTAssertGreaterThan(checkpointBytes, 0)
        XCTAssertLessThan(checkpointBytes, try XCTUnwrap(tokenizer.bytes))
        actions.append("pause-with-owned-byte-checkpoint")
        downloads.cancelAllTransfers()
        let restored = ModelDownloads(root: downloads.root, library: try ModelLibrary(file: libraryURL),
            sessionIdentifier: "org.experimentalmachines.openweights.tokenizer-reopen-tests." + UUID().uuidString, chunkBytes: 1024 * 1024)
        reopened = restored
        await restored.restore()
        XCTAssertEqual(restored.models.first?.state, .paused)
        XCTAssertEqual(try ModelFileTransfer.byteCount(partial), checkpointBytes)
        actions.append("reopen-paused-metadata-and-checkpoint")
        await restored.resume(try XCTUnwrap(restored.models.first))
        try await waitUntil(seconds: 480) { restored.models.first?.state == .ready || restored.models.first?.state == .failed }
        let ready = try XCTUnwrap(restored.models.first)
        XCTAssertEqual(ready.state, .ready, ready.failure ?? "")
        guard ready.state == .ready else { return }
        for file in ready.files { try ModelDownloads.verify(file.destination(in: target), file: file) }
        actions.append("resume-remaining-ranges-and-verify-all-model-files")
    }

    func cachedDirectory(artifact: String, revision: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models/" + artifact + "/" + revision)
    }
    private func attach(_ evidence: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
            let value = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            value.name = (evidence["purpose"] as? String ?? "product-flow") + ".json"
            value.lifetime = .keepAlways; add(value)
        }
    }

    private func exerciseChat(installed: LocalModel, downloads: ModelDownloads, root: URL, actions: inout [String]) async throws {
        let storeURL = root.appendingPathComponent("conversations.json")
        let suiteName = "product-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let chat = ChatController(store: try ConversationStore(file: storeURL), downloads: downloads, defaults: defaults)
        await chat.load(installed)
        XCTAssertNil(chat.error)
        chat.draft = "Remember this project is called Cedar. Reply briefly."
        await chat.send(); try await waitUntil(seconds: 90) { !chat.busy }
        XCTAssertNil(chat.error)
        let initial = try XCTUnwrap(chat.current)
        XCTAssertEqual(initial.messages.count, 2)
        XCTAssertFalse(initial.messages.last?.content.isEmpty ?? true)
        actions.append("stream-and-persist")
        // Short replies can finish between timer polls. Stop at a published streaming
        // update so the test never mistakes cancellation after completion for Stop.
        var stopIssuedOnStream = false
        let cancellation = chat.$current.sink { value in
            guard !stopIssuedOnStream, chat.busy, let message = value?.messages.last,
                  message.role == .assistant, message.status == .streaming, !message.content.isEmpty else { return }
            stopIssuedOnStream = true
            chat.cancel()
        }
        defer { cancellation.cancel() }
        chat.draft = "Write a long detailed story about Cedar."
        await chat.send()
        try await waitUntil(seconds: 30) { !chat.busy }
        cancellation.cancel()
        XCTAssertTrue(stopIssuedOnStream)
        XCTAssertFalse(chat.current?.messages.last?.content.isEmpty ?? true)
        XCTAssertEqual(chat.current?.messages.last?.status, .cancelled)
        actions.append("cancel-partial")
        chat.draft = "What is this project called? Answer with its name only."
        await chat.send(); try await waitUntil(seconds: 90) { !chat.busy }
        XCTAssertNil(chat.error)
        XCTAssertEqual(chat.current?.messages.last?.status, .complete)
        actions.append("send-after-cancellation")
        let reopened = ChatController(store: try ConversationStore(file: storeURL), downloads: downloads, defaults: defaults)
        await reopened.restore()
        XCTAssertEqual(reopened.current?.messages, chat.current?.messages)
        actions.append("reopen-persisted-transcript")
        let originalID = try XCTUnwrap(chat.current?.id)
        await chat.branch(through: initial.messages[1].id)
        XCTAssertNotEqual(chat.current?.id, originalID)
        XCTAssertEqual(chat.current?.messages.count, 2)
        actions.append("branch-with-independent-id")
        await chat.regenerate(); try await waitUntil(seconds: 90) { !chat.busy }
        XCTAssertEqual(chat.current?.messages.count, 2)
        actions.append("regenerate")
        await chat.editAndResend(messageID: try XCTUnwrap(chat.current?.messages.first?.id), text: "Say hello briefly.")
        try await waitUntil(seconds: 90) { !chat.busy }
        XCTAssertEqual(chat.current?.messages.first?.content, "Say hello briefly.")
        XCTAssertNil(chat.error)
        actions.append("edit-and-resend")
        var cpu = installed; cpu.backend = .llamaCPU
        await chat.load(cpu)
        XCTAssertEqual(chat.loadedModel?.backend, .llamaCPU)
        chat.draft = "What is two plus two?"
        await chat.send(); try await waitUntil(seconds: 90) { !chat.busy }
        XCTAssertNil(chat.error)
        XCTAssertEqual(chat.current?.messages.last?.status, .complete)
        actions.append("switch-metal-to-cpu-and-send")
    }

    func waitUntil(seconds: Double, condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ModelError.unsupported("Product flow timed out after \(seconds) seconds.") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
