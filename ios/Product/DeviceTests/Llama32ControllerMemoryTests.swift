import Foundation
import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    func testNativeLlama32ControllerMemoryReadReopenAndToolWithdrawalRecovery() async throws {
        let pinned=NativeLlama32Artifact.selected()
        let sourceRoot=FileManager.default.temporaryDirectory.appendingPathComponent("llama32-download-09E95F55-C323-45F8-9937-737DA72966A2")
        let library=try ModelLibrary(file:sourceRoot.appendingPathComponent("models.json"))
        let models=await library.list()
        var model=try XCTUnwrap(models.first { $0.repository==pinned.repository && $0.revision==pinned.revision && $0.entryFile==pinned.entryFile && $0.state == .ready })
        model.settings.temperature=0;model.settings.topP=1;model.settings.repeatPenalty=1;model.settings.outputTokens=96
        let source=sourceRoot.appendingPathComponent("Models/"+model.id.uuidString)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("llama32-controller-memory-"+UUID().uuidString)
        let suite=root.lastPathComponent,defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        let conversationsFile=root.appendingPathComponent("conversations.json"),memoryFile=root.appendingPathComponent("memory.json")
        let downloads=ModelDownloads(root:root.appendingPathComponent("Models"),library:try ModelLibrary(file:root.appendingPathComponent("models.json")),sessionIdentifier:suite)
        let memory=MemoryController(store:try MemoryStore(file:memoryFile),defaults:defaults)
        let observed=NativeObservedRuntime(try RuntimeFactory.make(model))
        let chat=ChatController(store:try ConversationStore(file:conversationsFile),downloads:downloads,memory:memory,defaults:defaults,runtimeFactory:{ _ in observed })
        var completed=false,actions:[String]=[],checks:[String:Any]=[:],hashes:[String:String]=[:]
        let idle=UIApplication.shared.isIdleTimerDisabled;UIApplication.shared.isIdleTimerDisabled=true
        defer {
            chat.cancel();downloads.cancelAllTransfers();defaults.removePersistentDomain(forName:suite);UIApplication.shared.isIdleTimerDisabled=idle
            let data:[String:Any]=["purpose":"native-llama32-controller-memory-read-reopen-tool-withdrawal","completed":completed,
                "artifact":NativeAgentArtifact.evidence(model),"sourceOwnedRoot":sourceRoot.lastPathComponent,"independentFullFileSHA256":hashes,
                "actions":actions,"checks":checks,"runtimeTrace":observed.snapshot(),"controllerError":chat.error ?? "",
                "operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations":["Actual product controller/RuntimeFactory adapter, memory executor and actor-store reopen with independently verified acquisition-owned bytes. The saved Cedar fact is authored by the fixture, not a model-approved write or user memory.","Controller-generated system instructions and real MemoryToolDefinitions differ from the isolated direct-runtime request. This is not an identical-prompt retry. Full traces retain actual input. Strict earlier Cedar/empty-parameter failures stay preserved.","No native touch/approval gesture, OS process termination/suspension, new weight download, general quality, performance, energy, fit, default selection or A2 replication claim."]]
            let attachment=XCTAttachment(data:try! JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name="Llama32 controller memory flow";attachment.lifetime = .keepAlways;add(attachment)
            if completed { try? FileManager.default.removeItem(at:root) }
        }
        for file in pinned.files {
            let input=try file.destination(in:source),owned=try file.destination(in:downloads.directory(model))
            try await Task.detached { try ModelFileTransfer.verify(input,file:file) }.value
            try FileManager.default.createDirectory(at:owned.deletingLastPathComponent(),withIntermediateDirectories:true)
            try FileManager.default.linkItem(at:input,to:owned)
            hashes[file.path]=try await Task.detached { try ModelFileTransfer.hash(owned) }.value
            XCTAssertEqual(hashes[file.path],file.sha256)
        }
        try await downloads.save(model)
        try await memory.store.remember("My project is Cedar.");await memory.restore();memory.readEnabled=true;memory.writeEnabled=false
        let before=await memory.store.list();let memorySHA=try ModelFileTransfer.hash(memoryFile)
        checks["seededFact"]="My project is Cedar.";checks["sourceLibrarySHA256"]=try ModelFileTransfer.hash(sourceRoot.appendingPathComponent("models.json"))
        await chat.load(model);XCTAssertNil(chat.error);XCTAssertTrue(chat.supportsTools)
        guard chat.error == nil,chat.supportsTools else { return }
        actions.append("load-full-hash-verified-owned-Llama-and-enable-read-only-isolated-memory")
        chat.draft="Use read_memory to find my saved project. Reply with only the project name.";await chat.send()
        try await waitUntil(seconds:120) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertFalse(chat.busy);XCTAssertNil(chat.error);XCTAssertNil(chat.pendingToolApproval)
        if chat.busy { chat.cancel();try await waitUntil(seconds:30) { !chat.busy } }
        let conversation=try XCTUnwrap(chat.current)
        let toolMessages=conversation.messages.filter { $0.role == .tool && $0.toolName == "read_memory" }
        let readSucceeded=toolMessages.contains { $0.status == .complete && $0.content.contains("My project is Cedar.") }
        let answer=conversation.messages.last { $0.role == .assistant }?.content.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        let strict=["Cedar","Cedar."].contains(answer)
        checks["readToolSucceeded"]=readSucceeded;checks["readAnswer"]=answer;checks["strictReadAnswer"]=strict
        checks["rejectedToolResults"]=toolMessages.filter { $0.status == .failed }.map(\.content)
        checks["toolResults"]=toolMessages.map { ["status":$0.status.rawValue,"content":$0.content,"callID":$0.toolCallID ?? ""] }
        let calls=conversation.messages.flatMap { $0.toolCalls ?? [] }
        checks["actualCalls"]=calls.map { ["name":$0.name,"arguments":$0.argumentsJSON] }
        for call in calls where call.name == "read_memory" {
            if let result=toolMessages.first(where:{ $0.toolCallID == call.id && $0.status == .complete }) {
                let arguments=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(call.argumentsJSON.utf8)) as? [String:Any])
                XCTAssertTrue(arguments.isEmpty);XCTAssertTrue(result.content.contains("My project is Cedar."))
            }
        }
        let after=await memory.store.list();XCTAssertEqual(after,before);XCTAssertEqual(try ModelFileTransfer.hash(memoryFile),memorySHA)
        XCTAssertTrue(readSucceeded);XCTAssertTrue(strict)
        actions.append("collect-actual-controller-tool-rounds-and-strict-read-answer-without-writing-fixture-memory")
        let stored=try await ConversationStore(file:conversationsFile).conversation(conversation.id)
        XCTAssertEqual(stored.messages,conversation.messages)
        let reopenedFacts=await (try MemoryStore(file:memoryFile)).list();XCTAssertEqual(reopenedFacts,before)
        await chat.open(stored);XCTAssertNil(chat.error);XCTAssertEqual(chat.current,stored)
        checks["storedMessagesExact"]=stored.messages==conversation.messages
        checks["storedConversationJSON"]=String(data:try JSONEncoder().encode(stored),encoding:.utf8) ?? ""
        actions.append("reopen-exact-tool-history-and-unchanged-memory-actor-stores-in-one-process")
        memory.readEnabled=false
        chat.draft="What is 2 + 2? Reply with only the number.";await chat.send()
        try await waitUntil(seconds:120) { !chat.busy }
        XCTAssertNil(chat.error);XCTAssertNil(chat.pendingToolApproval)
        let recovery=chat.current?.messages.last { $0.role == .assistant }?.content.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        checks["toolWithdrawalRecoveryAnswer"]=recovery;XCTAssertEqual(recovery,"4")
        actions.append("withdraw-memory-tools-and-request-number-only-contextual-recovery")
        completed=readSucceeded && strict && after==before && stored.messages==conversation.messages && chat.error == nil && recovery=="4"
    }
}
