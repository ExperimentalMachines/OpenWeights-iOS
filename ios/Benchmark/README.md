# iPhone benchmark pilot

This is an iOS benchmark app and hosted XCTest suite, built before choosing the
port's runtime defaults. It does not implement the Android app's product features.
The app and tests call the same runner.

## Run locally

Requires Xcode, CMake, Ninja, XcodeGen, an Apple development signing identity, and a paired
iPhone with Developer Mode enabled. The baseline app targets iOS 17 and newer. The initial
pilot toolchain was Xcode 26.5 with its iOS 26.5 SDK. Current cloud-compatible builds use Xcode 26.2 and standalone MLX 0.31.4. The original MLX 0.31.6 pilot pin is retained in `Study/pilot-Package.resolved`.

From the repository root:

```sh
python3 prepare-native-dependencies.py
cd ios/Benchmark
./build.sh DEVELOPMENT_TEAM=YOUR_TEAM_ID
./run.sh YOUR_IPHONE_UDID
```

Unlock the phone before starting. `build.sh` restores the checked-in Swift package
lock, builds the pinned shared C++ engine, and creates a signed Release app and
`.xctestrun`. The configured team is the local pilot's development team and can be
overridden with the build argument above. No additional memory entitlement is used.
The build also fetches the tokenizer revision pinned by ExecuTorch 1.4 and its
PCRE2 submodule to provide Qwen's required lookahead regex support. The iOS binary
package omits this optional component. PCRE2 JIT is disabled.

The first run downloads approximately 1.26 GB from the public Hugging Face repos
listed in `Resources/model-manifest.json`. Each file's revision and SHA-256 are
pinned. Downloads and verification finish before inference timing starts. Verified
files are reused on later runs and excluded from iCloud backup.

Raw JSON is saved in the app's Documents directory before loading each runtime
and after each completed request. The app disables automatic screen locking
during the run and restores the previous setting afterward.
The XCTest suite attaches the report, including partial results when a run throws.
`run.sh` exports the attachments under `Results/`. The standalone app also has a
Run button, cancellation, and a Share action for a completed report.

## What the pilot checks

All configurations use Qwen3 0.6B, a 2,048-token context ceiling, greedy decoding,
thinking disabled, and a 64-token output limit:

| Configuration | Artifact | Cache behavior |
| --- | --- | --- |
| llama.cpp CPU | GGUF Q4_K_M | Shared Android session, prefix reuse |
| llama.cpp Metal | Same GGUF, all layers offloaded | Prefix reuse |
| llama.cpp partial Metal | Same GGUF, 14 layers requested | Prefix reuse |
| ExecuTorch XNNPACK | 8da4w, 2k export | Reset before each request |
| MLX Metal | Affine 4-bit | Unquantized KV cache, prefix reuse |

Each configuration runs three fresh short conversations with follow-up turns, one
longer prompt, cancellation after three emitted tokens, and a fresh request after
cancellation. Each runtime starts at nominal thermal state, with a three-minute
cooldown limit. Failures are recorded per runtime and asserted by XCTest.

Reports include artifact hashes, runtime versions, prompts, outputs, load time,
first text callback latency, streaming throughput, process memory footprint,
thermal state, cache counts when available, and cancellation latency. The GGUF
runtime uses its own chat template. Explicit prompt hashes apply to MLX and
ExecuTorch only.

These are validation measurements. Different quantizations and cache behavior
prevent attributing differences solely to the runtime. Three repeats and one model
are insufficient to choose a production default or publish broad hardware claims.
Fresh contexts do not imply cold filesystem caches. Memory is sampled every 50 ms
during load and generation and can miss short peaks. Process footprints include
allocators, framework caches, and work from earlier stages of the same process.
They are not isolated engine memory requirements. Battery energy is not measured.

The local pilot passed on iPhone 16 with iOS 26.6.2 on 2026-10-01. All five
configurations completed nine requests each, with cancellation and subsequent
generation passing for each. See the [measured report](../../docs/research/ios-benchmark-pilot.md)
and [raw results](Results/iphone16-pilot-2026-10-01.json).

## Multi-turn scaling

The Six-turn conversation workload carries actual assistant responses forward,
expands history within the 2k ceiling, and checks three original or updated facts.
It runs one conversation per artifact. Prefix-enabled engines also replay the
same message arrays with cache cleared before each request. ExecuTorch's current
adapters rebuild history each turn. Select the workload in the app or run:

```sh
./run.sh YOUR_IPHONE_UDID --multi-turn
./run.sh YOUR_IPHONE_UDID --delegates --multi-turn
./run.sh YOUR_IPHONE_UDID --delegates --multi-turn --mlx-only
./run.sh YOUR_IPHONE_UDID --delegates --multi-turn --coreml-only --timeout-seconds=3600
```

The last two commands isolate a delegate. Both XCTest timeout allowances default
to 30 minutes and can be overridden together with `--timeout-seconds`. The FP16
Core ML export exceeded 30 minutes during turn 6, so its checkpoint is retained
as failure evidence. Its isolated retry completed all six turns in 18m38s under
a 60-minute allowance. Turn-6 first text still took 7m30s. The export and workload
were unchanged, and the cause of the earlier extreme slowdown is unresolved.

Build the corresponding target first. Raw reports record the workload definition,
turn, cache policy, full history, context bytes, native token counts where
available, strict recall probes, timings, memory and thermal states. This is an
exploratory six-turn pilot, not a general conversation-quality benchmark. See the
[multi-turn study](../../docs/research/ios-multiturn-scaling.md) for measured
results and the reply-splicing cache issue found in the shared llama.cpp engine.

## ExecuTorch Apple delegates

The additional O6 Core ML and O7 ExecuTorch MLX configurations use a separate
Release app build with ExecuTorch 1.5. They share the same Swift runner, prompts,
2k context ceiling, 64-token output limit, and XCTest assertions. The separate
build avoids linking the standalone MLX Swift package with the MLX C++ library
bundled in the ExecuTorch delegate. Installing either build replaces the benchmark
app on the phone, while keeping its Documents and downloaded-model cache.

```sh
./export-delegates.sh
./build-delegates.sh DEVELOPMENT_TEAM=YOUR_TEAM_ID
./run.sh YOUR_IPHONE_UDID --delegates
```

Exporting requires an Apple Silicon Mac, Python 3.12, `uv`, and `hf`. The script
creates an isolated environment from `Export/requirements.txt`, downloads the
original Qwen checkpoint at a pinned revision, and exports each delegate locally.
Weights and intermediate files stay ignored under `Models/` and `.build/`.
The generated `Resources/model-manifest-delegates.json` pins every bundled
file's SHA-256. XCTest verifies the bundled files before starting measurements.
These exports have not been published to Hugging Face.

The Core ML export targets iOS 18, uncompressed FP16 weights, FP16 KV cache,
and CPU_AND_GPU compute units. It uses static single-token steps for both prefill
and decode. Its custom
export adapter keeps symbolic scalar cache operations outside the tensor-only
Core ML boundary and converts the causal mask to equivalent additive float
values. The boolean mask generated an int8 gather that Apple's iPhone runtime
rejected. This is a baseline export rather than the optimized stateful Core ML
recipe. This configuration permits CPU and GPU execution. The initial ALL
configuration failed Neural Engine compilation and the test process was killed
during loading. No Neural Engine performance result is claimed.

The MLX delegate export uses TorchAO int4 linear weights with group size 32,
FP16 embeddings and KV cache, and a 2,048-token prefill setting. The dynamic
graph accepts up to 2,047 input tokens. This replaces the original 512-token
setting, whose chunk boundary failed during the growing-history test. It avoids
chunking within the pilot's 2k context and 64-token output reserve.
Both delegate runners reset the cache before each request. ExecuTorch 1.5's
packaged tokenizer includes the PCRE2 fallback, so this build does not link the
1.4 tokenizer addon. Swift package and Python versions are pinned separately.

Both delegate configurations passed nine requests each on iPhone 16 on
2026-10-02. MLX measured 111.4 streaming tokens/s. Core ML measured 4.0 tokens/s,
but produced repetitive, incorrect answers. The original five configurations
also passed a regression run after the shared runner changes. See the
[delegate measurements and limitations](../../docs/research/ios-executorch-apple-delegates.md).

The current Core ML export disables weight compression after a numerical
comparison found large errors in the channelwise int4 artifact. Uncompressed
FP16 reproduced the FP32 source outputs on both pilot prompts on Mac. It is
larger, at 1,205,798,090 bytes. The updated iPhone run passed all 18 requests,
including cancellation and recovery. Core ML's tested answers were coherent,
but it measured 3.53 tokens/s with 11.44 seconds to first text and a peak process
footprint of 2,392.4 MiB. See the
[export validation](../../docs/research/ios-coreml-export-validation.md).
Run the local fidelity check before testing a changed Core ML export:

```sh
.build/export-env/bin/python Export/validate_coreml.py Models/coreml/model.pte \
  --output Results/coreml-export-validation.json
```

Use `./package.sh --delegates` to prepare the additional XCTest archive for a
future Firebase run. It bundles the exported models and does not submit a test.

## Prepare the same tests for Firebase

After the local XCTest suite passes:

```sh
./package.sh --suite=smoke --firebase
```

This verifies the app signature and packages `Release-iphoneos` and `.xctestrun`
into `Results/OpenWeightsBench-tests.zip`, following the
[Firebase XCTest preparation guide](https://firebase.google.com/docs/test-lab/ios/run-xctest).
Packaging does not upload or start a cloud test. A Xcode 26.2 llama.cpp Metal smoke passed two tests and nine requests on Firebase iPhone 16 Pro, observed iOS 18.3.2, on 2026-10-02. Other cloud runtime/device cells remain unverified. See [cloud verification](../../docs/research/ios-firebase-smoke.md).


## Repeated conversation study

The protocol is `Study/protocol-v1.json`. Run independent block indices 0 through 4, with rotated fast-runtime order. Use `--attempt=1` or higher for retries. Raw failures remain evidence and retries are not counted as independent primary blocks.

```sh
Study/run_local_block.sh IPHONE_UDID --scenario=S1-stable-facts --block=0
Study/run_local_block.sh IPHONE_UDID --scenario=S2-workshop-corrections --block=0
Study/run_local_block.sh IPHONE_UDID --scenario=S3-interruption-recovery --block=0
Study/run_local_block.sh IPHONE_UDID --delegates --scenario=S3-interruption-recovery --block=0 --runtime="ExecuTorch MLX"
```

Core ML must be selected explicitly and runs alone. Its plan allows 40 minutes, within Firebase's 45-minute limit. Package a study plan with `--suite=study`, the scenario, block and optional runtime. Preserve each job's actual plan and build receipt.

The first local interruption block passed 59 requests across five runtimes. This is one block, not the completed repeated study. Analyze retained reports with `Study/analyze_study.py REPORT.json ... --output ANALYSIS.json`. The analysis rejects duplicate primary block IDs and reports medians, interquartile values, thermal filtering, failures and separate factual/format scores.

The first S3 block exposed factual misses, including misspellings of the diet. Version-2 analysis separates a correct value with an explicit dietary-rule prefix from the strict one-word requirement. Raw outputs and version-1 analysis are preserved. This grading clarification occurred before matrix expansion and is recorded in the protocol. Run `python3 -m unittest discover -s Study -p "test_*.py"` to verify independent-block counting and grading safeguards.


## Older-iOS GGUF benchmark

The separate `project-gguf.yml` target builds for iOS 16.6 with the pinned shared C++ engine. It uses the same Qwen3 Q4_K_M file, 2k context, greedy 64-token limit, CPU/full-Metal/14-layer partial-Metal configurations and S1-S3 workloads. MLX/ExecuTorch packages are excluded because their pinned Swift packages require iOS 17. Runtime metadata labels `gguf-ios16.6-v1`, and analysis keeps this package separate from the baseline. Excluding unused frameworks can change footprint/startup, so differences must not be attributed solely to hardware.

```sh
bash build-gguf.sh
bash package.sh --gguf-only --suite=smoke --firebase
bash Study/run_local_block.sh IPHONE_UDID --gguf-only --scenario=S1-stable-facts --block=0 --attempt=0
```

Select the pinned Xcode 26.2 toolchain when building and packaging, as with the baseline. [Protocol addendum](Study/older-ios-gguf-addendum.json) defines older-device candidates and gates before matrix expansion. [Build/package proof](Results/gguf16-build-349f1ccc7f20.json) records source-before/after checks, signed smoke/S1 archives, app/test minimums and all 302 native Mach-O object minimums. The prepared packages are 10,730,056 bytes for smoke and 10,730,088 bytes for S1. Both exact immutable packages now pass on iPhone 16, iOS 26.6.2. Smoke passes two tests and nine measured Metal requests, including cancellation/recovery. S1 passes two tests and thirty-six measured samples across CPU/full/partial Metal, with retained-prefix and matched reset replay. All S1 samples start/end at nominal temperature. [Local package proof](Results/retained-gguf16-local-validation-9f5bf2e44b05.json) records unchanged executable and test-plan hashes. This is one S1 block, below five, and is not execution on an iOS 16.6 phone. The approved older-device cloud smoke has now finished with no inference result: iPhone 11 Pro launched on iOS 16.6 and passed corruption rejection, but the model download timed out. iPhone 14 Pro failed all three infrastructure attempts. [Terminal cloud proof](Results/firebase-gguf16-smoke-outcome-2026-10-04.json) retains the failed benchmark attachment, XCTest/XML/logs and exact package/source identities. No further job or study replication is approved.

When the working tree has advanced since an immutable package was built, `Study/collect_local.py --retained-execution EXECUTION_RECEIPT` verifies the original archive, build/source receipts and before/after binary hashes. It records the retained sources instead of describing current files as the compiled inputs. The native execution receipt must identify the bundle. The current collector hash is recorded separately. The local smoke/S1 proof archives the exact validation tools. A deliberately incorrect archive hash was refused before altering results. Seven analysis regressions pass. The prepared package ZIPs and original protocol addendum remain unchanged.


Model acquisition retry validation on 2026-10-04:
`Results/acquisition-retry-local-validation-f2abcb9fccf3.json` retains six injected
Mac controls and nine native iPhone tests. A fresh full GGUF download verified
396,705,472 bytes in 6.79 seconds. The smoke used the verified app cache and passed
nine inference requests with cancellation/recovery. This is a new signed source
cohort, separate from the immutable historical older-iOS packages. It does not
prove Firebase's CDN timeout has recovered.

`ModelStore` retries only transient URL transport failures, at most three requests
with one- and two-second delays, from the original pinned Hub URL. HTTP/TLS/hash
failures remain terminal. The existing 1800-second per-request timeout remains, so
three attempts are not guaranteed to fit a five-minute cloud job. Both runners
checkpoint optional `acquisitions` events with source/response host, attempt,
outcome, status, bytes, elapsed time and error domain/code. Signed query URLs are
excluded. Older reports omit this optional field and remain decodable.

Run the isolated host controls with
`python3 ios/Benchmark/Export/check_model_acquisition.py` from the repository root.
The prepared smoke archive `OpenWeightsGGUFBench-smoke-75c18833e20a.zip` and
`Study/firebase-acquisition-retry-preflight-2026-10-04.json` await separate paid-job
approval. No new cloud execution or study replication is authorized.


## Bundled older-device delivery candidate, 2026-10-06

The separately signed gguf-ios16.6-bundled-v1 candidate carries the exact pinned GGUF in the application bundle and preserves original fixtures, native libraries and inference settings. It bypasses remote acquisition in the selected benchmark methods, without claiming the earlier CDN timeout or infrastructure failures are fixed. The frozen native source archive is authoritative for reused libraries. The separate raw runtime variant prevents pooling with older remote-delivery or full-framework packages.

[Protocol](Study/older-ios-bundled-gguf-addendum.json) and [clean package proof](Results/gguf16-bundled-package-revalidation-0104eef7f0e4.json) retain source-before/after guards, signing, exact model bytes, smoke/S1 plans and binary iOS 16.6 minimums. The first source-equivalence rejection and superseded package with HF cache resources remain preserved. Clean smoke and S1 archives are prepared but have not run on the phone. Exact local validation must pass before another paid cloud proposal. No new older-device approval or execution exists, and original study requirements remain intact.


## Figures with separate device and OS cohorts

`Study/plot_device_cohorts.py` exports PNG, SVG and PDF for one pinned artifact,
with complete-primary-block medians and IQRs for final-turn first text, decode
speed and sampled process footprint. Select each actual device and exact OS
string explicitly. It refuses fewer than five complete blocks, ambiguous
artifact/cache cohorts, differing runtime/artifact/cache settings and invalid
metric denominators. OS and lab conditions remain separate labels. The figure
does not isolate hardware effects or rank general model quality.

For example, after both exact cohorts have five matching complete blocks:

```sh
python Study/plot_device_cohorts.py Results/ANALYSIS.json \
  --output-dir Results/device-cohort-figures \
  --engine 'ExecuTorch Core ML' --scenario S1-stable-facts \
  --cohort 'iPhone17,3=Version 26.6.2 (Build 23G90)' \
  --cohort 'iPhone17,1=Version 18.3.2 (Build 22D82)'
```

Use the pinned `Study/plot-requirements.txt` plotting environment. Provenance
records the input analysis/source hashes, selected cells, tool versions and
asset hashes. [Host verification](../../migration/device-cohort-figure-verification-2026-10-07.json)
records nine controls, byte-identical reproduction of the actual five-block
local figure, and refusal of the actual four-block cloud cohort. The local
preview is a renderer check, not a new study measurement. Historical local
figures and `plot_study.py` remain unchanged.


## Source and build cohort correction, 2026-10-07

Analysis schema 5 requires every raw report to have a source proof with its exact filename and SHA-256. Compile source maps, executable hashes and Xcode/SDK identity define a build cohort. The analyzer separates load and turn distributions by this cohort along with artifact, protocol, device/OS and cache controls. The ledger checks the same raw/source binding and refuses older unseparated analyses.

The initial 19-of-63 count pooled different builds in baseline S2/S3. Each affected cell has four complete foreground-guard blocks plus one earlier block. Strict matching currently satisfies nine cells. All 51 raw reports and 16 failed runtime rows remain retained. Historical figures and their frozen analyses are preserved, and the current S1 seven-configuration figure reproduces from the source/build-separated analysis. The phone-test hold remains.
