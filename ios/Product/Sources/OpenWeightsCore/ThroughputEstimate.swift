import Foundation
import CryptoKit

// File bytes are an approximation of work per token, not a model-size or chip
// guarantee. Bind the size to known weight hashes so replaced files cannot reuse
// a measurement recorded for different weights under the same library ID.
public struct UsageWeights: Codable, Equatable, Sendable {
    public let bytes: Int64
    public let manifestSHA256: String
    public init?(model: LocalModel) {
        guard model.state == .ready else { return nil }
        let files = Self.files(model).sorted { $0.path < $1.path }
        guard !files.isEmpty, Set(files.map(\.path)).count == files.count else { return nil }
        var total: Int64 = 0
        var manifest: [[String: String]] = []
        for file in files {
            guard (try? ModelFile.validatePath(file.path)) != nil, let size = file.bytes, size > 0,
                  let hash = file.sha256?.lowercased(), Self.validHash(hash) else { return nil }
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
            manifest.append(["path": file.path, "bytes": String(size), "sha256": hash])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]) else { return nil }
        bytes = total
        manifestSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func files(_ model: LocalModel) -> [ModelFile] {
        model.files.filter { file in
            switch model.backend {
            case .llamaCPU, .llamaMetal: return file.path.lowercased().hasSuffix(".gguf")
            case .mlx: return file.path.lowercased().hasSuffix(".safetensors")
            case .xnnpack, .executorchMLX: return ["pte", "ptd"].contains((file.path as NSString).pathExtension.lowercased())
            }
        }
    }
    static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func validate() throws {
        guard bytes > 0, Self.validHash(manifestSHA256) else {
            throw ModelError.unsupported("The usage ledger has invalid weight metadata. Existing data was preserved.")
        }
    }
}

public struct ThroughputCalibration: Equatable, Sendable {
    public let modelID: UUID
    public let modelName: String
    public let backend: ModelBackend
    public let weights: UsageWeights
    public let tokens: Int64
    public let milliseconds: Double
    public let passes: Int
    public var measuredTokensPerSecond: Double { Double(tokens) * 1000 / milliseconds }
    public func predict(weightBytes: Int64, backend: ModelBackend) -> Double? {
        guard backend == self.backend, weightBytes > 0 else { return nil }
        let rate = measuredTokensPerSecond * (Double(weights.bytes) / Double(weightBytes))
        return rate.isFinite && rate > 0 ? rate : nil
    }
}

public struct ThroughputEstimates: Equatable, Sendable {
    public let prefill: ThroughputCalibration?
    public let decode: ThroughputCalibration?
    // Supply files verified at runtime load or filtered by a current storage
    // snapshot. Persisted ready metadata alone does not establish file presence.
    public init(records: [UsageRecord], installed: [LocalModel], backend: ModelBackend) {
        var known: [UUID: (LocalModel, UsageWeights)] = [:]
        for model in installed {
            let sameFormat = model.backend == backend ||
                ([ModelBackend.llamaCPU, .llamaMetal].contains(model.backend) && [.llamaCPU, .llamaMetal].contains(backend))
            if sameFormat, let weights = UsageWeights(model: model) { known[model.id] = (model, weights) }
        }
        var work: [UUID: UsageTotals] = [:]
        for row in records {
            guard row.backend == backend, let (_, weights) = known[row.modelID], row.weights == weights,
                  (try? row.measurements.validate()) != nil else { continue }
            let completeTiming = backend != .llamaMetal || row.measurements.prefillIncludesCompute == true
            var totals = work[row.modelID] ?? UsageTotals()
            totals.add(row.measurements, includePrefill: completeTiming, includeInferenceTime: completeTiming); work[row.modelID] = totals
        }
        func choose(prefill: Bool) -> ThroughputCalibration? {
            let candidates = work.compactMap { id, totals -> ThroughputCalibration? in
                guard let (model, weights) = known[id] else { return nil }
                let tokens = prefill ? totals.prefillTokens : totals.decodeTokens
                let time = prefill ? totals.prefillMilliseconds : totals.decodeMilliseconds
                guard tokens > 0, time > 0, time.isFinite else { return nil }
                let value = ThroughputCalibration(modelID: id, modelName: model.name, backend: backend,
                    weights: weights, tokens: tokens, milliseconds: time, passes: totals.passes)
                guard value.measuredTokensPerSecond.isFinite, value.measuredTokensPerSecond > 0 else { return nil }
                return value
            }
            return candidates.sorted {
                $0.tokens == $1.tokens ? $0.modelID.uuidString < $1.modelID.uuidString : $0.tokens > $1.tokens
            }.first
        }
        prefill = choose(prefill: true); decode = choose(prefill: false)
    }
}
