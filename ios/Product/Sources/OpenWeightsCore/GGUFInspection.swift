import Foundation

public protocol GGUFByteSource: Sendable {
    func read(offset: Int64, length: Int) async throws -> Data
}

public struct GGUFMetadata: Equatable, Sendable {
    public let architecture: String
    public let name: String?
    public let modelType: String?
    public let splitCount: Int?
    public let blocks: Int
    public let embedding: Int
    public let heads: Int
    public let kvHeads: [Int]
    public let keyWidth: Int
    public let valueWidth: Int
    public let trainingContext: Int
    public let fileType: Int?
    public let tensorCount: Int64
    public let stoppedAtTokenizer: Bool
    public let fetchedBytes: Int
    public func standaloneIssue(registeredArchitectures: Set<String>) -> String? {
        if tensorCount == 0 { return "This file has no model tensors." }
        if let splitCount, splitCount > 1 { return "This file belongs to a split model. Complete shard imports are not yet supported." }
        if let modelType, modelType != "model" { return "This GGUF is a \(modelType), not a standalone model." }
        if !registeredArchitectures.contains(architecture) { return "The linked engine does not recognize the \(architecture) architecture." }
        return nil
    }
    public func f16KVBytes(context: Int) -> Int64? {
        guard context > 0, blocks > 0, kvHeads.count == blocks, heads > 0,
              keyWidth > 0, valueWidth > 0 else { return nil }
        let total = kvHeads.reduce(Int64(0)) { GGUFMemoryPreview.add($0, Int64($1)) }
        return [total, Int64(keyWidth) + Int64(valueWidth), Int64(context), 2].reduce(1, GGUFMemoryPreview.multiply)
    }
}

public struct GGUFMemoryPreview: Equatable, Sendable {
    public let weightBytes: Int64?
    public let kvBytes: Int64?
    public let weightsAndKVBytes: Int64?
    public let headroomBytes: Int64?
    public let storageBytes: Int64?
    public let exceedsCurrentHeadroom: Bool
    public let insufficientStorage: Bool
    public init(metadata: GGUFMetadata, weightBytes: Int64?, context: Int, headroomBytes: Int64?, storageBytes: Int64?) {
        let weights = weightBytes.flatMap { $0 > 0 ? $0 : nil }
        let cache = metadata.f16KVBytes(context: context)
        let required = weights.flatMap { weight in cache.map { Self.add(weight, $0) } }
        let headroom = headroomBytes.flatMap { $0 > 0 ? $0 : nil }
        let storage = storageBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.weightBytes = weights; kvBytes = cache; weightsAndKVBytes = required
        self.headroomBytes = headroom; self.storageBytes = storage
        exceedsCurrentHeadroom = required.flatMap { required in headroom.map { required > $0 } } ?? false
        // A download stages one range alongside the growing owned file.
        insufficientStorage = weights.flatMap { weight in storage.map { Self.add(weight, min(weight, 32 * 1024 * 1024)) > $0 } } ?? false
    }
    static func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        guard lhs >= 0, rhs >= 0 else { return Int64.max }
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
    static func multiply(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        guard lhs >= 0, rhs >= 0 else { return Int64.max }
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}

public enum GGUFFileName {
    public static func exclusion(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        guard name.hasSuffix(".gguf") else { return "This file is not GGUF." }
        if name.hasPrefix("mmproj") { return "A projector must be paired with its base model." }
        if name.hasPrefix("mtp-") { return "A draft module is not a standalone chat model." }
        if name.range(of: "-[0-9]+-of-[0-9]+\\.gguf$", options: .regularExpression) != nil { return "Split GGUF files require their complete shard set." }
        if name.hasSuffix("-lora.gguf") || name.hasSuffix("-vocab.gguf") { return "An adapter or vocabulary is not a standalone chat model." }
        return nil
    }
    public static func quantization(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let expression = try! NSRegularExpression(pattern: "(?:^|-)(I?Q[0-9][a-z0-9_]*|B?F16|F32)\\.gguf$", options: [.caseInsensitive])
        let source = name as NSString
        guard let match = expression.firstMatch(in: name, range: NSRange(location: 0, length: source.length)) else { return nil }
        return source.substring(with: match.range(at: 1)).uppercased()
    }
}

public struct GGUFHeaderParser: Sendable {
    private let source: any GGUFByteSource
    private let windowBytes: Int
    public init(source: any GGUFByteSource, windowBytes: Int = 128 * 1024) { self.source = source; self.windowBytes = windowBytes }
    public func parse() async throws -> GGUFMetadata {
        guard (1...1_048_576).contains(windowBytes) else { throw ModelError.unsupported("The header read window is invalid.") }
        let reader = GGUFWindowReader(source: source, window: windowBytes)
        guard try await reader.bytes(4) == Data("GGUF".utf8) else { throw ModelError.unsupported("This file has no GGUF header.") }
        let version = try await reader.unsigned(4)
        // The linked llama.cpp loader itself rejects GGUF v1 and foreign byte order.
        guard version == 2 || version == 3 else { throw ModelError.unsupported("This build inspects little-endian GGUF v2 and v3. Convert older or differently encoded files first.") }
        let tensors = try await reader.count()
        let entries = try await reader.count()
        guard entries <= 4096 else { throw ModelError.unsupported("The GGUF metadata entry count exceeds the inspection limit.") }
        var values: [String: GGUFValue] = [:]
        var stopped = false
        for _ in 0..<entries {
            try Task.checkCancellation()
            let key = try await reader.string()
            if key.hasPrefix("tokenizer.") { stopped = true; break }
            guard values[key] == nil else { throw ModelError.unsupported("The GGUF header repeats a metadata key.") }
            values[key] = try await reader.value(type: reader.unsigned(4))
        }
        guard case .text(let architecture)? = values["general.architecture"], !architecture.isEmpty,
              architecture.utf8.count <= 128 else { throw ModelError.unsupported("The inspected header has no valid model architecture before its tokenizer.") }
        func number(_ key: String) throws -> Int? {
            guard let value = values[key] else { return nil }
            guard case .integer(let number) = value, (0...1_000_000_000).contains(number) else { throw ModelError.unsupported("The GGUF field \(key) is not a supported nonnegative integer.") }
            return Int(number)
        }
        let blocks = try number(architecture + ".block_count") ?? 0
        guard blocks <= 10_000 else { throw ModelError.unsupported("The GGUF block count exceeds the inspection limit.") }
        let embedding = try number(architecture + ".embedding_length") ?? 0
        let heads = try number(architecture + ".attention.head_count") ?? 0
        var kv: [Int] = []
        switch values[architecture + ".attention.head_count_kv"] {
        case .integer(let count):
            guard (0...1_000_000_000).contains(count) else { throw ModelError.unsupported("The GGUF KV head count is invalid.") }
            kv = Array(repeating: Int(count), count: blocks)
        case .array(let values):
            guard values.count == blocks else { throw ModelError.unsupported("Per-layer KV head counts do not match the GGUF block count.") }
            for value in values {
                guard case .integer(let count) = value, (0...1_000_000_000).contains(count) else { throw ModelError.unsupported("A per-layer GGUF KV count is invalid.") }
                kv.append(Int(count))
            }
        case nil: kv = Array(repeating: heads, count: blocks)
        default: throw ModelError.unsupported("The GGUF KV head array is not inspectable.")
        }
        let keyWidth = try number(architecture + ".attention.key_length") ?? (heads > 0 ? embedding / heads : 0)
        let valueWidth = try number(architecture + ".attention.value_length") ?? keyWidth
        let contexts = try [number(architecture + ".context_length"), number(architecture + ".rope.scaling.original_context_length")].compactMap { $0 }.filter { $0 > 0 }
        let name: String?
        if case .text(let value)? = values["general.name"] { name = value } else { name = nil }
        let modelType: String?
        if case .text(let value)? = values["general.type"] { modelType = value } else { modelType = nil }
        return GGUFMetadata(architecture: architecture, name: name, modelType: modelType, splitCount: try number("split.count"), blocks: blocks, embedding: embedding, heads: heads,
            kvHeads: kv, keyWidth: keyWidth, valueWidth: valueWidth, trainingContext: contexts.min() ?? 0,
            fileType: try number("general.file_type"), tensorCount: tensors, stoppedAtTokenizer: stopped, fetchedBytes: reader.fetched)
    }
}

private indirect enum GGUFValue { case integer(Int64), text(String), array([GGUFValue]), skipped }
private final class GGUFWindowReader {
    private let source: any GGUFByteSource
    private let window: Int
    private var data = Data()
    private var start: Int64 = 0
    private var position: Int64 = 0
    private var strings = 0
    private var arrayElements = 0
    private var requested = 0
    private(set) var fetched = 0
    init(source: any GGUFByteSource, window: Int) { self.source = source; self.window = window }
    func bytes(_ length: Int) async throws -> Data {
        try Task.checkCancellation()
        guard length >= 0, length <= 1_048_576 else { throw ModelError.unsupported("A GGUF value exceeds its byte limit.") }
        let end = position.addingReportingOverflow(Int64(length))
        guard !end.overflow else { throw ModelError.unsupported("The GGUF offset overflows.") }
        if position < start || end.partialValue > start + Int64(data.count) {
            let request = max(window, length)
            guard position <= Int64.max - Int64(request) else { throw ModelError.unsupported("The GGUF read window offset overflows.") }
            guard requested <= 16 * 1024 * 1024 - request else { throw ModelError.unsupported("The GGUF header exceeds the 16 MiB inspection read budget.") }
            requested += request
            data = try await source.read(offset: position, length: request)
            try Task.checkCancellation()
            start = position
            guard data.count <= request, data.count >= length else { throw ModelError.unsupported("The GGUF header response is oversized or truncated.") }
            fetched += data.count
        }
        let offset = Int(position - start)
        position = end.partialValue
        return data.subdata(in: offset..<(offset + length))
    }
    func unsigned(_ length: Int) async throws -> UInt64 {
        let bytes = try await bytes(length)
        return bytes.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
    }
    func count() async throws -> Int64 {
        let value = try await unsigned(8)
        guard value <= UInt64(Int64.max) else { throw ModelError.unsupported("The GGUF count exceeds its supported range.") }
        return Int64(value)
    }
    func string() async throws -> String {
        let length = try await count()
        guard length <= 1_048_576, strings <= 4 * 1024 * 1024 - Int(length) else { throw ModelError.unsupported("The GGUF header exceeds its string budget.") }
        strings += Int(length)
        guard let value = String(data: try await bytes(Int(length)), encoding: .utf8) else { throw ModelError.unsupported("The GGUF header contains invalid UTF-8.") }
        return value
    }
    func value(type: UInt64, depth: Int = 0) async throws -> GGUFValue {
        switch type {
        case 0, 7: return .integer(Int64(try await unsigned(1)))
        case 1: return .integer(Int64(Int8(bitPattern: UInt8(try await unsigned(1)))))
        case 2: return .integer(Int64(try await unsigned(2)))
        case 3: return .integer(Int64(Int16(bitPattern: UInt16(try await unsigned(2)))))
        case 4: return .integer(Int64(try await unsigned(4)))
        case 5: return .integer(Int64(Int32(bitPattern: UInt32(try await unsigned(4)))))
        case 6: _ = try await bytes(4); return .skipped
        case 8: return .text(try await string())
        case 9:
            guard depth == 0 else { throw ModelError.unsupported("Nested GGUF metadata arrays are unsupported.") }
            let element = try await unsigned(4), count = try await count()
            let widths: [UInt64: Int64] = [0:1,1:1,2:2,3:2,4:4,5:4,6:4,7:1,10:8,11:8,12:8]
            guard element != 9, widths[element] != nil || element == 8 else { throw ModelError.unsupported("The GGUF array type is unsupported.") }
            if count <= 4096 {
                guard arrayElements <= 16_384 - Int(count) else { throw ModelError.unsupported("The GGUF header exceeds its retained array limit.") }
                arrayElements += Int(count)
                var values: [GGUFValue] = []
                for _ in 0..<count { values.append(try await value(type: element, depth: depth + 1)) }
                return .array(values)
            }
            guard let width = widths[element] else { throw ModelError.unsupported("A GGUF text array exceeds the inspection limit.") }
            let size = width.multipliedReportingOverflow(by: count)
            let end = position.addingReportingOverflow(size.partialValue)
            guard !size.overflow, !end.overflow else { throw ModelError.unsupported("A GGUF array offset overflows.") }
            position = end.partialValue
            return .skipped
        case 10: return .integer(try await count())
        case 11: return .integer(Int64(bitPattern: try await unsigned(8)))
        case 12: _ = try await bytes(8); return .skipped
        default: throw ModelError.unsupported("The GGUF metadata type is unsupported.")
        }
    }
}
