# Bounded publication benchmark

The separate [Firebase delivery pilot](CLOUD.md) prepares one LFM2.5 CPU job and
one Metal job. It reuses this workload and scorer without resuming the parked
exhaustive study. Paid execution requires approval of the exact packages.

Status: Qwen3-0.6B pilot measured on iPhone 16 on 2026-10-07. All six fresh
conversations and 36 requests passed at nominal temperature. Twenty-one host
controls pass. The GGUF-only signed Release build uses Xcode 26.2/SDK 26.2.
The five-model batch also completed thirty conversations and 180 requests in
33.8 minutes. Both evidence bundles are privately archived with fresh-download
SHA-256 and ZIP-CRC verification. JC confirmed readiness for this new benchmark. The historical
A1-A3 study and parity tests remain parked, with evidence preserved.

This profile answers how quickly the same model responds on CPU and Metal,
how much app memory it uses, and whether it recalls facts across six turns.
Qwen3-0.6B is the protocol pilot. Broader model selection is Gemma 3 1B IT,
LFM2.5 1.2B Instruct, Qwen3 1.7B, Llama 3.2 3B Instruct and SmolLM3 3B.
Their pinned GGUF revisions/hashes are in `comparison-models.json`, totaling
7,306,063,392 bytes. Bounded header checks identify architectures supported by
the pinned native source. Actual CPU/Metal loading and six-turn inference passed for all five models.
No new ExecuTorch/Core ML/MLX exports are required for this first comparison.

## Measurements

| Code | Metric | Definition |
| --- | --- | --- |
| M1 | First-response delay | Median seconds to the first text callback. `turns.csv` also shows every turn, including first and sixth. |
| M2 | Generation speed | Median streaming tokens/s, excluding replies below eight generated tokens. Not comparable across tokenizers as literal words/s. |
| M3 | Peak app memory | Median of each nominal conversation's maximum process footprint across loading and generation, sampled every 50 ms. |
| M4 | Factual recall | Correct/scorable probes, with unscorable and missing probes explicit. Strict-format correctness is separate. Diagnostic only, not general model quality. |

CPU and Metal use identical GGUF bytes, native chat template, prefix retention,
greedy decoding, thinking disabled, 2k context, and a 64-token maximum reply.
The existing S1 stable-facts six-turn fixture is reused unchanged. Actual replies
carry into later turns. Models can therefore produce different later histories.
Three repetitions improve timing stability but are not three independent tasks.
The Android comparison shares model families and named quantizations, including
Qwen3-1.7B Q8_0 while the other four use Q4_K_M. Exact historical Android file
hashes are not established. These newly pinned artifacts must not be described
as verified byte-identical to the historical Android models. Android's published
GSM8K/IFEval/BFCL runs used different prompts, output caps, sampler settings and
single-pass conditions. This six-turn iOS study cannot support a controlled
Android-versus-iPhone performance or quality claim.
Each repetition has three recall probes. JSON enclosed in a code fence can be
factually correct while failing the strict-format probe. Malformed/ambiguous JSON
is unscorable. The one-word probe accepts case and terminal punctuation for facts,
and explicit positive diet labels. Other longer explanations are unscorable
rather than guessed. This scorer was fixed before five-model collection.

The Qwen pilot has six fresh XCTest invocations and 36 requests. Five models
have thirty invocations and 180 requests. Each invocation selects one model/backend
conversation. Distinct process IDs and observed CPU/MTL0 backend labels are captured for
every measured conversation. No reset replay, cancellation study or app-parity
suite is selected. Warm filesystem caches are not a cold-storage measurement.

## Prepare once

From `ios/Benchmark`, compile the GGUF-only Release target once:

```sh
bash build-gguf.sh
python3 Publication/benchmark.py prepare \
  --xctestrun .build/DerivedData-gguf16/Build/Products/OpenWeightsGGUFBench_iphoneosYOUR_SDK-arm64.xctestrun \
  --output Publication/outputs/qwen-pilot-UNIQUE_LABEL \
  --budget-seconds 900
```

Use the actual generated `.xctestrun` filename. Preparation contacts no device.
Select the same Xcode used for building through `DEVELOPER_DIR` when running.
This workspace's Xcode 26.2 is `.build/toolchains/Xcode.app/Contents/Developer`.
The existing Ninja/CMake binaries are under the workspace's
`.benchmark-work/Android/sdk/cmake/4.1.2/bin`; add that directory to PATH if needed.
It snapshots models, workload, protocol, runner and build receipt and records each
plan's SHA-256. Run refuses changed plans, changed inputs, stale compiled sources,
a different build receipt, or overwriting an executed stage. Full-model preparation
uses `--models` with a manifest containing one pinned GGUF per model. The format
matches `pilot-models.json`; do not use mutable `main` download URLs.

## Run after the phone hold is lifted

Use Developer Mode, trust/pair the Mac, and keep the benchmark unlocked and visible.
Enable UI Automation is useful for tap-based tests, which this profile does not run.
Charge beforehand, then unplug and cool the phone. Turn Low Power Mode off and
keep brightness fixed. Automatic screen sleep is disabled during each invocation
and restored afterwards. There may still be screen-lock gaps between invocations.
Do not disable passcode protection. A locked device stops at the host timeout.

```sh
python3 Publication/benchmark.py run Publication/outputs/qwen-pilot-UNIQUE_LABEL \
  --device YOUR_IPHONE_UDID --stage acquire --phone-ready
python3 Publication/benchmark.py run Publication/outputs/qwen-pilot-UNIQUE_LABEL \
  --device YOUR_IPHONE_UDID --stage measure --phone-ready
```

Acquisition verifies/downloads models separately, with a 15-minute host limit per
model. Measurement invocations refuse downloads and verify the device cache.
The full comparison budget is 60 minutes total, including launches, verification
and cooling. The pilot above uses a 15-minute ceiling. Each native conversation cancels cooperatively at ten minutes, and each
host invocation is bounded by the smaller of eleven minutes or remaining budget.
Nominal-temperature waits stop after three minutes. The first failure stops new
launches. There are no automatic benchmark retries. A new attempt gets a new folder.
Host termination has at most nine seconds of shutdown grace. It cannot guarantee
that an unresponsive device process stops immediately or exports its checkpoint.
Missing report evidence is marked rather than synthesized.

Completed turns are written atomically in the app. XCTest attaches complete or
partial reports when it can finish. After measurement, attachment extraction has
a separate 30-second limit per result bundle, outside the measurement budget.
Results are `index.json`, `summary.json`, `summary.csv`, `turns.csv`, raw attachments,
host logs and xcresult bundles. Failed, warm and missing observations stay retained.
Only nominal samples from successful complete conversations enter headline timing.
Rows show planned and observed denominators, even when no results are available.
Process footprint is not total CPU-plus-GPU device memory. Lower Metal readings
do not establish total physical-memory savings. GPU residency is not measured.
After an interrupted host session, inspect and retain its folder; never rerun into it.

For the five-model batch, run `--stage acquire`, then `--stage calibrate`, then
`--stage measure` in one prepared folder. Calibration runs repetition zero for
every model/backend, totaling ten conversations. These are part of the final
thirty conversations, not extra tests. Calibration time times three with 50%
headroom estimates the full duration. If it exceeds the budget, continuation
is refused until a smaller workload is approved. The cumulative measurement
clock spans calibration and remaining repetitions. Result extraction and the
interstage review are outside that clock. The hard budget still stops launches
if cooling or later repetitions exceed the estimate. No calibration is replayed.

## Storage and remaining work

Keep source in ExperimentalMachines/OpenWeights-iOS. After a terminal batch,
archive the complete evidence bundle in private `zeraphim/openweights-ios-artifacts`
using the repository's verified upload/download workflow. Reuse one source/build
snapshot per batch. Retain small raw reports, summaries and remote receipts locally.
No local evidence is deleted until a downloaded remote copy passes checksums and
archive checks. Public publication still requires review and explicit authorization.

After the batch is terminal, run:

```sh
python3 Publication/archive.py package Publication/outputs/YOUR_TERMINAL_BATCH
python3 Publication/archive.py transfer Publication/outputs/YOUR_TERMINAL_BATCH --evict-large
```

The packer verifies every ZIP member against its manifest. Transfer delegates to
`migration/archive_packages.py`, which rejects public buckets and performs a
fresh-download SHA-256/ZIP-CRC verification before deleting the execution ZIP.
Only after that proof exists can `--evict-large` remove xcresult/attachment trees.
Small raw reports, tables, snapshots, logs, member manifests and remote receipts
remain locally. The Qwen pilot handoff completed with verified private
round-trip checks. Its archived execution bundles were removed locally.

Measured work is complete. Public publication remains pending explicit approval.
The review draft is `docs/research/ios-publication-benchmark.md` in the repo root.
`completion-2026-10-07.json` records measured counts, exclusions and archive proof.
`protocol-freeze-2026-10-07.json` freezes metrics after the pilot.
`calibration-orchestration-2026-10-07.json` records the later host orchestration
change and verifies that metric calculations and factual scoring are unchanged.
`continuation-2026-10-07.json` records readiness and the completed pilot.
Attempts 0 and 1 were device-free pilot preparations. Attempt 2 is measured.

Host verification:

```sh
python3 -m unittest discover -s Publication -p 'test_*.py' -v
```
