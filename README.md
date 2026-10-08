<div align="center">

![OpenWeights logo](docs/assets/branding/readme-logo.png)

# OpenWeights iOS

**Run open-weight AI models on your iPhone.**<br>
No account, no telemetry. Inference runs on your own hardware.

[![Status](https://img.shields.io/badge/status-experimental-052B42?style=flat-square)](#requirements)
[![License](https://img.shields.io/badge/license-Apache--2.0-052B42?style=flat-square)](LICENSE)
[![iOS](https://img.shields.io/badge/iOS-17%2B-052B42?style=flat-square)](#requirements)
[![Engines](https://img.shields.io/badge/engines-llama.cpp%20%C2%B7%20MLX%20%C2%B7%20ExecuTorch-052B42?style=flat-square)](#three-runtimes-one-build)
[![Models](https://img.shields.io/badge/models-Hugging%20Face-052B42?style=flat-square)](https://huggingface.co/experimentalmachines)

</div>

OpenWeights iOS is an experimental native iPhone app for running open-weight
language models on your device. Download or import a compatible model, chat
with it locally, and control which tools and saved facts it can use.

This is the iOS counterpart to
[OpenWeights for Android](https://github.com/ExperimentalMachines/openweights),
built by Experimental Machines with SwiftUI and a shared C++ inference core.
The repository also includes a separate benchmark harness for measuring how
models and inference runtimes behave on real iPhones.

<div align="center">

<table>
  <tr>
    <th>Model library</th>
    <th>Discovery filters</th>
    <th>Saved memory</th>
  </tr>
  <tr>
    <td><img src="docs/assets/screenshots/models.png" alt="Model library with a local Qwen3 model, runtime choices and import controls" width="240"></td>
    <td><img src="docs/assets/screenshots/discovery-filters.png" alt="Hugging Face discovery filters for runtime, task and model size" width="240"></td>
    <td><img src="docs/assets/screenshots/saved-memory.png" alt="Saved memory screen for facts kept on the device across conversations" width="240"></td>
  </tr>
  <tr>
    <th>File tools</th>
    <th>Watches</th>
    <th>Local usage</th>
  </tr>
  <tr>
    <td><img src="docs/assets/screenshots/file-tools.png" alt="File tools with a folder picker and separate find, read, write and delete switches" width="240"></td>
    <td><img src="docs/assets/screenshots/watches.png" alt="Watches screen with reminder controls and iOS background scheduling disclosure" width="240"></td>
    <td><img src="docs/assets/screenshots/usage.png" alt="Local usage screen showing generated token counts and a thirty-day chart" width="240"></td>
  </tr>
</table>

Captured on iPhone 16 during the October 7, 2026 native UI validation in the
separate benchmark-slot app container. These are development-build screenshots.
The original image hashes were checked against the retained local validation
record before adding these screenshots.

</div>

## Contents

- [What makes it different](#what-makes-it-different)
- [Features](#features)
- [Requirements](#requirements)
- [Build](#build)
- [Our models on Hugging Face](#our-models-on-hugging-face)
- [Measurements and reports](#measurements-and-reports)
- [Architecture](#architecture)
- [Documentation map](#documentation-map)
- [Contributing and contact](#contributing-and-contact)
- [License](#license)

## What makes it different

**The Hub is the model list.** Search Hugging Face from the app, filter by
runtime and model metadata, or import compatible weights you already have.
Compatibility is checked for the selected artifact, rather than promised for
every search result.

**Three runtimes, one native app.** GGUF models use llama.cpp, compatible MLX
folders use MLX, and the validated Qwen3 compiled export uses ExecuTorch.
SwiftUI provides the interface, with inference on the phone.

**Tools within limits you set.** File access is scoped to a folder you choose.
Memory and file operations have separate switches and approval controls.
Network features are named, and iOS background scheduling limits remain visible.

**Numbers you can check.** The separate benchmark harness retains model hashes,
compiled source identities and real-device results. Published measurements
include reproduction data and state what they do and do not establish.

## Features

- **Find and manage models.** Search Hugging Face by runtime, task, publisher
  and size, download compatible artifacts, or import a local GGUF file.
- **Chat locally.** Stream responses, stop generation, manage saved
  conversations and adjust settings per model.
- **Control tools and memory.** Choose a shared folder, enable individual file
  operations and manage facts saved across conversations. File and memory
  tools start off and use approval controls when enabled.
- **Track local usage.** View generated token counts and model storage on
  the device.
- **Experiment with agent workflows.** Planning, questions, bounded goals,
  conversation folding and scheduled watches are under development. Their
  remaining acceptance checks are tracked in the
  [Android parity ledger](ios/Product/parity.md).

Model inference runs on the device. Model discovery and downloads use network
services, and enabled web tools can make network requests. Watch intervals are
due times: iOS controls when background work actually runs.

### Three runtimes, one build

| Runtime | Product integration | Benchmark coverage |
| --- | --- | --- |
| llama.cpp | Compatible GGUF models on CPU or Metal | CPU, full Metal and partial Metal configurations |
| MLX | Compatible MLX model folders on Metal | Standalone MLX |
| ExecuTorch | Validated Qwen3 XNNPACK export | XNNPACK, Core ML and MLX delegate exports |

Compatibility depends on the model architecture, artifact format and device
resources. A model appearing in search does not establish that it can run.
The benchmark harness measures first-response delay, streaming speed, process
memory, factual recall and interruption recovery with pinned artifacts and
retained source/build evidence.

## Requirements

- An iPhone running iOS 17 or newer. Isolated script and inference helpers use
  iOS 26 APIs and have separate availability checks.
- Enough memory and storage for your selected model and context window.
- To build: macOS, Xcode, XcodeGen and the native dependencies described in the
  component guides. Current independent signed builds were verified with Xcode 26.2.

The app is experimental and built from source. Full Android feature parity and
broader device coverage remain incomplete. Model weights and prebuilt ExecuTorch
dependencies are acquired separately.

## Build

From the repository root, prepare and verify the pinned native dependencies:

```sh
python3 prepare-native-dependencies.py
python3 prepare-native-dependencies.py --check
```

Run the host Swift core tests:

```sh
swift test --package-path ios/Product
```

Follow [the product build guide](ios/Product/README.md) for the SwiftUI app,
or [the benchmark build guide](ios/Benchmark/README.md) for the measurement
harness. The product build requires native libraries prepared with the same
selected Xcode toolchain.

## Our models on Hugging Face

Experimental Machines publishes model artifacts under
[experimentalmachines](https://huggingface.co/experimentalmachines).
Choose an artifact compatible with the iOS runtime, rather than assuming that
an Android ExecuTorch export runs unchanged on iPhone. The product guide
explains the pinned artifacts used for validation.

## Measurements and reports

The bounded CPU/Metal benchmark completed 36 conversations and 216 requests
on iPhone 16 across the Qwen3 pilot and five-model comparison. The
[published benchmark](https://experimentalmachines.github.io/OpenWeights-iOS/)
includes results, limitations and downloadable reproduction data. See the
[benchmark page guide](site/README.md) for retained files and verification.

The broader multi-device study and full Android parity are parked with
evidence preserved. Selected passing checks do not establish full parity or
a general runtime winner.

## Architecture

| Path | Purpose |
| --- | --- |
| `ios/Product` | SwiftUI app, shared Swift core and product tests |
| `ios/Benchmark` | Benchmark app, model export helpers, protocols and analysis |
| `core/engine` | Shared C++ session adapter and pinned llama.cpp dependency |
| `core/sandbox` | Pinned QuickJS dependency for script tools |
| `docs/research` | Measured reports and comparison figures |
| `migration` | Source provenance, validation receipts and artifact storage records |

Generated builds, model files and full test bundles are excluded from Git.
Large completed artifacts are archived privately on Hugging Face. See the
[storage layout](migration/storage-layout.md) for retained paths and restoration.

## Documentation map

| Document | Read it for |
| --- | --- |
| [Product guide](ios/Product/README.md) | App builds, dependencies and selected product validation |
| [Benchmark guide](ios/Benchmark/README.md) | Runtime builds, model exports and study execution |
| [Parity ledger](ios/Product/parity.md) | Android behavior, iOS acceptance checks and remaining gaps |
| [Repeated study](docs/research/ios-repeated-artifact-study.md) | Retained measurements, source/build cohorts and limitations |
| [Benchmark page](site/README.md) | Public report files and aggregate reproduction |
| [Storage layout](migration/storage-layout.md) | Local evidence, private archives and restoration |
| [Source manifest](migration/source-manifest.json) | Copied-source provenance and checksums |

## Contributing and contact

Use [issues](https://github.com/ExperimentalMachines/OpenWeights-iOS/issues)
and pull requests for iOS bugs and contributions. Include the device, iOS
version, model artifact, runtime and steps to reproduce. Performance claims
need real-device measurements with the tested build and model identified.

For the Android app, see
[ExperimentalMachines/openweights](https://github.com/ExperimentalMachines/openweights).
The README logo and app icon use that project's official artwork from
`play/graphics/readme-logo.png` and `play/graphics/icon-512.png`.

## License

[Apache License 2.0](LICENSE). Native dependencies and third-party models
retain their own licenses.

## Migration and verification details

<details>
<summary>Independent checkout validation and retained study evidence</summary>

This checkout separates the iOS sources from the Android repository. Sources
and native dependency hashes are verified. Independent signed product compilation
and six selected real-iPhone migration checks pass with Xcode 26.2. The independent
baseline benchmark passes three native methods and 45 requests across five
configurations. The rebuilt Core ML and ExecuTorch MLX targets pass three native
methods and 18 requests, including cancellation and recovery. These selected checks
validate execution from this checkout, not full study replication or parity.
Working reports and model exports use shared workspace
storage with links preserving historical paths. Historical signed builds remain
in the original checkout.
The full multi-device study and Android feature parity remain incomplete.
The [source manifest](migration/source-manifest.json) retains provenance and
copied-file checksums.

Historical proof files retain their original paths and hashes.

Study archive verification supports Firebase's separate `--xctestrun-file` plan.
It refuses changes to test hosts, bundles, method selection, timeouts and all
non-study settings. Twelve host integrity controls pass, and the exact completed
local Core ML S1 block 3 plan verifies against the retained signed package.
The separate-plan path passed the approved Core ML Pro S1 block 3 execution with two native methods and six conversation turns. See
[migration/separate-study-plan-verification-2026-10-07.json](migration/separate-study-plan-verification-2026-10-07.json).

The current study analysis requires exact raw-hash-bound source proofs and separates source, executable and toolchain cohorts. Nine of 63 cells have five matching complete primary blocks. The earlier 19-cell count pooled different builds in local baseline S2/S3. Historical results remain retained. See [the corrected report](docs/research/ios-repeated-artifact-study.md).

</details>
