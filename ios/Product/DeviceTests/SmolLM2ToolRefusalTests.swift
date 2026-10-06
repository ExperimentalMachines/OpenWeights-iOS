import Foundation
import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    func testNativeLoadedSmolLM2ToolsRefuseCountingWarmingAndGeneration() async throws {
        let pinned=NativeSmolLM2Artifact.selected()
        let roots=try FileManager.default.contentsOfDirectory(at:FileManager.default.temporaryDirectory,includingPropertiesForKeys:nil)
            .filter { $0.lastPathComponent.hasPrefix("smollm2-download-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var selected: (LocalModel,URL,URL)?
        for root in roots {
            guard let library=try? ModelLibrary(file:root.appendingPathComponent("models.json")),
                  let model=await library.list().first(where: { $0.repository == pinned.repository && $0.revision == pinned.revision && $0.entryFile == pinned.entryFile && $0.state == .ready }) else { continue }
            selected=(model,root.appendingPathComponent("Models/"+model.id.uuidString),root);break
        }
        let (saved,source,sourceRoot)=try XCTUnwrap(selected)
        var model=saved;model.settings.temperature=0;model.settings.topP=1;model.settings.repeatPenalty=1;model.settings.outputTokens=96
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("smollm2-tool-refusal-"+UUID().uuidString)
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
        XCTAssertFalse(runtime.supportsTools);XCTAssertFalse(runtime.supportsReasoningEffort)
        let messages=[["role":"system","content":ChatController.systemPrompt],["role":"user","content":"Read my saved project name."]]
        let tools=[AgentToolDefinition(name:"read_memory",description:"Read saved facts",parametersJSON:"{}")]
        let size=try await runtime.promptSize(messages:messages,settings:model.settings,tools:[])
        XCTAssertTrue(size.exact);XCTAssertGreaterThan(size.tokens,0)
        var errors:[String:String]=[:]
        do { _=try await runtime.promptSize(messages:messages,settings:model.settings,tools:tools);XCTFail("Enabled tools must refuse counting.") }
        catch { errors["count"]=error.localizedDescription }
        do { try await runtime.warm(messages:messages,settings:model.settings,tools:tools);XCTFail("Enabled tools must refuse warming.") }
        catch { errors["warm"]=error.localizedDescription }
        var generatedEvents=0
        do {
            for try await _ in runtime.stream(messages:messages,settings:model.settings,tools:tools) { generatedEvents+=1 }
            XCTFail("Enabled tools must refuse generation.")
        } catch { errors["stream"]=error.localizedDescription }
        XCTAssertEqual(generatedEvents,0)
        XCTAssertEqual(errors["count"],"This compiled template does not support enabled tools. Turn the tools off or select a tool-capable model.")
        XCTAssertEqual(errors["warm"],"This compiled model cannot exchange supported tool calls and results.")
        XCTAssertEqual(errors["stream"],"This compiled model cannot exchange supported tool calls and results.")
        let evidence:[String:Any]=["purpose":"native-loaded-smollm2-tools-refusal","completed":errors.count==3 && generatedEvents==0,
            "artifact":NativeAgentArtifact.evidence(model),"sourceOwnedRoot":sourceRoot.lastPathComponent,
            "sourceLibrarySHA256":try ModelFileTransfer.hash(sourceRoot.appendingPathComponent("models.json")),
            "independentFullFileSHA256":hashes,"errors":errors,"toolFreePromptTokens":size.tokens,"toolFreeCountExact":size.exact,
            "generatedEvents":generatedEvents,"runtimeTrace":runtime.snapshot(),"operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations":["Actual loaded product adapter with independently verified retained acquisition-owned bytes. No new network transfer or successful tool generation.","Direct API refusal and exact token count, not controller/touch/accessibility or requested-answer quality acceptance. Initial three strict answer failures remain unchanged."]]
        let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name="Loaded SmolLM2 tool refusal";attachment.lifetime = .keepAlways;add(attachment)
    }
}
