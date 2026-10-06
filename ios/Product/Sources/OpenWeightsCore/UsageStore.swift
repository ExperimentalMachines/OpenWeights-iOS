import Foundation

public struct UsageMeasurements: Codable, Equatable, Sendable {
    public var promptTokens: Int
    public var generatedTokens: Int
    public var cachedTokens: Int
    public var inferenceMilliseconds: Double
    public var prefillMilliseconds: Double?
    public var decodeMilliseconds: Double?
    public var decodeTokens: Int?
    public var prefillIncludesCompute: Bool?
    public init(promptTokens: Int, generatedTokens: Int, cachedTokens: Int, inferenceMilliseconds: Double,
                prefillMilliseconds: Double? = nil, decodeMilliseconds: Double? = nil, decodeTokens: Int? = nil,
                prefillIncludesCompute: Bool? = nil) {
        self.promptTokens = promptTokens; self.generatedTokens = generatedTokens; self.cachedTokens = cachedTokens
        self.inferenceMilliseconds = inferenceMilliseconds; self.prefillMilliseconds = prefillMilliseconds
        self.decodeMilliseconds = decodeMilliseconds; self.decodeTokens = decodeTokens
        self.prefillIncludesCompute = prefillIncludesCompute
    }
    func validate() throws {
        guard promptTokens >= 0, generatedTokens >= 0, cachedTokens >= 0,
              inferenceMilliseconds.isFinite, inferenceMilliseconds >= 0,
              [prefillMilliseconds, decodeMilliseconds].allSatisfy({ $0.map { $0.isFinite && $0 >= 0 } ?? true }),
              decodeTokens.map({ $0 >= 0 && $0 <= generatedTokens }) ?? true,
              (decodeTokens == nil) == (decodeMilliseconds == nil) else {
            throw ModelError.unsupported("The runtime returned invalid usage measurements. Existing usage was preserved.")
        }
    }
}

public struct UsageRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let day: Int
    public let modelID: UUID
    public let modelName: String
    public let backend: ModelBackend
    public let measurements: UsageMeasurements
    public let weights: UsageWeights?
    public init(id: UUID = UUID(), at: Date = Date(), timeZone: TimeZone = .current, modelID: UUID,
                modelName: String, backend: ModelBackend, measurements: UsageMeasurements, weights: UsageWeights? = nil) {
        self.id = id; self.day = UsageSummary.localDay(at, timeZone: timeZone); self.modelID = modelID
        self.modelName = modelName; self.backend = backend; self.measurements = measurements; self.weights = weights
    }
}

public struct UsageTotals: Equatable, Sendable {
    public var promptTokens: Int64 = 0
    public var generatedTokens: Int64 = 0
    public var cachedTokens: Int64 = 0
    public var inferenceMilliseconds: Double = 0
    public var prefillTokens: Int64 = 0
    public var prefillMilliseconds: Double = 0
    public var decodeTokens: Int64 = 0
    public var decodeMilliseconds: Double = 0
    public var passes = 0
    public var prefillTokensPerSecond: Double? { Self.rate(prefillTokens, prefillMilliseconds) }
    public var decodeTokensPerSecond: Double? { Self.rate(decodeTokens, decodeMilliseconds) }
    private static func rate(_ tokens: Int64, _ milliseconds: Double) -> Double? {
        guard tokens > 0, milliseconds > 0 else { return nil }
        let value = Double(tokens) * 1000 / milliseconds
        return value.isFinite ? value : nil
    }
    mutating func add(_ m: UsageMeasurements, includePrefill: Bool = true, includeInferenceTime: Bool = true) {
        promptTokens = GGUFMemoryPreview.add(promptTokens, Int64(m.promptTokens))
        generatedTokens = GGUFMemoryPreview.add(generatedTokens, Int64(m.generatedTokens))
        cachedTokens = GGUFMemoryPreview.add(cachedTokens, Int64(m.cachedTokens))
        if includeInferenceTime { inferenceMilliseconds += m.inferenceMilliseconds }; passes += 1
        if includePrefill, let time = m.prefillMilliseconds, time > 0, m.promptTokens > 0 {
            prefillTokens = GGUFMemoryPreview.add(prefillTokens, Int64(m.promptTokens)); prefillMilliseconds += time
        }
        if let time = m.decodeMilliseconds, let tokens = m.decodeTokens, time > 0, tokens > 0 {
            decodeTokens = GGUFMemoryPreview.add(decodeTokens, Int64(tokens)); decodeMilliseconds += time
        }
    }
}

public struct UsageGrowthPoint: Equatable, Identifiable, Sendable {
    public let day: Int
    public let generatedTokens: Int64
    public let cumulativeTokens: Int64
    public var id: Int { day }
    public var date: Date { Date(timeIntervalSince1970: Double(day) * 86400) }
}
public struct ModelUsage: Equatable, Identifiable, Sendable {
    public let modelID: UUID
    public let modelName: String
    public let backend: ModelBackend
    public var totals: UsageTotals
    public var id: String { modelID.uuidString + ":" + backend.rawValue }
}
public struct UsageSummary: Equatable, Sendable {
    public var totals = UsageTotals()
    public var activeDays = 0
    public var incompleteMetalTimingPasses = 0
    public var growth: [UsageGrowthPoint] = []
    public var perModel: [ModelUsage] = []
    public var tokensToday: Int64 { growth.last?.generatedTokens ?? 0 }
    public var tokensYesterday: Int64 { growth.dropLast().last?.generatedTokens ?? 0 }
    public var dayOverDayChange: Double? {
        tokensYesterday > 0 ? Double(tokensToday - tokensYesterday) / Double(tokensYesterday) : nil
    }
    public init(records: [UsageRecord] = [], today: Int = localDay(Date()), windowDays: Int = 30) {
        var days: [Int: Int64] = [:]; var models: [String: ModelUsage] = [:]
        for record in records {
            let completeTiming = record.backend != .llamaMetal || record.measurements.prefillIncludesCompute == true
            if !completeTiming { incompleteMetalTimingPasses += 1 }
            totals.add(record.measurements, includePrefill: completeTiming, includeInferenceTime: completeTiming)
            days[record.day] = GGUFMemoryPreview.add(days[record.day] ?? 0, Int64(record.measurements.generatedTokens))
            let key = record.modelID.uuidString + ":" + record.backend.rawValue
            var model = models[key] ?? ModelUsage(modelID: record.modelID, modelName: record.modelName, backend: record.backend, totals: UsageTotals())
            model.totals.add(record.measurements, includePrefill: completeTiming, includeInferenceTime: completeTiming); models[key] = model
        }
        activeDays = days.count
        perModel = models.values.sorted { a, b in
            a.totals.generatedTokens == b.totals.generatedTokens ? a.id < b.id : a.totals.generatedTokens > b.totals.generatedTokens
        }
        guard let oldest = days.keys.min(), let newest = days.keys.max() else { return }
        let end = max(today, newest), start = max(oldest, end - min(366, max(1, windowDays)) + 1)
        var running = days.filter { $0.key < start }.values.reduce(Int64(0), GGUFMemoryPreview.add)
        for day in start...end {
            let tokens = days[day] ?? 0; running = GGUFMemoryPreview.add(running, tokens)
            growth.append(UsageGrowthPoint(day: day, generatedTokens: tokens, cumulativeTokens: running))
        }
    }
    public static func localDay(_ date: Date, timeZone: TimeZone = .current) -> Int {
        var local = Calendar(identifier: .gregorian); local.timeZone = timeZone
        let components = local.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return Int(utc.date(from: components)!.timeIntervalSince1970 / 86400)
    }
}

// Independent from conversations: deleting or branching a transcript cannot
// erase or copy inference that already happened. No message text is recorded.
public actor UsageStore {
    private struct Snapshot: Codable { var version = 1; var records: [UsageRecord] }
    private let file: URL
    private var records: [UsageRecord]
    public init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
            guard snapshot.version == 1 else { throw StoreError.unsupportedVersion(snapshot.version) }
            guard Set(snapshot.records.map(\.id)).count == snapshot.records.count else { throw ModelError.unsupported("The usage ledger repeats a pass. Existing data was preserved.") }
            for row in snapshot.records { try row.measurements.validate(); try row.weights?.validate() }
            guard snapshot.records.allSatisfy({ (-719162...2932896).contains($0.day) }) else {
                throw ModelError.unsupported("The usage ledger has an invalid calendar day. Existing data was preserved.")
            }
            records = snapshot.records
        } else { records = [] }
    }
    public func list() -> [UsageRecord] { records }
    public func summary(at: Date = Date(), timeZone: TimeZone = .current) -> UsageSummary {
        UsageSummary(records: records, today: UsageSummary.localDay(at, timeZone: timeZone))
    }
    public func record(_ row: UsageRecord) throws {
        try row.measurements.validate()
        try row.weights?.validate()
        if let existing = records.first(where: { $0.id == row.id }) {
            guard existing == row else { throw ModelError.unsupported("This inference pass already has different usage measurements.") }
            return
        }
        var next = records; next.append(row)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Snapshot(records: next)).write(to: file, options: .atomic)
        records = next
    }
}
