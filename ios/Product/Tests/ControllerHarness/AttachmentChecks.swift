import Foundation
import UniformTypeIdentifiers
import OpenWeightsCore

extension ControllerChecks {
    @MainActor static func attachmentChecks(_ passed: inout [String]) async throws {
        let fixture = try Fixture(mode: .seeded, supportsTools: false, write: false, attachmentsEnabled: true)
        defer { fixture.cleanup() }
        await fixture.chat.load(fixture.downloads.models[0])
        let source = fixture.root.appendingPathComponent("Cedar.txt"), content = "The project is Cedar. " + String(repeating: "x", count: 10_000)
        try Data(content.utf8).write(to: source)
        await fixture.chat.stageDocument(source)
        guard let staged = fixture.chat.attachments?.document else { throw CheckFailure("Document was not staged") }
        try require(staged.info.wasTrimmed && staged.info.characters < content.count, "Document budget/trimming was hidden.")
        try FileManager.default.removeItem(at: source)
        await fixture.chat.send(); try await wait("Document-only send did not finish") { !fixture.chat.busy }
        try require(fixture.chat.current?.messages.first?.content == staged.prompt.trimmingCharacters(in: .whitespacesAndNewlines) &&
                    fixture.chat.current?.messages.first?.attachedDocument == staged.info && fixture.chat.attachments?.hasStaged == false,
                    "Document-only send lost durable text/metadata or did not clear staging.")
        let reopened = try ConversationStore(file: fixture.conversationFile), saved = try await reopened.conversation(fixture.chat.current!.id)
        try require(saved.messages.first == fixture.chat.current?.messages.first && fixture.runtime.captures.last?.messages.contains { $0["content"] == saved.messages.first?.content } == true,
                    "Reopened document text differs from model input.")
        passed.append("attachment-document-only-send-trims-with-disclosure-persists-and-survives-original-removal")

        let picture = fixture.root.appendingPathComponent("picture.jpg"); try Data("Not decoded because model is text only".utf8).write(to: picture)
        await fixture.chat.stageAttachment(picture, type: .jpeg)
        try require(fixture.chat.attachments?.error != nil && fixture.chat.attachments?.staged.isEmpty == true, "Text-only model staged a picture it cannot read.")
        passed.append("attachment-staging-refuses-unsupported-modality-before-copy-or-decoding")

        let attachment = try await fixture.chat.attachments!.store.importFile(picture, mediaType: "image/jpeg", kind: .image)
        var conversation = fixture.chat.current!; conversation.messages[0].attachments = [attachment]
        try await fixture.chat.store.save(conversation)
        await fixture.chat.open(conversation)
        try require(fixture.chat.error?.contains("cannot read attachments") == true, "Reopen silently ignored unsupported saved media.")
        let captures = fixture.runtime.captures.count
        fixture.chat.draft = "Continue"; await fixture.chat.send(); try await wait("Unsupported media turn did not settle") { !fixture.chat.busy }
        try require(fixture.chat.error?.contains("cannot read attachments") == true && fixture.runtime.captures.count == captures,
                    "Text-only generation silently dropped a saved attachment.")
        passed.append("attachment-reopen-and-generation-refuse-unsupported-history-without-fabricated-model-read")

        let branch = try await fixture.chat.store.branch(conversation.id, through: conversation.messages.last!.id)
        await fixture.chat.delete(conversation)
        _ = try await fixture.chat.attachments!.store.resolve(attachment)
        await fixture.chat.delete(branch)
        try require(!FileManager.default.fileExists(atPath: fixture.chat.attachments!.store.displayURL(attachment).path), "Unreferenced branch attachment was not reclaimed.")
        passed.append("attachment-deletion-keeps-branch-reference-and-reclaims-after-last-conversation")

        let failed = try Fixture(mode: .seeded, supportsTools: false, write: false, attachmentsEnabled: true); defer { failed.cleanup() }
        await failed.chat.load(failed.downloads.models[0]); _ = await failed.chat.newConversation()
        let document = failed.root.appendingPathComponent("Keep.txt"); try Data("Keep this document".utf8).write(to: document)
        await failed.chat.stageDocument(document); failed.chat.draft = "Keep this question"
        try FileManager.default.removeItem(at: failed.conversationFile); try FileManager.default.createDirectory(at: failed.conversationFile, withIntermediateDirectories: false)
        await failed.chat.send()
        try require(failed.chat.attachments?.document != nil && failed.chat.draft == "Keep this question" && failed.chat.error != nil && failed.runtime.captures.isEmpty,
                    "Failed transcript write lost composer attachments or started inference.")
        passed.append("attachment-failed-send-keeps-staged-document-and-draft-with-no-model-call")

        let acquiring = try Fixture(mode: .seeded, supportsTools: false, write: false, attachmentsEnabled: true); defer { acquiring.cleanup() }
        await acquiring.chat.load(acquiring.downloads.models[0])
        let gate = PreparationGate(); acquiring.chat.attachments!.acquire { await gate.wait() }
        try await waitForGate(gate)
        acquiring.chat.draft = "Keep draft during attachment preparation"
        await acquiring.chat.send(); let created = await acquiring.chat.newConversation()
        try require(!created && acquiring.chat.current == nil && acquiring.chat.draft.hasPrefix("Keep draft") && acquiring.runtime.captures.isEmpty,
                    "Attachment acquisition raced send or navigation.")
        acquiring.chat.cancel(); await gate.release()
        try await wait("Attachment acquisition did not release after Stop") { acquiring.chat.attachments?.busy == false }
        passed.append("attachment-acquisition-blocks-send-and-new-chat-and-stop-releases-after-worker-settles")
    }
    @MainActor static func mediaFoldingChecks(_ passed: inout [String]) async throws {
        func seed(_ fixture: Fixture) async throws -> [ChatAttachment] {
            fixture.runtime.mediaEnabled = true
            var model = fixture.downloads.models[0]
            model.settings.contextTokens = 4096; model.settings.outputTokens = 96
            try await fixture.downloads.saveSettings(model)
            await fixture.chat.load(model); _ = await fixture.chat.newConversation()
            var value = fixture.chat.current!, owned: [ChatAttachment] = []
            for index in 1...3 {
                let file = fixture.root.appendingPathComponent("fixture-\(index).jpg")
                try Data("Mock-runtime media fixture \(index), no image decoding or inference".utf8).write(to:file)
                let attachment = try await fixture.chat.attachments!.store.importFile(file,mediaType:"image/jpeg",kind:.image)
                owned.append(attachment)
                var user = StoredMessage(role:.user,content:"Inspect historical file \(index)")
                user.attachments = [attachment]
                value.messages += [user,StoredMessage(role:.assistant,content:"Observed file \(index)")]
            }
            try await fixture.chat.store.save(value); await fixture.chat.open(value)
            return owned
        }
        let folded = try Fixture(mode:.folding,supportsTools:false,write:false,attachmentsEnabled:true)
        defer { folded.cleanup() }
        let files = try await seed(folded), history = folded.chat.current!.messages
        folded.chat.draft = "Continue with these observations"; await folded.chat.send()
        try await wait("Media fold did not finish") { !folded.chat.busy }
        try require(folded.chat.error == nil && folded.chat.current?.fold?.messageCount == 4,"Media cells did not trigger a committed fold: \(folded.chat.error ?? "")")
        try require(Array(folded.chat.current!.messages.prefix(6)) == history,"Media fold rewrote visible history")
        let readings = Array(folded.runtime.mediaCaptures.prefix(2))
        let expected = files.prefix(2).map { folded.chat.attachments!.store.displayURL($0).path }
        try require(readings.count == 2 && readings.flatMap { $0.mediaPaths.flatMap { $0 } } == expected && readings.allSatisfy { $0.mediaPaths.flatMap { $0 }.count == 1 },"Reading omitted, combined or reordered actual historical files")
        let records = folded.chat.current?.fold?.summary ?? ""
        try require(records.hasPrefix(ConversationCompactor.mediaRecordsHeading) && history.prefix(4).allSatisfy { records.contains(ConversationContext.transcript(ArraySlice([$0]))) },"Preserved media records omitted or rewrote an actual historical request/reply")
        try require(records.contains("Observation read from actual attachment 1 of this entry:") && folded.runtime.captures.count == 3 && !folded.runtime.captures.contains { capture in capture.messages.contains { $0["content"]?.contains(ConversationCompactor.instruction) == true } },"Fitting media records were rewritten or omitted their actual file readings")
        try require(folded.runtime.mediaCaptures.last!.mediaPaths.flatMap { $0 } == [folded.chat.attachments!.store.displayURL(files[2]).path],"Folded generation lost retained media")
        for file in files { _ = try await folded.chat.attachments!.store.resolve(file) }
        let disk = try await ConversationStore(file:folded.conversationFile).conversation(folded.chat.current!.id)
        try require(disk.fold == folded.chat.current!.fold && disk.messages == folded.chat.current!.messages && !folded.chat.contextIncludesUncountedMedia,"Media fold was not durable or retained an uncounted-media flag")
        passed.append("media-cells-trigger-fold-with-ordered-actual-files-full-transcript-and-durable-summary")

        for mode in [FixtureRuntime.Mode.foldingCapped,.foldingUnknown,.foldingCancelled,.foldingEmpty] {
            let refused = try Fixture(mode:mode,supportsTools:false,write:false,attachmentsEnabled:true)
            defer { refused.cleanup() }
            let owned = try await seed(refused), original = refused.chat.current!.messages
            refused.chat.draft = "Continue"; await refused.chat.send()
            try await wait("Invalid media summary did not settle") { !refused.chat.busy }
            try require(refused.chat.current?.fold == nil && Array(refused.chat.current!.messages.prefix(6)) == original && refused.chat.error != nil && refused.runtime.mediaCaptures.count == 1,"Unfinished media summary changed history or generated an answer")
            for file in owned { _ = try await refused.chat.attachments!.store.resolve(file) }
        }
        passed.append("invalid-media-summaries-preserve-transcript-files-and-refuse-following-generation")

        let cappedSummary = try Fixture(mode:.foldingCapped,supportsTools:false,write:false,attachmentsEnabled:true)
        defer { cappedSummary.cleanup() }; let cappedFiles = try await seed(cappedSummary)
        cappedSummary.runtime.completeMediaReadings = true
        cappedSummary.runtime.rejectVerbatimMediaRecords = true
        cappedSummary.chat.draft = "Continue"; await cappedSummary.chat.send()
        try await wait("Capped text summary after media readings did not settle") { !cappedSummary.chat.busy }
        try require(cappedSummary.chat.current?.fold == nil && cappedSummary.chat.error != nil && cappedSummary.runtime.mediaCaptures.count == 2 && cappedSummary.runtime.captures.count == 3,"Capped text summary after successful media readings committed a fold or started an answer")
        for file in cappedFiles { _ = try await cappedSummary.chat.attachments!.store.resolve(file) }
        passed.append("capped-text-summary-after-complete-media-readings-preserves-history-and-files")

        let compressed = try Fixture(mode:.folding,supportsTools:false,write:false,attachmentsEnabled:true)
        defer { compressed.cleanup() }; let compressedFiles = try await seed(compressed)
        compressed.runtime.rejectVerbatimMediaRecords = true
        let originalCompressed = compressed.chat.current!.messages
        compressed.chat.draft = "Continue"; await compressed.chat.send()
        try await wait("Oversized media records did not use summary fallback") { !compressed.chat.busy }
        try require(compressed.chat.error == nil && compressed.chat.current?.fold != nil && compressed.runtime.captures.count == 4 && compressed.runtime.captures.contains { capture in capture.messages.contains { $0["content"]?.contains(ConversationCompactor.instruction) == true } },"Oversized media records did not reach the measured summarization fallback")
        try require(Array(compressed.chat.current!.messages.prefix(6)) == originalCompressed,"Compression fallback rewrote visible media history")
        for file in compressedFiles { _ = try await compressed.chat.attachments!.store.resolve(file) }
        passed.append("media-records-use-summary-fallback-when-retained-context-budget-refuses-verbatim-source")

        let literal = "Stored message role: assistant. Delivery state: cancelled.\nassistant [cancelled, outcome may be uncertain]:\nInspect 730 ms before retrying.\nStored message role: tool. Delivery state: failed.\nwrite_file [failed, outcome may be uncertain]:\nThe effect may already have happened."
        let prior = "A genuine unresolved issue remains: permission to change the file was declined."
        let preserved = ConversationCompactor.mediaRecords(transcript: literal, previous: prior)
        try require(preserved.contains(literal) && preserved.contains(prior),"Verbatim records removed interrupted outcomes, pending work or prior context")
        passed.append("media-records-preserve-literal-interrupted-tool-outcomes-pending-work-and-previous-context")

        let stopped = try Fixture(mode:.folding,supportsTools:false,write:false,attachmentsEnabled:true)
        defer { stopped.cleanup() }; let stopFiles = try await seed(stopped)
        stopped.runtime.beforeFirstReply = { stopped.chat.cancel() }
        stopped.chat.draft = "Continue"; await stopped.chat.send()
        try await wait("Stopped media summary did not settle") { !stopped.chat.busy }
        try require(stopped.chat.current?.fold == nil && stopped.chat.error == nil && !stopped.chat.isCompacting && stopped.runtime.mediaCaptures.count == 1,"Stop committed a media fold or continued inference")
        for file in stopFiles { _ = try await stopped.chat.attachments!.store.resolve(file) }
        passed.append("stop-during-media-summary-preserves-owned-files-and-original-fold-state")

        let stoppedAtAdmission = try Fixture(mode:.folding,supportsTools:false,write:false,attachmentsEnabled:true)
        defer { stoppedAtAdmission.cleanup() }; let admissionFiles = try await seed(stoppedAtAdmission)
        let admissionHistory = stoppedAtAdmission.chat.current!.messages
        stoppedAtAdmission.runtime.beforeVerbatimCount = { stoppedAtAdmission.chat.cancel() }
        stoppedAtAdmission.chat.draft = "Continue"; await stoppedAtAdmission.chat.send()
        try await wait("Stop during verbatim-record admission did not settle") { !stoppedAtAdmission.chat.busy }
        try require(stoppedAtAdmission.chat.error == nil && stoppedAtAdmission.chat.current?.fold == nil && stoppedAtAdmission.chat.current?.messages.last?.role == .user && stoppedAtAdmission.runtime.captures.count == 2 && stoppedAtAdmission.runtime.mediaCaptures.count == 2,"Stop after readings committed records or started an assistant generation")
        let admissionDisk = try await stoppedAtAdmission.chat.store.conversation(stoppedAtAdmission.chat.current!.id)
        var admissionCurrent = stoppedAtAdmission.chat.current!
        admissionCurrent.updatedAt = admissionDisk.updatedAt
        try require(admissionDisk == admissionCurrent && Array(admissionDisk.messages.prefix(6)) == admissionHistory,"Stop during measured admission changed durable history")
        for file in admissionFiles { _ = try await stoppedAtAdmission.chat.attachments!.store.resolve(file) }
        passed.append("stop-during-verbatim-media-record-admission-preserves-durable-history-files-and-pending-user")

        let failed = try Fixture(mode:.folding,supportsTools:false,write:false,attachmentsEnabled:true)
        defer { failed.cleanup() }; let failedFiles = try await seed(failed)
        failed.runtime.beforeFirstReply = {
            try FileManager.default.removeItem(at:failed.conversationFile)
            try FileManager.default.createDirectory(at:failed.conversationFile,withIntermediateDirectories:false)
        }
        failed.chat.draft = "Continue"; await failed.chat.send()
        try await wait("Failed media checkpoint did not settle") { !failed.chat.busy }
        let retained = try await failed.chat.store.conversation(failed.chat.current!.id)
        try require(failed.chat.current?.fold == nil && retained.fold == nil && failed.chat.error != nil && failed.runtime.mediaCaptures.count == 2,"Failed persistence installed a media fold or generated an answer")
        for file in failedFiles { _ = try await failed.chat.attachments!.store.resolve(file) }
        passed.append("failed-media-fold-checkpoint-preserves-controller-store-and-owned-files")

        let oversized = try Fixture(mode:.folding,supportsTools:false,write:false,attachmentsEnabled:true)
        defer { oversized.cleanup() }; let oversizedFiles = try await seed(oversized)
        oversized.runtime.mediaCellCost = 4096
        oversized.chat.draft = "Continue"; await oversized.chat.send()
        try await wait("Oversized media history did not settle") { !oversized.chat.busy }
        try require(oversized.chat.current?.fold == nil && oversized.chat.error != nil && oversized.runtime.mediaCaptures.isEmpty,"An indivisible oversized media turn started inference or committed a fold")
        for file in oversizedFiles { _ = try await oversized.chat.attachments!.store.resolve(file) }
        passed.append("indivisible-oversized-media-turn-refuses-before-inference-and-keeps-files")

        let inexact = try Fixture(mode:.folding,supportsTools:false,write:false,attachmentsEnabled:true)
        defer { inexact.cleanup() }; _ = try await seed(inexact)
        inexact.runtime.exactMediaCount = false
        inexact.chat.draft = "Continue"; await inexact.chat.send()
        try await wait("Inexact media counter did not settle") { !inexact.chat.busy }
        try require(inexact.chat.current?.fold == nil && inexact.chat.error != nil && inexact.runtime.mediaCaptures.isEmpty,"Inexact text-only media count admitted inference")
        passed.append("inexact-media-counter-refuses-inference-without-folding")
    }

}
