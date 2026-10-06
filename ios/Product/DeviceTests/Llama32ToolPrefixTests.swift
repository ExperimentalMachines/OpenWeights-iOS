import Foundation
import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    func testNativeLlama32RetainedPythonTagParsesAndInvalidReadArgumentsRefuse() async throws {
        let raw=#"<|python_tag|>{"name": "read_memory", "parameters": {"type": "object", "properties": {}}}"#
        let call=try XCTUnwrap(CompiledLlama32ToolReply.parse(raw,offered:["read_memory"])?.calls.first)
        XCTAssertEqual(call.name,"read_memory")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("llama32-prefix-replay-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try MemoryStore(file:root.appendingPathComponent("memory.json"));try await store.remember("Project Cedar")
        let tools=MemoryTools(store:store);var settings=MemoryToolSettings();settings.readEnabled=true
        let rejection=await tools.execute(call,settings:settings)
        XCTAssertTrue(rejection.rejected);XCTAssertFalse(rejection.text.contains("Cedar"))
        XCTAssertEqual(rejection.text,"read_memory requires an empty arguments object. No saved facts were read.")
        let valid=try XCTUnwrap(CompiledLlama32ToolReply.parse(#"<|python_tag|>{"name":"read_memory","parameters":{}}"#,offered:["read_memory"])?.calls.first)
        let accepted=await tools.execute(valid,settings:settings)
        XCTAssertFalse(accepted.rejected);XCTAssertTrue(accepted.text.contains("Project Cedar"))
        let evidence:[String:Any]=["purpose":"native-llama32-retained-python-tag-dispatch-control","raw":raw,"parsedName":call.name,"parsedArguments":call.argumentsJSON,"rejected":rejection.rejected,"result":rejection.text,"validEmptyControlRead":!accepted.rejected,"completed":rejection.rejected && !accepted.rejected,"limitations":["Replays the exact failed native call through the production parser and isolated memory executor. No model inference or user memory read. The valid empty control is authored by the test."]]
        llama32PrefixAttachment(evidence,name:"Llama32 retained prefix dispatch control")
    }

    func testNativeLoadedLlama32PythonTagToolRequestRequiresEmptyParameters() async throws {
        let pinned=NativeLlama32Artifact.selected()
        let roots=try FileManager.default.contentsOfDirectory(at:FileManager.default.temporaryDirectory,includingPropertiesForKeys:nil)
            .filter { $0.lastPathComponent.hasPrefix("llama32-download-") }.sorted { $0.lastPathComponent<$1.lastPathComponent }
        var selected:(LocalModel,URL,URL)?
        for root in roots {
            guard let library=try? ModelLibrary(file:root.appendingPathComponent("models.json")),
                  let model=await library.list().first(where: { $0.repository==pinned.repository && $0.revision==pinned.revision && $0.entryFile==pinned.entryFile && $0.state == .ready }) else { continue }
            selected=(model,root.appendingPathComponent("Models/"+model.id.uuidString),root);break
        }
        let (saved,source,sourceRoot)=try XCTUnwrap(selected)
        var model=saved;model.settings.temperature=0;model.settings.topP=1;model.settings.repeatPenalty=1;model.settings.outputTokens=96
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("llama32-prefix-native-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        var hashes:[String:String]=[:]
        for file in pinned.files {
            let input=try file.destination(in:source),owned=try file.destination(in:root)
            try await Task.detached { try ModelFileTransfer.verify(input,file:file) }.value
            try FileManager.default.createDirectory(at:owned.deletingLastPathComponent(),withIntermediateDirectories:true)
            try FileManager.default.linkItem(at:input,to:owned)
            hashes[file.path]=try await Task.detached { try ModelFileTransfer.hash(owned) }.value
            XCTAssertEqual(hashes[file.path],file.sha256)
        }
        let runtime=NativeObservedRuntime(try RuntimeFactory.make(model))
        let idle=UIApplication.shared.isIdleTimerDisabled;UIApplication.shared.isIdleTimerDisabled=true
        defer { runtime.cancel();UIApplication.shared.isIdleTimerDisabled=idle }
        try await runtime.load(model:model,directory:root)
        let messages=[["role":"system","content":ChatController.systemPrompt],["role":"user","content":"Call read_memory with no parameters to retrieve my saved project name."]]
        let definitions=[AgentToolDefinition(name:"read_memory",description:"Read the user's saved project name.",parametersJSON:"{\"type\":\"object\",\"properties\":{}}")]
        var reply:RuntimeReply?
        for try await event in runtime.stream(messages:messages,settings:model.settings,tools:definitions) { if case .reply(let value)=event { reply=value } }
        let value=try XCTUnwrap(reply)
        let call=try XCTUnwrap(value.toolCalls.first)
        XCTAssertEqual(value.toolCalls.count,1);XCTAssertEqual(call.name,"read_memory")
        XCTAssertFalse(value.cancelled);XCTAssertEqual(value.stopReason,.endOfTurn);XCTAssertEqual(value.cachedTokens,0)
        XCTAssertEqual(value.content,"");XCTAssertTrue((value.promptContent ?? "").hasPrefix("<|python_tag|>"))
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(call.arguments.utf8)) as? [String:Any])
        let strict=object.isEmpty
        let store=try MemoryStore(file:root.appendingPathComponent("memory.json"));try await store.remember("Project Cedar")
        let tools=MemoryTools(store:store);var settings=MemoryToolSettings();settings.readEnabled=true
        let result=await tools.execute(AgentToolCall(id:call.id,name:call.name,argumentsJSON:call.arguments),settings:settings)
        XCTAssertEqual(result.rejected,!strict)
        if !strict { XCTAssertFalse(result.text.contains("Cedar"));XCTAssertEqual(result.text,"read_memory requires an empty arguments object. No saved facts were read.") }
        let evidence:[String:Any]=["purpose":"native-loaded-llama32-python-tag-tool-parameters-control","completed":strict,
            "artifact":NativeAgentArtifact.evidence(model),"sourceOwnedRoot":sourceRoot.lastPathComponent,
            "sourceLibrarySHA256":try ModelFileTransfer.hash(sourceRoot.appendingPathComponent("models.json")),
            "independentFullFileSHA256":hashes,"raw":value.promptContent ?? "","parsedName":call.name,"parsedArguments":call.arguments,
            "emptyParametersMatch":strict,"rejectedByMemoryExecutor":result.rejected,"toolResult":result.text,"runtimeTrace":runtime.snapshot(),
            "operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations":["Actual fresh loaded adapter request using independently verified acquisition-owned bytes, no new weight download. Same original request, schemas and greedy settings.","Isolated memory executor with authored Cedar fixture, not persistent user memory, controller approval or follow-up generation. Recognition of the native prefix is separate from strict empty-parameter acceptance. Initial Cedar failure is retained and not rerun."]]
        llama32PrefixAttachment(evidence,name:"Loaded Llama32 prefix parameters control")
        XCTAssertTrue(strict,"The model must provide empty parameters, not the offered schema.")
    }
    private func llama32PrefixAttachment(_ evidence:[String:Any],name:String) {
        let attachment=XCTAttachment(data:try! JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
    }
}
