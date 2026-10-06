import XCTest
import SwiftUI
import UIKit
import WebKit
import CryptoKit
import OpenWeightsCore
@testable import OpenWeights

@MainActor private func builderViews(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(builderViews) }
@MainActor private func builderWait(_ condition: () async throws -> Bool, seconds: Double = 20) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while try await !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
        try await Task.sleep(for: .milliseconds(50))
    }
}
private func builderSHA(_ data: Data) -> String { SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined() }

extension ProductTests {
    @MainActor func testNativeModelAuthoredCanvasCreationAndRepair() async throws {
        let pinned = try NativeAgentArtifact.selected()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-Canvas-builder-" + UUID().uuidString)
        let suite = "openweights.builder." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle; defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        let shared = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at:shared.appendingPathComponent("site"), withIntermediateDirectories:true)
        let entryURL = shared.appendingPathComponent("site/index.html")
        let conversationFile = root.appendingPathComponent("conversations.json")
        let downloads = ModelDownloads(root:root.appendingPathComponent("Models"), library:try ModelLibrary(file:root.appendingPathComponent("models.json")), sessionIdentifier:suite)
        let files = WorkspaceController(bookmarkFile:root.appendingPathComponent("workspace.bookmark"), defaults:defaults)
        await files.choose(shared); XCTAssertNil(files.error)
        files.enabled = ["read_file","write_file"]; files.canvasEnabled = ["show_website"]; files.mode = .ask
        var phase = "create", grades: [[String:Any]] = [], approvals: [[String:Any]] = [], observations: [String:Any] = [:]
        files.pageChecker = { canvas, folder in
            let report = await CanvasPageChecker.check(canvas, workspace:folder)
            grades.append(["phase":phase, "entry":canvas.entry, "returnedReport":report != nil, "errors":report?.errors ?? [], "missing":report?.missing ?? [], "blocked":report?.blocked ?? [], "verdict":report?.verdict ?? ""])
            return report
        }
        let observed = NativeObservedRuntime(LlamaRuntime(gpuLayers:99))
        let chat = ChatController(store:try ConversationStore(file:conversationFile), downloads:downloads, files:files, defaults:defaults, runtimeFactory:{ _ in observed })
        var completed = false
        var hosting: UIHostingController<NavigationStack<NavigationPath,CanvasScreen>>?
        defer {
            chat.cancel(); hosting?.dismiss(animated:false)
            observations["phase"] = phase; observations["error"] = chat.error ?? ""
            observations["currentConversation"] = FileManager.default.fileExists(atPath:conversationFile.path) ? String(decoding:(try? Data(contentsOf:conversationFile)) ?? Data(),as:UTF8.self) : ""
            observations["finalHTML"] = String(decoding:(try? Data(contentsOf:entryURL)) ?? Data(),as:UTF8.self)
            let value: [String:Any] = ["purpose":"native-model-authored-Canvas-create-interactive-page-exact-Ask-and-repair", "completed":completed, "observations":observations, "approvals":approvals, "grades":grades, "runtimeTrace":observed.snapshot(), "artifact":NativeAgentArtifact.evidence(pinned), "operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString, "limitations":["One pinned greedy 1.7B Q4_K_M Metal artifact, context 4096 and output limit 512. Model writes actual source; approvals and button action are programmatic native tests, not user gestures.", "The missing.css reference is inserted by the fixture after successful creation. This verifies response to a controlled real browser diagnostic, not a claim that the model originally made or autonomously discovered that defect.", "Actual CanvasScreen and persistent conversation reopening are exercised. No general model quality, default-model, website security, external provider or OS lifecycle claim."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value, options:[.prettyPrinted,.sortedKeys]), uniformTypeIdentifier:"public.json")
            attachment.name = "Model-authored Canvas creation and repair"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let source = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Models/gguf/" + (try XCTUnwrap(pinned.revision)) + "/" + pinned.entryFile)
        try ModelDownloads.verify(source,file:try XCTUnwrap(pinned.files.first)); await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first)
        model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1; model.settings.thinking = false
        model.settings.contextTokens = 4096; model.settings.outputTokens = 512
        try await downloads.save(model); await chat.load(model); XCTAssertNil(chat.error)
        var tickets: Set<UUID> = []
        @MainActor func finishTurn() async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 90
            while chat.busy {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
                if let question = chat.pendingUserQuestion { throw NSError(domain:"CanvasBuilderFixture",code:1,userInfo:[NSLocalizedDescriptionKey:"The model asked a question instead of performing the requested page task: " + question.text]) }
                if let request = chat.pendingToolApproval, tickets.insert(request.ticketID).inserted {
                    let call = request.displayedCall
                    guard ["read_file","write_file","show_website"].contains(call.name) else { throw NSError(domain:"CanvasBuilderFixture",code:2,userInfo:[NSLocalizedDescriptionKey:"Unexpected approval: " + call.name]) }
                    let path = try CanvasToolDefinitions.path(call)
                    guard path == "site/index.html" || (call.name == "show_website" && path == "site") else { throw WorkspaceError.invalidPath }
                    let before = try? Data(contentsOf:entryURL)
                    if phase == "create", call.name == "write_file", approvals.isEmpty { XCTAssertNil(before) }
                    if phase == "create", call.name == "show_website" { XCTAssertNil(files.canvas) }
                    approvals.append(["phase":phase, "ticket":request.ticketID.uuidString, "callName":call.name, "arguments":call.argumentsJSON, "beforeFileSHA256":before.map(builderSHA) ?? "absent", "canvasBeforeApproval":files.canvas?.entry ?? "absent"])
                    chat.answerToolApproval(approved:true)
                }
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTAssertNil(chat.error)
        }
        let createPrompt = "Create a complete local HTML page at site/index.html. It must show the heading Cedar Expedition in blue, a button with text Add one, and a visible numeric count starting at 0 that increases by 1 each time the button is pressed. Use inline CSS and JavaScript, no network URLs. Save using write_file, then open it using show_website. Do not ask a question. After it opens, briefly tell me it is ready."
        observations["createPrompt"] = createPrompt; chat.draft = createPrompt; await chat.send(); try await finishTurn()
        let authored = try Data(contentsOf:entryURL), authoredText = String(decoding:authored,as:UTF8.self)
        observations["authoredHTML"] = authoredText; observations["authoredSHA256"] = builderSHA(authored)
        XCTAssertEqual(files.canvas?.entry,"site/index.html")
        XCTAssertTrue(chat.current?.messages.contains { $0.toolName == "write_file" && $0.status == .complete } == true)
        XCTAssertTrue(chat.current?.messages.contains { $0.toolName == "show_website" && $0.status == .complete && $0.toolPrivateDataRead == true } == true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let presenter = try XCTUnwrap(scene.windows.first { $0.isKeyWindow }?.rootViewController)
        let shown = UIHostingController(rootView:NavigationStack { CanvasScreen(files:files) }); hosting = shown
        shown.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in presenter.present(shown,animated:false) { continuation.resume() } }
        try await builderWait {
            guard let web = builderViews(shown.view).compactMap({ $0 as? WKWebView }).first,
                  let text = try? await web.evaluateJavaScript("document.body.innerText") as? String else { return false }
            return text.contains("Cedar Expedition") && text.contains("Add one")
        }
        let web = try XCTUnwrap(builderViews(shown.view).compactMap { $0 as? WKWebView }.first)
        let measure = "({text:document.body.innerText,heading:document.querySelector('h1')?.textContent,color:document.querySelector('h1')?getComputedStyle(document.querySelector('h1')).color:'',missingReference:!!document.querySelector('link[href*=\"missing.css\"]')})"
        @MainActor func checkCounter() async throws -> [String:Any] {
            let beforeValue = try await web.evaluateJavaScript(measure)
            let before = try XCTUnwrap(beforeValue as? [String:Any])
            XCTAssertEqual((before["heading"] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines),"Cedar Expedition")
            let color = before["color"] as? String ?? ""
            let numbers = color.components(separatedBy:CharacterSet.decimalDigits.inverted).compactMap(Int.init)
            XCTAssertGreaterThanOrEqual(numbers.count,3)
            if numbers.count >= 3 { XCTAssertGreaterThan(numbers[2],numbers[0]); XCTAssertGreaterThan(numbers[2],numbers[1]) }
            let text = before["text"] as? String ?? ""
            XCTAssertNotNil(text.range(of:"(^|[^0-9])0([^0-9]|$)",options:.regularExpression))
            let invoked = try await web.evaluateJavaScript("(()=>{let button=Array.from(document.querySelectorAll('button')).find(b=>b.textContent.trim()==='Add one');if(!button)return false;button.click();return true})()") as? Bool
            XCTAssertEqual(invoked,true)
            try await builderWait { ((try? await web.evaluateJavaScript("document.body.innerText")) as? String)?.range(of:"(^|[^0-9])1([^0-9]|$)",options:.regularExpression) != nil }
            let afterValue = try await web.evaluateJavaScript(measure)
            return ["before":before,"after":try XCTUnwrap(afterValue as? [String:Any])]
        }
        observations["createdDOM"] = try await checkCounter()
        phase = "repair"
        var damaged = authoredText
        let fault = "<link rel='stylesheet' href='missing.css'>"
        if let end = damaged.range(of:"</head>",options:.caseInsensitive) { damaged.insert(contentsOf:fault,at:end.lowerBound) }
        else { damaged = fault + "\n" + damaged }
        try Data(damaged.utf8).write(to:entryURL,options:.atomic)
        observations["injectedFaultHTML"] = damaged
        observations["injectedFaultSHA256"] = builderSHA(Data(damaged.utf8))
        let repairStart = chat.current?.messages.count ?? 0
        let repairStreamStart = (observed.snapshot()["streams"] as? [[String:Any]])?.count ?? 0
        let repairPrompt = "The page now has a broken local asset reference. First inspect site/index.html using show_website. Wait for its actual preview feedback before choosing the repair. You must then read site/index.html before writing any repair, because the file has changed since your original save. Use that current source to fix the reported broken reference, preserving the Cedar Expedition heading in blue and the working Add one counter. Save the complete HTML with write_file using replace true. Do not ask a question. Finish after the saved page is clean."
        observations["repairPrompt"] = repairPrompt; chat.draft = repairPrompt; await chat.send(); try await finishTurn()
        let repairMessages = Array((chat.current?.messages ?? []).dropFirst(repairStart))
        XCTAssertTrue(repairMessages.contains { $0.toolName == "show_website" && $0.content.contains("missing.css") && $0.toolUntrustedText == true && $0.toolPrivateDataRead == true })
        XCTAssertTrue(repairMessages.contains { $0.toolName == "read_file" && $0.status == .complete })
        XCTAssertTrue(repairMessages.contains { $0.toolName == "write_file" && $0.status == .complete })
        let repaired = try Data(contentsOf:entryURL)
        XCTAssertFalse(String(decoding:repaired,as:UTF8.self).contains("missing.css")); XCTAssertNotEqual(repaired,Data(damaged.utf8))
        let repairStreams = Array(((observed.snapshot()["streams"] as? [[String:Any]]) ?? []).dropFirst(repairStreamStart))
        let repairUsesObservedFeedback = repairStreams.contains { stream in
            let calls = (stream["reply"] as? [String:Any])?["toolCalls"] as? [[String:Any]] ?? []
            let messages = stream["messages"] as? [[String:String]] ?? []
            return calls.contains { $0["name"] as? String == "write_file" } && messages.contains { $0["role"] == "tool" && $0["content"]?.contains("Missing file: missing.css") == true }
        }
        let repairUsesCurrentSource = repairStreams.contains { stream in
            let calls = (stream["reply"] as? [String:Any])?["toolCalls"] as? [[String:Any]] ?? []
            let messages = stream["messages"] as? [[String:String]] ?? []
            return calls.contains { $0["name"] as? String == "write_file" } && messages.contains { $0["role"] == "tool" && $0["content"] == damaged }
        }
        observations["repairWriteGeneratedAfterActualDiagnostic"] = repairUsesObservedFeedback
        observations["repairWriteGeneratedAfterCurrentFileRead"] = repairUsesCurrentSource
        XCTAssertTrue(repairUsesObservedFeedback)
        XCTAssertTrue(repairUsesCurrentSource)
        try await builderWait {
            guard let value = try? await web.evaluateJavaScript(measure) as? [String:Any], let text = value["text"] as? String else { return false }
            return value["missingReference"] as? Bool == false && text.range(of:"(^|[^0-9])0([^0-9]|$)",options:.regularExpression) != nil
        }
        observations["repairedDOM"] = try await checkCounter(); observations["repairedSHA256"] = builderSHA(repaired)
        XCTAssertTrue(grades.contains { ($0["phase"] as? String) == "repair" && ($0["missing"] as? [String])?.contains("missing.css") == true })
        let last = try XCTUnwrap(grades.last); XCTAssertEqual(last["verdict"] as? String,""); XCTAssertEqual(last["returnedReport"] as? Bool,true)
        let reopened = try ConversationStore(file:conversationFile), stored = await reopened.list()
        let current = try XCTUnwrap(chat.current), persisted = try XCTUnwrap(stored.first { $0.id == current.id })
        XCTAssertEqual(persisted.messages,current.messages)
        let reopenedFolder = try Workspace(root:shared), reopenedBytes = try await reopenedFolder.readCanvas("site/index.html")
        XCTAssertEqual(reopenedBytes,repaired)
        observations["reopenedMessages"] = persisted.messages.count; observations["folderReopenSHA256"] = builderSHA(reopenedBytes)
        completed = chat.error == nil && repairUsesObservedFeedback && repairUsesCurrentSource && grades.contains { ($0["missing"] as? [String])?.contains("missing.css") == true } && !String(decoding:repaired,as:UTF8.self).contains("missing.css") && persisted.messages == current.messages && reopenedBytes == repaired
        await files.revoke()
    }
}
