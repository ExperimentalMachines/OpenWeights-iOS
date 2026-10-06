import XCTest
@testable import OpenWeightsCore

private actor HeaderBytes: GGUFByteSource {
    let data: Data
    private(set) var requests: [(Int64, Int)] = []
    let oversized: Bool
    let cancelled: Bool
    init(_ data: Data, oversized: Bool = false, cancelled: Bool = false) { self.data = data; self.oversized = oversized; self.cancelled = cancelled }
    func read(offset: Int64, length: Int) async throws -> Data {
        requests.append((offset, length))
        if cancelled { throw CancellationError() }
        if oversized { return Data(repeating: 0, count: length + 1) }
        guard offset < data.count else { return Data() }
        return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + length))
    }
}
private enum HeaderFixture {
    static func integer(_ value: UInt64, bytes: Int = 8) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func string(_ value: String) -> Data { integer(UInt64(value.utf8.count)) + Data(value.utf8) }
    static func text(_ key: String, _ value: String) -> Data { string(key) + integer(8, bytes: 4) + string(value) }
    static func number(_ key: String, _ value: UInt64) -> Data { string(key) + integer(4, bytes: 4) + integer(value, bytes: 4) }
    static func array(_ key: String, _ values: [UInt64]) -> Data { string(key) + integer(9, bytes: 4) + integer(4, bytes: 4) + integer(UInt64(values.count)) + values.reduce(Data()) { $0 + integer($1, bytes: 4) } }
    static func file(_ entries: [Data], version: UInt64 = 3) -> Data { Data("GGUF".utf8) + integer(version, bytes: 4) + integer(200) + integer(UInt64(entries.count)) + entries.reduce(Data(), +) }
    static var qwen: [Data] { [text("general.architecture", "qwen3"), text("general.name", "Cedar Qwen"), number("qwen3.block_count", 28), number("qwen3.embedding_length", 1024), number("qwen3.attention.head_count", 16), number("qwen3.attention.head_count_kv", 8), number("qwen3.attention.key_length", 128), number("qwen3.attention.value_length", 128), number("qwen3.context_length", 40960), number("qwen3.rope.scaling.original_context_length", 32768)] }
}
final class GGUFInspectionTests: XCTestCase {
    func testStandaloneAdmissionRefusesUnregisteredSplitAndAdapterHeaders() async throws {
        let normal = try await GGUFHeaderParser(source: HeaderBytes(HeaderFixture.file(HeaderFixture.qwen))).parse()
        XCTAssertNil(normal.standaloneIssue(registeredArchitectures: ["qwen3"]))
        XCTAssertNotNil(normal.standaloneIssue(registeredArchitectures: ["llama"]))
        for entries in [HeaderFixture.qwen + [HeaderFixture.number("split.count", 2)], HeaderFixture.qwen + [HeaderFixture.text("general.type", "adapter")]] {
            let metadata = try await GGUFHeaderParser(source: HeaderBytes(HeaderFixture.file(entries))).parse()
            XCTAssertNotNil(metadata.standaloneIssue(registeredArchitectures: ["qwen3"]))
        }
        let zeroTensors = Data("GGUF".utf8) + HeaderFixture.integer(3, bytes: 4) + HeaderFixture.integer(0) + HeaderFixture.integer(1) + HeaderFixture.text("general.architecture", "qwen3")
        let metadata = try await GGUFHeaderParser(source: HeaderBytes(zeroTensors)).parse()
        XCTAssertNotNil(metadata.standaloneIssue(registeredArchitectures: ["qwen3"]))
    }
    func testQwenHeadWidthsAndOriginalContextAreReadBeforeTokenizerWithoutVocabularyFetch() async throws {
        let tokenizerTail: Data = HeaderFixture.string("tokenizer.ggml.tokens") + Data(repeating: 255, count: 20)
        let bytes = HeaderFixture.file(HeaderFixture.qwen + [tokenizerTail])
        let source = HeaderBytes(bytes)
        let metadata = try await GGUFHeaderParser(source: source, windowBytes: 32).parse()
        XCTAssertEqual(metadata.architecture, "qwen3"); XCTAssertEqual(metadata.name, "Cedar Qwen")
        XCTAssertEqual(metadata.keyWidth, 128); XCTAssertEqual(metadata.valueWidth, 128)
        XCTAssertEqual(metadata.trainingContext, 32768); XCTAssertEqual(metadata.kvHeads.count, 28)
        XCTAssertEqual(metadata.f16KVBytes(context: 2048), 234_881_024)
        XCTAssertTrue(metadata.stoppedAtTokenizer); XCTAssertNil(metadata.fileType)
        let requests = await source.requests
        XCTAssertLessThan(requests.last!.0, Int64(bytes.count)); XCTAssertLessThanOrEqual(metadata.fetchedBytes, requests.reduce(0) { $0 + $1.1 })
    }
    func testHybridPerLayerHeadsAndMissingWidthsUseCorrectDefaults() async throws {
        let source = HeaderBytes(HeaderFixture.file([HeaderFixture.text("general.architecture", "lfm2"), HeaderFixture.number("lfm2.block_count", 3), HeaderFixture.number("lfm2.embedding_length", 1024), HeaderFixture.number("lfm2.attention.head_count", 8), HeaderFixture.array("lfm2.attention.head_count_kv", [0, 2, 0]), HeaderFixture.number("lfm2.context_length", 16384)]))
        let metadata = try await GGUFHeaderParser(source: source, windowBytes: 8).parse()
        XCTAssertEqual(metadata.kvHeads, [0, 2, 0]); XCTAssertEqual(metadata.keyWidth, 128)
        XCTAssertEqual(metadata.f16KVBytes(context: 2048), 2_097_152)
        XCTAssertFalse(metadata.stoppedAtTokenizer)
    }
    func testMissingGeometryIsUnknownAndMemoryMathSaturatesWithoutFalseFit() async throws {
        let source = HeaderBytes(HeaderFixture.file([HeaderFixture.text("general.architecture", "mamba")]))
        let metadata = try await GGUFHeaderParser(source: source).parse()
        XCTAssertNil(metadata.f16KVBytes(context: 2048))
        let unknown = GGUFMemoryPreview(metadata: metadata, weightBytes: nil, context: 2048, headroomBytes: 0, storageBytes: nil)
        XCTAssertNil(unknown.weightsAndKVBytes); XCTAssertNil(unknown.headroomBytes); XCTAssertFalse(unknown.insufficientStorage)
        let known = try await GGUFHeaderParser(source: HeaderBytes(HeaderFixture.file(HeaderFixture.qwen))).parse()
        let preview = GGUFMemoryPreview(metadata: known, weightBytes: Int64.max, context: Int.max, headroomBytes: 1_000, storageBytes: Int64.max - 1)
        XCTAssertEqual(preview.weightsAndKVBytes, Int64.max); XCTAssertTrue(preview.exceedsCurrentHeadroom); XCTAssertTrue(preview.insufficientStorage)
        let normal = GGUFMemoryPreview(metadata: known, weightBytes: 396_705_472, context: 2048, headroomBytes: 1_000_000_000, storageBytes: 396_705_472)
        XCTAssertEqual(normal.weightsAndKVBytes, 631_586_496); XCTAssertFalse(normal.exceedsCurrentHeadroom); XCTAssertTrue(normal.insufficientStorage)
    }
    func testBadMagicVersionsUTF8CountsTypesDuplicatesAndLayerArraysRefuse() async throws {
        let invalid: [Data] = [Data("not a header".utf8), HeaderFixture.file(HeaderFixture.qwen, version: 1), HeaderFixture.file(HeaderFixture.qwen, version: 4), HeaderFixture.file([HeaderFixture.string("general.architecture") + HeaderFixture.integer(8, bytes: 4) + HeaderFixture.integer(1) + Data([255])]), HeaderFixture.file([HeaderFixture.text("general.architecture", "qwen3"), HeaderFixture.text("general.architecture", "llama")]), HeaderFixture.file([HeaderFixture.text("general.architecture", "qwen3"), HeaderFixture.number("qwen3.block_count", 10001)]), HeaderFixture.file([HeaderFixture.text("general.architecture", "qwen3"), HeaderFixture.number("qwen3.block_count", 2), HeaderFixture.array("qwen3.attention.head_count_kv", [1])]), HeaderFixture.file([HeaderFixture.string("bad") + HeaderFixture.integer(99, bytes: 4)]), Data("GGUF".utf8) + HeaderFixture.integer(3, bytes: 4) + HeaderFixture.integer(200) + HeaderFixture.integer(4097)]
        for bytes in invalid {
            do { _ = try await GGUFHeaderParser(source: HeaderBytes(bytes), windowBytes: 16).parse(); XCTFail("Invalid header was accepted") } catch {}
        }
    }
    func testTruncationOversizedResponsesAndCancellationRefuseBeforeLaterReads() async throws {
        for length in [0, 3, 8, 20] {
            do { _ = try await GGUFHeaderParser(source: HeaderBytes(HeaderFixture.file(HeaderFixture.qwen).prefix(length))).parse(); XCTFail("Truncated header accepted") } catch {}
        }
        do { _ = try await GGUFHeaderParser(source: HeaderBytes(Data(), oversized: true)).parse(); XCTFail("Oversized window accepted") } catch {}
        let cancelled = HeaderBytes(Data(), cancelled: true)
        do { _ = try await GGUFHeaderParser(source: cancelled).parse(); XCTFail("Canceled header accepted") } catch is CancellationError {} catch { XCTFail("Wrong error") }
        let calls = await cancelled.requests; XCTAssertEqual(calls.count, 1)
    }
    func testNestedArrayHugeStringsAndUnsignedOverflowAreRefused() async throws {
        let key = HeaderFixture.string("before.tokenizer")
        for value in [HeaderFixture.integer(9, bytes: 4) + HeaderFixture.integer(9, bytes: 4) + HeaderFixture.integer(1), HeaderFixture.integer(8, bytes: 4) + HeaderFixture.integer(1_048_577), HeaderFixture.integer(10, bytes: 4) + HeaderFixture.integer(UInt64.max), HeaderFixture.integer(9, bytes: 4) + HeaderFixture.integer(8, bytes: 4) + HeaderFixture.integer(4097), HeaderFixture.integer(9, bytes: 4) + HeaderFixture.integer(10, bytes: 4) + HeaderFixture.integer(UInt64(Int64.max / 8) + 1)] {
            do { _ = try await GGUFHeaderParser(source: HeaderBytes(HeaderFixture.file([key + value])), windowBytes: 16).parse(); XCTFail("Hostile value accepted") } catch {}
        }
    }
    func testRetainedArraysAndTotalStringBudgetAreBounded() async throws {
        let arrays = (0..<5).map { HeaderFixture.array("array\($0)", Array(repeating: 1, count: 4096)) }
        let texts = (0..<5).map { HeaderFixture.text("text\($0)", String(repeating: "x", count: 1_000_000)) }
        for entries in [arrays, texts] {
            do { _ = try await GGUFHeaderParser(source: HeaderBytes(HeaderFixture.file(entries))).parse(); XCTFail("Retained metadata budget exceeded") } catch {}
        }
    }
    func testFileHintsDistinguishProjectorsDraftsAdaptersShardsAndQuantizations() {
        for path in ["mmproj-Qwen-F16.gguf", "dir/mtp-Qwen-Q4_K_M.gguf", "model-00001-of-00003.gguf", "model-LoRA.gguf", "model-vocab.gguf", "model.pte"] { XCTAssertNotNil(GGUFFileName.exclusion(path), path) }
        XCTAssertNil(GGUFFileName.exclusion("Tree-of-thought-Q4_K_M.gguf"))
        XCTAssertEqual(GGUFFileName.quantization("dir/Model-IQ3_XXS.GGUF"), "IQ3_XXS")
        XCTAssertEqual(GGUFFileName.quantization("Model-BF16.gguf"), "BF16")
        XCTAssertNil(GGUFFileName.quantization("Model-unknown.gguf"))
    }
}
