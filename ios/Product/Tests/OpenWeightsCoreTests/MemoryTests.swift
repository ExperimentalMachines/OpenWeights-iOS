import XCTest
@testable import OpenWeightsCore

final class MemoryTests: XCTestCase {
    func testReadMemoryRejectsSchemaAsArgumentsBeforeReturningPrivateFacts() async throws {
        let (root,store)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
        try await store.remember("Project Cedar")
        let tools=MemoryTools(store:store);var settings=MemoryToolSettings();settings.readEnabled=true
        let raw=#"<|python_tag|>{"name":"read_memory","parameters":{"type":"object","properties":{}}}"#
        let call=try XCTUnwrap(CompiledLlama32ToolReply.parse(raw,offered:["read_memory"])?.calls.first)
        let rejected=await tools.execute(call,settings:settings)
        XCTAssertTrue(rejected.rejected);XCTAssertFalse(rejected.text.contains("Cedar"))
        XCTAssertEqual(rejected.text,"read_memory requires an empty arguments object. No saved facts were read.")
        let valid=AgentToolCall(id:"valid",name:"read_memory",argumentsJSON:"{}")
        let result=await tools.execute(valid,settings:settings)
        XCTAssertFalse(result.rejected);XCTAssertTrue(result.text.contains("Project Cedar"))
    }
    private func fixture() throws -> (URL, MemoryStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (root, try MemoryStore(file: root.appendingPathComponent("memory.json")))
    }
    func testNormalizationDedupeAgeAndReopen() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.remember("  Prefers\nbrief answers  ", now: Date(timeIntervalSince1970: 100))
        try await store.remember("prefers brief answers")
        let before = await store.list()
        XCTAssertEqual(before.count, 1)
        try await store.replace(old: "brief answers", new: "Prefers detailed answers")
        let reopened = try MemoryStore(file: root.appendingPathComponent("memory.json"))
        let after = await reopened.list()
        XCTAssertEqual(after.first?.savedAt, before.first?.savedAt)
        XCTAssertEqual(after.first?.id, before.first?.id)
        XCTAssertEqual(after.first?.text, "Prefers detailed answers")
    }
    func testBudgetsProtectEditedFactAndBoundFactCount() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.remember("old")
        for index in 1...6 { try await store.remember(String(repeating: String(index), count: 150)) }
        try await store.replace(old: "old", new: String(repeating: "z", count: 160))
        let facts = await store.list()
        XCTAssertEqual(facts.first?.text, String(repeating: "z", count: 160))
        XCTAssertLessThanOrEqual(facts.reduce(0, { $0 + $1.text.utf16.count }), 1000)
        try await store.forgetAll()
        for index in 0..<25 { try await store.remember("fact \(index)") }
        let capped = await store.list()
        XCTAssertEqual(capped.count, 24)
        XCTAssertEqual(capped.first?.text, "fact 1")
        do { try await store.remember(String(repeating: "🧠", count: 81)); XCTFail("UTF-16 budget was not enforced") }
        catch { XCTAssertTrue(error is MemoryError) }
    }
    func testAmbiguousMatchesRejectWithoutQuotingSavedFacts() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.remember("Keeps two cats")
        try await store.remember("Likes black cats")
        do { try await store.forget("cats"); XCTFail("Ambiguous deletion should fail") }
        catch {
            XCTAssertFalse(error.localizedDescription.contains("Keeps"))
            XCTAssertFalse(error.localizedDescription.contains("Likes"))
        }
        try await store.forget("keeps two cats")
        let facts = await store.list()
        XCTAssertEqual(facts.map(\.text), ["Likes black cats"])
    }
    func testEveryToolWriteRequiresOneMatchingApprovalAndReadHasSeparateSwitch() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = MemoryTools(store: store)
        var settings = MemoryToolSettings()
        let call = AgentToolCall(id: "call-1", name: "save_memory", argumentsJSON: "{\"fact\":\"Prefers tea\"}")
        let disabled = await tools.execute(call, settings: settings, approval: ApprovedToolCall(displayedCall: call))
        XCTAssertTrue(disabled.rejected)
        settings.writeEnabled = true
        let unapproved = await tools.execute(call, settings: settings)
        XCTAssertTrue(unapproved.rejected)
        let approval = ApprovedToolCall(displayedCall: call)
        let changed = AgentToolCall(id: call.id, name: call.name, argumentsJSON: "{\"fact\":\"Prefers coffee\"}")
        let mismatch = await tools.execute(changed, settings: settings, approval: approval)
        XCTAssertTrue(mismatch.rejected)
        let allowed = await tools.execute(call, settings: settings, approval: approval)
        XCTAssertFalse(allowed.rejected)
        let reused = await tools.execute(call, settings: settings, approval: approval)
        XCTAssertTrue(reused.rejected)
        let read = AgentToolCall(id: "read", name: "read_memory", argumentsJSON: "{}")
        let privateRead = await tools.execute(read, settings: settings)
        XCTAssertTrue(privateRead.rejected)
        XCTAssertFalse(privateRead.text.contains("tea"))
        settings.readEnabled = true
        let visible = await tools.execute(read, settings: settings)
        XCTAssertTrue(visible.text.contains("Prefers tea"))
    }
    func testFailedWriteLeavesMemoryUnchangedAndCorruptionIsPreserved() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("memory.json")
        try await store.remember("A saved fact")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        do { try await store.remember("Another fact"); XCTFail("Write should fail") } catch {}
        let kept = await store.list()
        XCTAssertEqual(kept.map(\.text), ["A saved fact"])
        try FileManager.default.removeItem(at: file)
        let corrupt = Data("broken JSON".utf8)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try MemoryStore(file: file))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
    func testManualIdentityEditPreservesAgeBudgetAndDuplicateRules() async throws {
        let (root,store)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
        try await store.remember("First",now:Date(timeIntervalSince1970:100))
        try await store.remember("Second",now:Date(timeIntervalSince1970:200))
        let before=await store.list(),selected=before[0]
        try await store.replace(id:selected.id,expectedText:selected.text,new:"  Edited\nfirst  ")
        let after=await store.list();XCTAssertEqual(after[0].id,selected.id);XCTAssertEqual(after[0].savedAt,selected.savedAt);XCTAssertEqual(after[0].text,"Edited first")
        let reopened=try MemoryStore(file:root.appendingPathComponent("memory.json"));let durable=await reopened.list();XCTAssertEqual(durable,after)
        try await store.replace(id:selected.id,expectedText:after[0].text,new:"SECOND")
        let deduped=await store.list();XCTAssertEqual(deduped,[before[1]])
        for index in 0..<6 { try await store.remember(String(repeating:String(index),count:150)) }
        let protected=await store.list()[0];try await store.replace(id:protected.id,expectedText:protected.text,new:String(repeating:"z",count:160))
        let budgeted=await store.list();XCTAssertTrue(budgeted.contains { $0.id == protected.id && $0.savedAt == protected.savedAt });XCTAssertLessThanOrEqual(budgeted.reduce(0) { $0+$1.text.utf16.count },1000)
    }
    func testStaleManualRowsCannotMutateSubstringMatches() async throws {
        let (root,store)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
        try await store.remember("Cedar");let selected=await store.list()[0]
        try await store.replace(old:"Cedar",new:"Pine");try await store.remember("Cedar backup")
        let before=await store.list()
        do { try await store.replace(id:selected.id,expectedText:selected.text,new:"Oak");XCTFail("Stale manual edit was admitted") } catch MemoryError.changedFact { }
        let preserved=await store.list();XCTAssertEqual(preserved,before)
        try await store.forget(id:selected.id);let remaining=await store.list()
        do { try await store.forget(id:selected.id);XCTFail("Missing selected ID fell back to another fact") } catch MemoryError.missingFact { }
        let final=await store.list();XCTAssertEqual(final,remaining);XCTAssertEqual(final.map(\.text),["Cedar backup"])
    }
    func testManualWriteFailuresLeaveActorAndDiskUnchanged() async throws {
        let (root,store)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
        try await store.remember("Keep");let before=await store.list(),fact=before[0],file=root.appendingPathComponent("memory.json"),bytes=try Data(contentsOf:file)
        try FileManager.default.removeItem(at:file);try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
        do { try await store.replace(id:fact.id,expectedText:fact.text,new:"Lost");XCTFail("Failed store committed edit") } catch { }
        do { try await store.forget(id:fact.id);XCTFail("Failed store committed delete") } catch { }
        let after=await store.list();XCTAssertEqual(after,before)
        try FileManager.default.removeItem(at:file);try bytes.write(to:file)
        let reopened=try MemoryStore(file:file);let durable=await reopened.list();XCTAssertEqual(durable,before)
    }

    func testEditorAndStoreUseTheSameNormalizedUTF16Budget() async throws {
        let (root,store)=try fixture();defer { try? FileManager.default.removeItem(at:root) }
        let raw=String(repeating:" ",count:180)+"Cedar\n\tproject"+String(repeating:" ",count:180)
        let normalized=MemoryStore.normalizedFact(raw)
        XCTAssertEqual(normalized,"Cedar project");XCTAssertEqual(normalized.utf16.count,13)
        try await store.remember(raw);let saved=await store.list();XCTAssertEqual(saved.first?.text,normalized)
        XCTAssertTrue(MemoryStore.normalizedFact(" \n \t").isEmpty)
        XCTAssertEqual(MemoryStore.normalizedFact(String(repeating:"🧠",count:80)).utf16.count,MemoryStore.maximumFactCharacters)
        XCTAssertGreaterThan(MemoryStore.normalizedFact(String(repeating:"🧠",count:81)).utf16.count,MemoryStore.maximumFactCharacters)
    }

}
