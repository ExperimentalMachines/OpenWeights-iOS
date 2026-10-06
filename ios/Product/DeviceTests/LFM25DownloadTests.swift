import Foundation
import XCTest
import UIKit
import Combine
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    func testNativeShortlistedLFM25DownloadResumeAndMultiturnChat() async throws {
        let pinned = NativeLFMArtifact.metal()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lfm25-download-" + UUID().uuidString)
        let suite = root.lastPathComponent, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        let libraryURL = root.appendingPathComponent("models.json"), conversationsURL = root.appendingPathComponent("conversations.json")
        let downloads = ModelDownloads(root:root.appendingPathComponent("Models"),library:try ModelLibrary(file:libraryURL),sessionIdentifier:suite)
        var reopened: ModelDownloads?, chat: ChatController?
        var observed: NativeObservedRuntime?
        var actions: [String] = [], observations: [String:Any] = [:], completed = false
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            chat?.cancel(); downloads.cancelAllTransfers(); reopened?.cancelAllTransfers()
            UIApplication.shared.isIdleTimerDisabled = idle; defaults.removePersistentDomain(forName:suite)
            observations["ownedRoot"] = root.path
            observations["runtimeTrace"] = observed?.snapshot() ?? [:]
            lfm25DownloadAttachment(completed:completed,actions:actions,observations:observations)
        }
        let details = try await HubClient.details(try XCTUnwrap(pinned.repository),revision:try XCTUnwrap(pinned.revision),transport:HubAPITransport(useStoredCredential:false))
        let file = try XCTUnwrap(details.siblings.first { $0.rfilename == pinned.entryFile })
        var model = try HubClient.gguf(details,file:file)
        let range = try HubGGUFRangeSource(model:model,useStoredCredential:false)
        let header = try await GGUFHeaderParser(source:range).parse()
        XCTAssertEqual(header.architecture,"lfm2")
        XCTAssertNil(header.standaloneIssue(registeredArchitectures:Set(OWRuntimeSession.registeredArchitectureNames())))
        XCTAssertEqual(model.backend,.llamaMetal)
        model.family = header.architecture
        XCTAssertEqual(Set(model.files.map(\.path)),Set(pinned.files.map(\.path)))
        for expected in pinned.files {
            let selected = try XCTUnwrap(model.files.first { $0.path == expected.path })
            XCTAssertEqual(selected.bytes,expected.bytes)
            XCTAssertEqual(selected.sha256,expected.sha256)
            XCTAssertEqual(selected.url,expected.url)
        }
        observations = ["repository":details.id,"revision":details.sha,"entry":model.entryFile,"family":model.family ?? "",
            "components":model.files.map { ["path":$0.path,"bytes":$0.bytes ?? -1,"sha256":$0.sha256 ?? "","gitBlobSHA1":$0.gitBlobSHA1 ?? ""] }]
        observations["architecture"] = header.architecture
        observations["headerFetchedBytes"] = header.fetchedBytes
        observations["trainingContext"] = header.trainingContext
        actions.append("select-shortlist-measured-file-by-live-pin-and-recognized-header")
        model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1; model.settings.outputTokens = 96; model.settings.contextTokens = 2048
        await downloads.install(model); XCTAssertNil(downloads.error)
        let weights = try XCTUnwrap(model.files.first { $0.path == model.entryFile })
        let ownedWeights = try weights.destination(in:downloads.directory(model)), partial = ownedWeights.appendingPathExtension("partial")
        try await waitUntil(seconds:180) { ((try? ModelFileTransfer.byteCount(partial)) ?? 0) > 0 || downloads.models.first?.state == .ready || downloads.models.first?.state == .failed || downloads.error != nil }
        XCTAssertEqual(downloads.models.first?.state,.downloading,downloads.error ?? downloads.models.first?.failure ?? "")
        guard downloads.models.first?.state == .downloading else { return }
        await downloads.pause(try XCTUnwrap(downloads.models.first)); XCTAssertNil(downloads.error)
        let checkpoint = try ModelFileTransfer.byteCount(partial)
        XCTAssertGreaterThan(checkpoint,0); XCTAssertLessThan(checkpoint,try XCTUnwrap(weights.bytes))
        XCTAssertEqual(downloads.models.first?.state,.paused)
        observations["weightCheckpointBytes"] = checkpoint
        let saved = downloads.models
        try await Task.sleep(nanoseconds:200_000_000)
        XCTAssertEqual(try ModelFileTransfer.byteCount(partial),checkpoint)
        downloads.cancelAllTransfers()
        let restored = ModelDownloads(root:downloads.root,library:try ModelLibrary(file:libraryURL),sessionIdentifier:suite + ".reopen")
        reopened = restored; await restored.restore()
        XCTAssertEqual(restored.models,saved)
        XCTAssertEqual(try ModelFileTransfer.byteCount(partial),checkpoint)
        actions.append("pause-stable-weight-checkpoint-and-reopen-model-metadata")
        await restored.resume(try XCTUnwrap(restored.models.first)); XCTAssertNil(restored.error)
        let ranges = restored.diagnosticSnapshot().compactMap { $0["range"] as? String }
        observations["resumeRequestRanges"] = ranges
        XCTAssertTrue(ranges.contains { $0.hasPrefix("bytes=\(checkpoint)-") })
        guard ranges.contains(where:{ $0.hasPrefix("bytes=\(checkpoint)-") }) else { return }
        try await waitUntil(seconds:480) { restored.models.first?.state == .ready || restored.models.first?.state == .failed || restored.error != nil }
        let installed = try XCTUnwrap(restored.models.first)
        XCTAssertNil(restored.error); XCTAssertEqual(installed.state,.ready,installed.failure ?? "")
        guard installed.state == .ready else { return }
        var fullSHA256: [String:String] = [:]
        for expected in pinned.files {
            let owned = try expected.destination(in:restored.directory(installed))
            try await Task.detached { try ModelFileTransfer.verify(owned,file:expected) }.value
            let actual = try await Task.detached { try ModelFileTransfer.hash(owned) }.value
            fullSHA256[expected.path] = actual
            XCTAssertEqual(actual,expected.sha256)
            XCTAssertFalse(FileManager.default.fileExists(atPath:owned.appendingPathExtension("partial").path))
        }
        observations["independentFullFileSHA256"] = fullSHA256
        actions.append("resume-exact-range-and-verify-all-complete-files-against-independent-pins")
        lfm25DownloadAttachment(completed:false,actions:actions,observations:observations)
        let runtime = NativeObservedRuntime(try RuntimeFactory.make(installed)); observed = runtime
        let initial = ChatController(store:try ConversationStore(file:conversationsURL),downloads:restored,defaults:defaults,runtimeFactory:{ _ in runtime })
        chat = initial
        await initial.load(installed); XCTAssertNil(initial.error)
        guard initial.error == nil else { return }
        var replies: [[String:Any]] = []
        func send(_ prompt: String, expected: String? = nil) async throws -> String {
            initial.draft = prompt; await initial.send()
            try await waitUntil(seconds:120) { !initial.busy }
            XCTAssertNil(initial.error)
            let answer = try XCTUnwrap(initial.current?.messages.last { $0.role == .assistant }?.content).trimmingCharacters(in:.whitespacesAndNewlines)
            replies.append(["prompt":prompt,"answer":answer,"expected":expected ?? "", "matchesExpected":expected.map { answer == $0 || ($0 == "Cedar" && answer == "Cedar.") } as Any? ?? NSNull()])
            if let expected { XCTAssertTrue(answer == expected || (expected == "Cedar" && answer == "Cedar."),"Expected \(expected), got \(answer)") }
            observations["conversationProbes"] = replies
            return answer
        }
        _ = try await send("Reply with exactly Cedar.",expected:"Cedar")
        _ = try await send("Remember my destination is Kyoto and my budget is 450. Reply briefly.")
        _ = try await send("What are my destination and budget? Reply with exactly Kyoto|450.",expected:"Kyoto|450")
        _ = try await send("Correction: my destination is Osaka and my budget is 730. Replace the previous values. Reply briefly.")
        _ = try await send("What are my current destination and budget? Reply with exactly Osaka|730.",expected:"Osaka|730")
        let conversation = try XCTUnwrap(initial.current)
        let stored = try await ConversationStore(file:conversationsURL).conversation(conversation.id)
        var expectedStored = conversation; expectedStored.updatedAt = stored.updatedAt
        XCTAssertEqual(stored,expectedStored);XCTAssertGreaterThanOrEqual(stored.updatedAt,conversation.updatedAt)
        guard stored == expectedStored,stored.updatedAt >= conversation.updatedAt else { return }
        await initial.open(stored);XCTAssertNil(initial.error);XCTAssertEqual(initial.current,stored)
        XCTAssertEqual(initial.loadedModel?.id,installed.id)
        _ = try await send("What are my current destination and budget? Reply with exactly Osaka|730.",expected:"Osaka|730")
        actions.append("grow-history-update-facts-and-continue-durable-reopened-conversation")
        var stopped = false
        let stopObserver = initial.$current.sink { value in
            guard !stopped,initial.busy,let last=value?.messages.last,last.role == .assistant,last.status == .streaming,!last.content.isEmpty else { return }
            stopped = true;initial.cancel()
        }
        initial.draft = "Write a long detailed travel story about my current destination.";await initial.send()
        try await waitUntil(seconds:120) { !initial.busy };stopObserver.cancel()
        XCTAssertTrue(stopped);XCTAssertEqual(initial.current?.messages.last?.status,.cancelled)
        observations["stopIssuedOnPublishedStreamingText"] = stopped
        actions.append("stop-on-published-partial-text")
        _ = try await send("What are my current destination and budget? Reply with exactly Osaka|730.",expected:"Osaka|730")
        _ = try await send("What is 2 + 2? Reply with only the number.",expected:"4")
        actions.append("recover-after-stop-with-updated-facts-and-arithmetic")
        let exact = replies.compactMap { $0["matchesExpected"] as? Bool }
        completed = exact.count == 6 && exact.allSatisfy { $0 } && stopped && initial.error == nil
    }
    private func lfm25DownloadAttachment(completed:Bool,actions:[String],observations:[String:Any]) {
        let evidence:[String:Any] = ["purpose":"native-shortlisted-lfm25-download-resume-multiturn-chat","completed":completed,"actions":actions,"observations":observations,
            "operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations":["Actual public pinned Hub selection, bounded GGUF header inspection and fresh URLSession weight download. Complete independent SHA-256 is verified. No Mac/cached weight seeding.",
                "Pause/library/manager/conversation reopen occur within one process. No OS suspension, process death or Files/provider/native gestures/VoiceOver claim.",
                "Stop occurs on published partial text. Native worker interruption before buffered computation finishes is not independently proved.",
                "One pinned Metal artifact and a bounded synthetic fact/format probe. No tools, CPU routing, broader families, general quality, default recommendation, energy, measured fit, runtime ranking or A2 replication claim."]]
        let value=XCTAttachment(data:try! JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        value.name="native-lfm25-download-chat.json";value.lifetime = .keepAlways;add(value)
    }
}
