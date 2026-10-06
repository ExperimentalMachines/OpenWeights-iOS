# OpenWeights iOS

Native iOS port and benchmark harness for Experimental Machines.

This checkout separates the iOS sources from the Android repository. Sources
and native dependency hashes are verified. Independent signed product compilation
and six selected real-iPhone migration checks pass with Xcode 26.2. The independent
baseline benchmark passes three native methods and 45 requests across five
configurations. Core ML and ExecuTorch MLX benchmark targets also compile, with
device validation of their new binaries pending. Large completed artifacts are archived
privately on Hugging Face. Working reports and model exports use shared workspace
storage with links preserving historical paths. Historical signed builds remain
in the original checkout.
The full multi-device study and Android feature parity remain in progress.

- `ios/Product`: SwiftUI product, shared Swift core and product tests.
- `ios/Benchmark`: benchmark app, model export helpers, study protocols and analysis.
- `core/engine`: shared C++ session adapter and pinned llama.cpp dependency.
- `core/sandbox`: pinned QuickJS dependency.
- `docs/research`: reports and comparison figures.
- `migration/source-manifest.json`: source provenance and copied-file checksums.
- `migration/storage-layout.md`: executed local and Hugging Face storage layout.

Prepare native dependencies with `python3 prepare-native-dependencies.py`.
Verify them with `python3 prepare-native-dependencies.py --check`.
Build instructions are in [the product README](ios/Product/README.md) and
[the benchmark README](ios/Benchmark/README.md). Model weights and prebuilt
ExecuTorch dependencies are acquired separately as described there.

Generated builds, model files and full test bundles are excluded from Git.
Historical proof files retain their original paths and hashes.
