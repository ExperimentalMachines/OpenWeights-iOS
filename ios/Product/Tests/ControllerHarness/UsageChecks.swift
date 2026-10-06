import Foundation
import OpenWeightsCore

extension ControllerChecks {
@MainActor static func usageChecks(_ passed: inout [String]) async throws {
    let fixture = try Fixture(mode: .read, read: true, write: false, usage: true)
    defer { fixture.cleanup() }
    fixture.files.mode = .auto
    fixture.runtime.usageMetrics = UsageMeasurements(promptTokens: 5, generatedTokens: 20, cachedTokens: 7,
        inferenceMilliseconds: 105, prefillMilliseconds: 10, decodeMilliseconds: 95, decodeTokens: 19)
    try await fixture.loadAndSend()
    try await wait("Usage tool turn did not settle") { !fixture.chat.busy }
    guard let ledger = fixture.chat.usage else { throw CheckFailure("Usage fixture has no ledger") }
    let summary = await ledger.summary()
    try require(summary.totals.passes == 2 && summary.totals.generatedTokens == 40 && summary.totals.promptTokens == 10,
                "Usage did not record both model passes exactly once.")
    try require(summary.totals.decodeTokensPerSecond == 200 && summary.totals.prefillTokensPerSecond == 500,
                "Controller usage changed the measured split.")
    passed.append("usage-records-tool-and-final-passes-with-fresh-prompt-and-weighted-split")
    let original = try await fixture.chat.store.conversation(fixture.chat.current!.id)
    guard let reply = original.messages.last(where: { $0.role == .assistant }) else { throw CheckFailure("No final reply") }
    let branch = try await fixture.chat.store.branch(original.id, through: reply.id)
    try await fixture.chat.store.delete(original.id); try await fixture.chat.store.delete(branch.id)
    let afterDeletion = await ledger.summary()
    try require(afterDeletion == summary, "Branch/delete changed already recorded usage.")
    let reopened = try UsageStore(file: fixture.root.appendingPathComponent("usage.json"))
    let reopenedSummary = await reopened.summary()
    try require(reopenedSummary == summary, "Reopening usage lost totals or backend.")
    passed.append("usage-survives-conversation-branch-delete-and-ledger-reopen")

    let failure = try Fixture(mode: .seeded, write: false, usage: true)
    defer { failure.cleanup() }
    failure.runtime.usageMetrics = fixture.runtime.usageMetrics
    try FileManager.default.createDirectory(at: failure.root.appendingPathComponent("usage.json"), withIntermediateDirectories: false)
    try await failure.loadAndSend(); try await wait("Usage failure blocked chat") { !failure.chat.busy }
    try require(failure.chat.current?.messages.last?.status == .complete && failure.chat.error == nil && failure.chat.usageError != nil,
                "Usage write failure destroyed chat or was hidden.")
    let unrecorded = await failure.chat.usage!.list()
    try require(unrecorded.isEmpty, "Failed ledger write published success.")
    passed.append("usage-write-failure-keeps-chat-functional-and-discloses-missing-measurement")

    let cancelled = try Fixture(mode: .foldingCancelled, write: false, usage: true)
    defer { cancelled.cleanup() }
    cancelled.runtime.usageMetrics = fixture.runtime.usageMetrics
    try await cancelled.loadAndSend(); try await wait("Cancelled usage turn did not settle") { !cancelled.chat.busy }
    let cancelRows = await cancelled.chat.usage!.list()
    try require(cancelRows.count == 1 && cancelled.chat.current?.messages.last?.status == .cancelled,
                "A cancelled reply with measured work disappeared from usage.")
    passed.append("usage-records-returned-cancelled-work-without-claiming-a-complete-reply")

    let folded = try Fixture(mode: .folding, write: false, usage: true)
    defer { folded.cleanup() }
    folded.runtime.usageMetrics = fixture.runtime.usageMetrics
    try await seedLongHistory(folded)
    let originalFoldedHistory = folded.chat.current!.messages
    folded.chat.draft = "Continue with the corrected city."; await folded.chat.send()
    try await wait("Summary accounting did not settle") { !folded.chat.busy }
    let summaryStreams = folded.runtime.captures.filter { $0.messages.last?["content"]?.contains(ConversationCompactor.instruction) == true }
    let foldRows = await folded.chat.usage!.list()
    try require(folded.chat.error == nil && folded.chat.current?.fold?.messageCount == 4 && summaryStreams.count >= 2,
                "Accounting fixture did not execute and commit the segmented summary.")
    try require(foldRows.count == folded.runtime.captures.count && foldRows.count == summaryStreams.count + 1 &&
                foldRows.allSatisfy { $0.measurements == fixture.runtime.usageMetrics },
                "Summary/final passes disappeared or duplicated in the ledger.")
    try require(Array(folded.chat.current!.messages.prefix(4)) == originalFoldedHistory, "Usage accounting changed folded history.")
    passed.append("usage-records-every-segmented-summary-and-final-pass-without-copying-visible-history")

    let watched = try Fixture(mode: .watchReminder, supportsTools: false, write: false, usage: true)
    defer { watched.cleanup() }
    watched.runtime.usageMetrics = fixture.runtime.usageMetrics
    try await watched.loadAndSend(); try await wait("Watch accounting initial chat did not settle") { !watched.chat.busy }
    let conversation = watched.chat.current
    let watch = try await watched.watches.store.start(task: "Remind me to review Cedar", everyMinutes: 1, at: Date().addingTimeInterval(-61))
    let ran = await watched.watches.runBackground(UUID())
    let recorded = await watched.watches.store.watch(watch.id), watchRows = await watched.chat.usage!.list()
    try require(ran && recorded?.runs == 1 && recorded?.history.last?.outcome == .checked && watchRows.count == 2 &&
                watched.chat.current == conversation && !watched.chat.busy,
                "Background-entry watch accounting lost work or changed the conversation.")
    _ = await watched.watches.runBackground(UUID())
    let afterEarly = await watched.chat.usage!.list()
    try require(afterEarly == watchRows, "A not-due watch fabricated usage.")
    let reopenedWatchUsage = try UsageStore(file: watched.root.appendingPathComponent("usage.json"))
    let durableWatchRows = await reopenedWatchUsage.list()
    try require(durableWatchRows == watchRows, "Watch usage did not survive reopen.")
    passed.append("usage-records-due-background-entry-watch-once-keeps-chat-and-no-early-repeat-after-reopen")
}
}
