import Foundation
import OpenWeightsCore

@MainActor enum NativeMLXArtifact {
    static func qwen25() -> LocalModel {
        let repository = "mlx-community/Qwen2.5-1.5B-Instruct-4bit", revision = "8b403126fc14f14cfc99bb4cfa72ecbc129ea677"
        let specs: [(String, Int64, String)] = [
            ("added_tokens.json", 605, "58b54bbe36fc752f79a24a271ef66a0a0830054b4dfad94bde757d851968060b"),
            ("config.json", 784, "636d3e2a15e8914b8cf82b05cc2288a811f9bd93c3bf1afc00cab701a70b47c0"),
            ("merges.txt", 1671853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
            ("model.safetensors", 868628559, "0979f33d1bc58afcf696d13f57977644e7b11a6f0eec3e631d8e9463d18c0717"),
            ("model.safetensors.index.json", 51569, "6b98634d5044f0e2ad45228a374f8445904e571f1082392d08a6ce54f5d517ca"),
            ("special_tokens_map.json", 613, "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
            ("tokenizer.json", 7031673, "a8506e7111b80c6d8635951a02eab0f4e1a8e4e5772da83846579e97b16f61bf"),
            ("tokenizer_config.json", 7308, "f7c61e32b7a17d19bf8e7037dcb74079a833e53ea9801f24008cac68458f03b7"),
            ("vocab.json", 2776833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910")
        ]
        return LocalModel(name: "Qwen2.5 1.5B Instruct MLX family control", backend: .mlx, entryFile: "config.json",
            files: specs.map { path, bytes, sha in ModelFile(path: path, bytes: bytes, sha256: sha,
                url: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)")!) },
            repository: repository, revision: revision, family: "qwen2")
    }
}
