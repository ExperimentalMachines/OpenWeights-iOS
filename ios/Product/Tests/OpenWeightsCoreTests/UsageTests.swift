import XCTest
@testable import OpenWeightsCore

final class UsageTests: XCTestCase {
    private let model = UUID()
    private func row(day: Int, generated: Int, prompt: Int = 0, prefill: Double? = nil, decode: Double? = nil, decoded: Int? = nil, backend: ModelBackend = .llamaCPU) -> UsageRecord {
        UsageRecord(at: Date(timeIntervalSince1970: Double(day) * 86400), timeZone: TimeZone(secondsFromGMT: 0)!,
            modelID: model, modelName: "Cedar", backend: backend,
            measurements: UsageMeasurements(promptTokens: prompt, generatedTokens: generated, cachedTokens: 400,
                inferenceMilliseconds: (prefill ?? 0) + (decode ?? 0), prefillMilliseconds: prefill,
                decodeMilliseconds: decode, decodeTokens: decoded))
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testWeightedSplitUsesTotalWorkAndOmitsUnknownAndZeroIntervals() {
        let slow = row(day: 1, generated: 1001, prompt: 2000, prefill: 100000, decode: 100000, decoded: 1000)
        let fast = row(day: 2, generated: 11, prompt: 20, prefill: 1000, decode: 1000, decoded: 10)
        let legacy = row(day: 2, generated: 500, prompt: 300)
        let one = row(day: 2, generated: 1, prompt: 0, prefill: 1000, decode: 0, decoded: 0)
        let summary = UsageSummary(records: [slow, fast, legacy, one], today: 2)
        XCTAssertEqual(summary.totals.decodeTokensPerSecond, 10)
        XCTAssertEqual(summary.totals.prefillTokensPerSecond, 20)
        XCTAssertEqual(summary.totals.generatedTokens, 1513); XCTAssertEqual(summary.totals.promptTokens, 2320)
        XCTAssertEqual(summary.totals.cachedTokens, 1600); XCTAssertEqual(summary.totals.passes, 4)
        XCTAssertNil(UsageSummary(records: [legacy, one], today: 2).totals.decodeTokensPerSecond)
    }
    func testGrowthFillsQuietDaysCarriesOldHistoryAndRunsToToday() {
        let summary = UsageSummary(records: [row(day: 1, generated: 10000), row(day: 40, generated: 500), row(day: 41, generated: 500)], today: 42, windowDays: 4)
        XCTAssertEqual(summary.growth.map(\.day), [39,40,41,42])
        XCTAssertEqual(summary.growth.map(\.generatedTokens), [0,500,500,0])
        XCTAssertEqual(summary.growth.map(\.cumulativeTokens), [10000,10500,11000,11000])
        XCTAssertEqual(summary.tokensToday, 0); XCTAssertEqual(summary.tokensYesterday, 500)
        XCTAssertEqual(summary.dayOverDayChange, -1); XCTAssertEqual(summary.activeDays, 3)
        XCTAssertTrue(UsageSummary().growth.isEmpty)
        XCTAssertNil(UsageSummary(records: [row(day: 3, generated: 20)], today: 3).dayOverDayChange)
    }
    func testBackendsRemainSeparateAndFutureClockRowsAreRetained() {
        let summary = UsageSummary(records: [row(day: 12, generated: 50), row(day: 12, generated: 70, backend: .mlx)], today: 10)
        XCTAssertEqual(summary.perModel.count, 2); XCTAssertEqual(summary.perModel.first?.backend, .mlx)
        XCTAssertEqual(summary.growth.last?.day, 12); XCTAssertEqual(summary.totals.generatedTokens, 120)
    }
    func testLocalDayUsesCalendarDateAcrossMidnightAndDaylightSaving() {
        let parser = ISO8601DateFormatter()
        let utc = TimeZone(secondsFromGMT: 0)!, manila = TimeZone(identifier: "Asia/Manila")!, la = TimeZone(identifier: "America/Los_Angeles")!
        let date = parser.date(from: "2026-10-04T16:01:00Z")!
        XCTAssertEqual(UsageSummary.localDay(date, timeZone: manila), UsageSummary.localDay(date, timeZone: utc) + 1)
        let first = parser.date(from: "2026-03-08T09:30:00Z")!, second = parser.date(from: "2026-03-08T10:30:00Z")!
        XCTAssertEqual(UsageSummary.localDay(first, timeZone: la), UsageSummary.localDay(second, timeZone: la))
    }
    func testLedgerReopenDeduplicatesExactPassAndRejectsConflict() async throws {
        let file = try temporary().appendingPathComponent("usage.json"), ledger = try UsageStore(file: file)
        let original = row(day: 1, generated: 50)
        try await ledger.record(original); let bytes = try Data(contentsOf: file)
        try await ledger.record(original); XCTAssertEqual(try Data(contentsOf: file), bytes)
        let reopened = try UsageStore(file: file); let reopenedRows = await reopened.list(); XCTAssertEqual(reopenedRows, [original])
        let conflict = UsageRecord(id: original.id, at: Date(timeIntervalSince1970: 86400), timeZone: TimeZone(secondsFromGMT: 0)!, modelID: model,
            modelName: "Changed", backend: .mlx, measurements: original.measurements)
        do { try await ledger.record(conflict); XCTFail("Conflicting pass accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let json = String(data: bytes, encoding: .utf8)!; XCTAssertFalse(json.contains("content")); XCTAssertFalse(json.contains("messages"))
    }
    func testInvalidMetricsAndFailedWritePreserveMemoryAndBytes() async throws {
        let root = try temporary(), file = root.appendingPathComponent("usage.json"), ledger = try UsageStore(file: file)
        let original = row(day: 1, generated: 1); try await ledger.record(original)
        let bytes = try Data(contentsOf: file)
        for metrics in [UsageMeasurements(promptTokens: -1, generatedTokens: 2, cachedTokens: 0, inferenceMilliseconds: 1),
                        UsageMeasurements(promptTokens: 1, generatedTokens: 2, cachedTokens: 0, inferenceMilliseconds: .nan),
                        UsageMeasurements(promptTokens: 1, generatedTokens: 2, cachedTokens: 0, inferenceMilliseconds: 1, decodeMilliseconds: 1, decodeTokens: 3)] {
            do { try await ledger.record(UsageRecord(modelID: model, modelName: "Cedar", backend: .llamaCPU, measurements: metrics)); XCTFail("Invalid metrics accepted") } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do { try await ledger.record(row(day: 2, generated: 2)); XCTFail("Failed write exposed success") } catch {}
        let after = await ledger.list(); XCTAssertEqual(after, [original])
    }
    func testUnreadableVersionAndCorruptionNeverOverwriteLedger() throws {
        let file = try temporary().appendingPathComponent("usage.json")
        for bytes in [Data("broken".utf8), Data("{\"version\":99,\"records\":[]}".utf8)] {
            try bytes.write(to: file); XCTAssertThrowsError(try UsageStore(file: file)); XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }
    func testActualDiskBytesIncludePartialAndOrphansButExcludeSymlinkTargets() async throws {
        let root = try temporary(), outside = try temporary()
        var model = LocalModel(name: "Paused Cedar", backend: .llamaCPU, entryFile: "model.gguf", files: [ModelFile(path: "model.gguf", bytes: 999999)])
        model.state = .paused
        let directory = root.appendingPathComponent(model.id.uuidString); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: directory.appendingPathComponent("model.gguf.partial"))
        try Data(repeating: 2, count: 7).write(to: root.appendingPathComponent("orphan"))
        try Data(repeating: 3, count: 500).write(to: outside.appendingPathComponent("private"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("external"), withDestinationURL: outside)
        let snapshot = try await ModelStorageInspector().snapshot(root: root, models: [model])
        XCTAssertEqual(snapshot.ownedBytes, 107); XCTAssertEqual(snapshot.unlistedBytes, 7)
        XCTAssertEqual(snapshot.rows[0].incompleteBytes, 100); XCTAssertEqual(snapshot.rows[0].declaredFileBytes, 0)
        XCTAssertNil(snapshot.rows[0].metadata)
        let link = outside.appendingPathComponent("root-link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        do { _ = try await ModelStorageInspector().snapshot(root: link, models: [model]); XCTFail("Linked root accepted") } catch {}
    }
}
