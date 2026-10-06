#if OW_SCRIPT_SECURITY_VALIDATION
import XCTest
import Darwin
import UIKit
import OpenWeightsCore
@testable import OpenWeights

@MainActor extension ProductTests {
    func testNativeScriptSandboxAccessAndHelperDeathPreservesLoadedChat() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The isolated helper requires iOS 26.") }
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("script-security-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("host-owned.txt")
        try Data("controlled-host-sentinel".utf8).write(to: sentinel)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "controlled-host-sentinel")
        let listener = socket(AF_INET, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(listener, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        defer { close(listener) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0); XCTAssertEqual(listen(listener, 4), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        XCTAssertEqual(named, 0); let port = UInt16(bigEndian: address.sin_port); XCTAssertNotEqual(port, 0)
        let positive = socket(AF_INET, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(positive, 0)
        guard positive >= 0 else { throw POSIXError(.EIO) }; defer { close(positive) }
        let connected = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(positive, $0, length) } }
        XCTAssertEqual(connected, 0)
        let runner = IsolatedScriptRunner()
        var observation: [String: Any] = ["purpose": "native-script-sandbox-and-helper-death", "completed": false,
            "hostPID": getpid(), "hostCanReadSentinel": true, "hostLoopbackConnectResult": connected,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations": ["Validation-only helper actions are compiled out of the standard build. One controlled host-file and loopback TCP boundary, not exhaustive sandbox or interpreter escape resistance. Loaded chat is exercised directly through the product controller. No model-generated script registration, older iOS, touch or background behavior."]]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys, .prettyPrinted]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        let probe = try await runner.validateAccess(path: sentinel.path, port: port)
        XCTAssertFalse(probe.failed)
        let decoded = try XCTUnwrap(probe.output.data(using: .utf8))
        let access = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded) as? [String: Any])
        observation["accessProbe"] = access
        let helperPID = try XCTUnwrap(runner.lastProcessID); observation["helperPIDBeforeDeath"] = helperPID
        XCTAssertNotEqual(helperPID, getpid())
        let fileError = try XCTUnwrap(access["fileErrno"] as? Int)
        let networkError = try XCTUnwrap(access["connectionErrno"] as? Int)
        XCTAssertEqual(access["fileOpened"] as? Bool, false)
        XCTAssertTrue([Int(EPERM), Int(EACCES)].contains(fileError))
        XCTAssertTrue([Int(EPERM), Int(EACCES)].contains(networkError))
        guard access["fileOpened"] as? Bool == false, [Int(EPERM), Int(EACCES)].contains(fileError), [Int(EPERM), Int(EACCES)].contains(networkError) else { return }

        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")), sessionIdentifier: "org.experimentalmachines.script-security." + UUID().uuidString)
        defer { downloads.cancelAllTransfers() }
        let pinned = try NativeAgentArtifact.selected()
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Models/gguf/" + (pinned.revision ?? ""))
        let source = cache.appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source, file: try XCTUnwrap(pinned.files.first))
        await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first); XCTAssertEqual(model.state, .ready)
        model.settings.temperature = 0; model.settings.repeatPenalty = 1; model.settings.outputTokens = 64
        try await downloads.save(model)
        let suite = "script-security-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let chat = ChatController(store: try ConversationStore(file: root.appendingPathComponent("chat.json")), downloads: downloads, defaults: defaults)
        await chat.load(model); XCTAssertNil(chat.error)
        func waitForChat() async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 90
            while chat.busy { guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }; try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertNil(chat.error); XCTAssertEqual(chat.current?.messages.last?.status, .complete)
        }
        chat.draft = "Remember this project is called Cedar. Reply briefly."
        await chat.send(); try await waitForChat()
        observation["chatBeforeDeath"] = chat.current?.messages.last?.content ?? ""
        let conversationID = try XCTUnwrap(chat.current?.id)
        let begin = ProcessInfo.processInfo.systemUptime
        do { _ = try await runner.terminateForValidation(); XCTFail("The killed helper returned success."); return }
        catch { observation["helperDeathError"] = String(describing: error); XCTAssertFalse(error is CancellationError) }
        observation["helperDeathReturnSeconds"] = ProcessInfo.processInfo.systemUptime - begin
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin, 5)
        let fresh = try await runner.run(source: "6*7", inputsJSON: "{}")
        XCTAssertEqual(fresh.output, "42"); XCTAssertFalse(fresh.failed)
        let nextPID = try XCTUnwrap(runner.lastProcessID); observation["helperPIDAfterDeath"] = nextPID
        XCTAssertNotEqual(nextPID, helperPID); XCTAssertNotEqual(nextPID, getpid())
        chat.draft = "What is this project called? Answer with its name only."
        await chat.send(); try await waitForChat()
        let answer = try XCTUnwrap(chat.current?.messages.last?.content)
        observation["chatAfterDeath"] = answer
        XCTAssertTrue(answer.lowercased().contains("cedar")); XCTAssertEqual(chat.current?.id, conversationID)
        XCTAssertEqual(chat.current?.messages.count, 4); XCTAssertEqual(getpid(), observation["hostPID"] as? Int32)
        observation["artifact"] = NativeAgentArtifact.evidence(pinned)
        observation["completed"] = fresh.output == "42" && nextPID != helperPID && answer.lowercased().contains("cedar") && chat.error == nil
    }
}
#endif
