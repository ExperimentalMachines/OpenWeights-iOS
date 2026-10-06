import Foundation
import OpenWeightsCore

extension ControllerChecks {
    @MainActor static func memoryEditingChecks(_ passed:inout [String]) async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("memory-edit-checks-"+UUID().uuidString)
        let suite="memory-edit-checks-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("memory.json"),store=try MemoryStore(file:file),memory=MemoryController(store:store,defaults:defaults)
        try require(await memory.save("Cedar"),"Manual add failed")
        let selected=memory.facts[0]
        try require(await memory.save("Pine",replacing:selected),"Manual identity edit failed")
        let edited=memory.facts[0]
        try require(edited.id==selected.id && edited.savedAt==selected.savedAt && edited.text=="Pine" && !memory.writeEnabled,"Manual edit changed ID/age or required agent write access")
        passed.append("manual-memory-edit-with-agent-switch-off-preserves-ID-and-age")
        try require(await memory.save("Cedar backup"),"Second fact failed")
        let before=memory.facts
        try require(!(await memory.save("Oak",replacing:selected)) && memory.facts==before && memory.error != nil,"Stale selected edit changed another fact")
        passed.append("manual-memory-stale-edit-refuses-without-text-query-fallback")
        await memory.delete(edited);let remaining=memory.facts
        await memory.delete(selected)
        try require(memory.facts==remaining && remaining.map(\.text)==["Cedar backup"] && memory.error != nil,"Stale delete changed a substring match")
        passed.append("manual-memory-stale-delete-keeps-unrelated-substring-fact")
        let blank = await memory.save("\n ",replacing:remaining[0]), oversized = await memory.save(String(repeating:"🧠",count:81),replacing:remaining[0])
        try require(!blank && !oversized && memory.facts==remaining,"Invalid manual edit changed saved facts")
        passed.append("manual-memory-invalid-edit-preserves-existing-facts-and-reports-errors")
        let snapshot=try Data(contentsOf:file)
        try FileManager.default.removeItem(at:file);try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
        try require(!(await memory.save("Lost",replacing:remaining[0])) && memory.facts==remaining,"Failed manual commit changed controller state")
        await memory.delete(remaining[0]);try require(memory.facts==remaining && memory.error != nil,"Failed delete changed state")
        await memory.deleteAll();try require(memory.facts==remaining && memory.error != nil,"Failed clear changed state")
        try FileManager.default.removeItem(at:file);try snapshot.write(to:file)
        passed.append("manual-memory-edit-delete-clear-failures-preserve-controller-and-file-snapshot")
        let reopened=MemoryController(store:try MemoryStore(file:file),defaults:defaults);await reopened.restore()
        try require(reopened.facts==remaining,"Memory controller reopen differs")
        await reopened.deleteAll();let empty=try MemoryStore(file:file)
        try require(await empty.list().isEmpty && reopened.facts.isEmpty && reopened.error == nil,"Manual clear failed durable reopening")
        passed.append("manual-memory-controller-reopen-and-clear-all-durability")
    }
}
