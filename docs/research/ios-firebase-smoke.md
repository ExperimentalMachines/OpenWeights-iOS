# iOS Firebase smoke verification

Status: executed and verified on 2026-10-02. This verifies cloud execution of one fast runtime. The repeated multi-device study and native product remain incomplete.

Firebase matrix `matrix-3fwpagg6ujov0` passed both selected XCTest methods and all nine llama.cpp Metal requests on an iPhone 16 Pro. Catalog OS label `18.3` produced an observed `iPhone17,1` running iOS 18.3.2, build 22D82. Record the observed version when comparing devices.

The cloud output confirms downloading the pinned Qwen3-0.6B Q4_K_M GGUF from Hugging Face. ModelStore checked its 396,705,472 bytes and SHA-256 before inference. Cancellation and subsequent generation passed. The corruption test rejected a wrong hash and wrong size. The benchmark JSON was recovered from the cloud XCTest attachment. All nine samples began and ended at nominal thermal state. Charging and ambient conditions were not controlled by the experimenter.

## Build compatibility

Both baseline and delegate Release XCTest builds passed using Xcode 26.2, build 17C52, SDK 26.2 and Swift 6.2.3. Workspace-local Ninja 1.13.0 replaced the Make generator because Make mishandled the toolchain path containing spaces. CMake was 4.3.3. Apple's iOS 26.2 platform support and Metal toolchain were downloaded through the CLI. The system-selected Xcode was not changed.

Standalone MLX 0.31.6 requires Swift tools 6.3 and could not compile with this Firebase-supported Xcode. The compatible build explicitly pins MLX 0.31.4 while retaining mlx-swift-lm 3.31.3. The original pilot dependency lockfile is preserved in `ios/Benchmark/Study/pilot-Package.resolved`. Historical pilot measurements are not rewritten. Repeated comparisons must keep this version difference explicit.

Local validation of the compatible builds passed 45 baseline requests, nine delegate MLX requests and nine requests through the exact smoke-only package plan. The baseline pilot exercised all five fast configurations. The slow Core ML artifact was compiled but was not executed as part of this fast compatibility check.

## Cloud attempts and cost

The initial matrix `matrix-1mgxt3mbil7bu` failed validation with `SERVICE_NOT_ACTIVATED`, before any device execution. Enabling `testing.googleapis.com` and `toolresults.googleapis.com` allowed the same verified archive to execute in the replacement matrix. Both attempts are retained.

Tool Results reports success, two tests and 112 seconds of test-process time. XCTest suite time was 105.207 seconds including model acquisition. Generation sample timings exclude downloading and hashing. Execution rounds to two physical-device minutes. Estimated execution charge is $0 within the documented 30 free physical-device minutes per day. Without free allowance, two minutes would cost about $0.17. An invoice was not verified and storage charges are excluded from that estimate. See [Firebase pricing](https://firebase.google.com/docs/test-lab/usage-quotas-pricing).

## Retained evidence

- [Cloud raw report](../../ios/Benchmark/Results/firebase-iphone16pro-smoke-2026-10-02.json)
- [Cloud verification, source hashes, build receipt and test verdict](../../ios/Benchmark/Results/firebase-iphone16pro-smoke-source.json)
- [Initial validation failure](../../ios/Benchmark/Results/firebase-smoke-validation-failure-2026-10-02.json)
- [Preflight and device catalog](../../ios/Benchmark/Results/firebase-preflight-2026-10-02.json)
- [Local baseline compatibility run](../../ios/Benchmark/Results/iphone16-xcode26.2-baseline-pilot-2026-10-02.json)
- [Local delegate smoke](../../ios/Benchmark/Results/iphone16-xcode26.2-delegates-smoke-2026-10-02.json)
- [Study protocol](../../ios/Benchmark/Study/protocol-v1.json)

The ignored Results directory archives include signed smoke packages and exact source snapshots. `Export/verify_archive.py` verifies package executables and the smoke plan against a retained build receipt, then verifies every source snapshot hash. Cloud xcresult, output logs and XML remain in the ignored build directory. Public JSON excludes device identifiers and account credentials.

## Reproduce a compatible build

Install CMake, XcodeGen and official Xcode 26.2, then initialize the required Apple components. From `ios/Benchmark`:

```sh
python3 -m venv .build/build-tools
.build/build-tools/bin/pip install ninja==1.13.0
export PATH="$PWD/.build/build-tools/bin:$PATH"
export DEVELOPER_DIR="/path/to/Xcode-26.2.app/Contents/Developer"
./build.sh
./build-delegates.sh
./run.sh IPHONE_UDID
./run.sh IPHONE_UDID --delegates --smoke
./package.sh --suite=smoke --firebase
```

Recheck and retain the current Firebase catalog before packaging. The current compatibility check uses the catalog retained under `.build/firebase/versions-2026-10-02.json`. `package.sh` selects an explicit suite instead of allowing all slow tests to run together. Recheck free allowance and prepare the chosen project/device command before any paid matrix expansion.
