import CryptoKit
import XCTest
@testable import OpenWeightsCore

final class CompiledHubArtifactTests: XCTestCase {
    private let pin = String(repeating: "a", count: 40)
    private let entry = "xnnpack/model-2k.pte"
    private func fixture(source: String = "Qwen/Qwen2.5-1.5B-Instruct", context: Any = 2048,
                         backend: String = "xnnpack", version: String = "1.4.0") throws -> (Data, [ModelFile]) {
        let data = try JSONSerialization.data(withJSONObject: ["runtime":"executorch", "runtime_version":version,
            "backend":backend, "tokenizer":"tokenizer.json", "source_model":source,
            "variants":[["file":"model-2k.pte", "context":context, "size_bytes":1000, "sha256":String(repeating:"B",count:64)]]])
        var blob = Insecure.SHA1(); blob.update(data: Data("blob \(data.count)\0".utf8)); blob.update(data: data)
        let hash = blob.finalize().map { String(format:"%02x",$0) }.joined()
        return (data, [ModelFile(path:"xnnpack/config.json",bytes:Int64(data.count),gitBlobSHA1:hash),
            ModelFile(path:"tokenizer.json",bytes:6,gitBlobSHA1:"ce013625030ba8dba906f756967f9e9ca394464a"),
            ModelFile(path:entry,bytes:1000,sha256:String(repeating:"b",count:64))])
    }
    private func select(_ data: Data, _ files: [ModelFile], entry: String? = nil, revision: String? = nil) throws -> LocalModel {
        try CompiledHubArtifact.select(repository:"org/model",revision:revision ?? pin,entry:entry ?? self.entry,files:files,configData:data)
    }
    func testFamilyAwarePinnedSelectionAndCanonicalCompanions() throws {
        for (source,family) in [("Qwen/Qwen2.5-1.5B-Instruct","qwen25"),("Qwen/Qwen3-1.7B","qwen3"),("HuggingFaceTB/SmolLM2-135M-Instruct","smollm2"),("meta-llama/Llama-3.2-1B-Instruct","llama32")] {
            var (data,files) = try fixture(source:source)
            files[2].url = URL(string:"https://unrelated.example/weights")
            let model = try select(data,files)
            XCTAssertEqual(model.family,family); XCTAssertEqual(model.backend,.xnnpack)
            XCTAssertEqual(model.settings.contextTokens,2048); XCTAssertEqual(model.entryFile,entry)
            XCTAssertEqual(model.files.map(\.path),["xnnpack/config.json","tokenizer.json",entry])
            XCTAssertTrue(model.files.allSatisfy { $0.url?.host == "huggingface.co" && $0.url?.path.contains("/resolve/" + pin + "/") == true })
            XCTAssertEqual(model.files[2].sha256,String(repeating:"b",count:64))
            XCTAssertNil(model.files[2].gitBlobSHA1)
        }
    }
    func testRefusesUnsupportedProtocolsVersionsContextsAndNumericCoercion() throws {
        for source in ["Qwen/Qwen2.5-1.5B","Qwen/Qwen2.5-Coder-1.5B-Instruct","Qwen/Qwen3-VL-2B-Instruct","HuggingFaceTB/SmolLM2-135M","HuggingFaceTB/SmolLM3-3B"] {
            let (data,files) = try fixture(source:source); XCTAssertThrowsError(try select(data,files))
        }
        for context in [4096,2048.5,true,"2048"] as [Any] {
            let (data,files) = try fixture(context:context); XCTAssertThrowsError(try select(data,files))
        }
        for (backend,version) in [("coreml","1.4.0"),("mlx","1.4.0"),("xnnpack","1.5.0")] {
            let (data,files) = try fixture(backend:backend,version:version); XCTAssertThrowsError(try select(data,files))
        }
    }
    func testRefusesMissingAmbiguousTamperedAndExternalComponents() throws {
        let (data,files) = try fixture()
        for index in files.indices {
            var missing = files; missing.remove(at:index); XCTAssertThrowsError(try select(data,missing))
            var duplicate = files; duplicate.append(files[index]); XCTAssertThrowsError(try select(data,duplicate))
            var noHash = files; noHash[index].sha256 = nil; noHash[index].gitBlobSHA1 = nil; XCTAssertThrowsError(try select(data,noHash))
            var badSize = files; badSize[index].bytes = 0; XCTAssertThrowsError(try select(data,badSize))
        }
        var mismatch = files; mismatch[2].bytes = 1001; XCTAssertThrowsError(try select(data,mismatch))
        mismatch = files; mismatch[2].sha256 = String(repeating:"c",count:64); XCTAssertThrowsError(try select(data,mismatch))
        mismatch = files; mismatch[0].gitBlobSHA1 = String(repeating:"d",count:40); XCTAssertThrowsError(try select(data,mismatch))
        XCTAssertThrowsError(try select(Data(data.reversed()),files))
        XCTAssertThrowsError(try select(data,files + [ModelFile(path:"xnnpack/weights.ptd",bytes:1000,sha256:String(repeating:"e",count:64))]))
        XCTAssertThrowsError(try select(data,files,entry:"../escape.pte"))
        XCTAssertThrowsError(try select(data,files,revision:"main"))
        var malformed = files; malformed[1].gitBlobSHA1 = "invalid"; XCTAssertThrowsError(try select(data,malformed))
    }
    func testLegacyModelFileDecodesWithoutGitChecksum() throws {
        let file = try JSONDecoder().decode(ModelFile.self,from:Data("{\"path\":\"model.pte\",\"bytes\":1000}".utf8))
        XCTAssertNil(file.gitBlobSHA1)
        let (data,files) = try fixture()
        let model = try select(data,files)
        XCTAssertEqual(try JSONDecoder().decode(LocalModel.self,from:JSONEncoder().encode(model)),model)
    }
}
