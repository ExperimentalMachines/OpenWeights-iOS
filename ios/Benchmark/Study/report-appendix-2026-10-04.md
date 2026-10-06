## Local validation of the older-iOS package, October 4

The immutable `gguf-ios16.6-v1` smoke and S1 packages now pass locally on iPhone 16, observed iOS 26.6.2. The smoke runs two tests and nine measured full-Metal requests with cancellation/recovery. S1 runs two tests and thirty-six measured samples across CPU, full Metal and fourteen-layer partial Metal, covering six retained-prefix turns plus matched-history reset replay. All S1 samples start/end at nominal thermal state. Each final-turn fact and JSON formatting probe passes. This is one independent block per configuration, below the five-block target. The separate analysis has no failed adapter rows.

[Exact package validation proof](../../ios/Benchmark/Results/retained-gguf16-local-validation-9f5bf2e44b05.json) retains original ZIP, executable, plan and archived-source hashes, raw XCTest evidence and validation-tool snapshots. The original source snapshot is authoritative because the working tree has later engine/collector changes. The collector can now use a verified retained execution receipt rather than restamping current inputs. An invalid archive hash is refused before altering results, and seven analysis regressions pass.

The original seven-runtime measurements and eighteen replicated cells above are unchanged. This package excludes MLX/ExecuTorch and has its own variant identity. Its local validation is not an iOS 16.6 compatibility result, older-device performance result or multi-device replication. The approved older-device cloud smoke outcome is recorded below. It produced no inference measurements and does not expand replicated cells. Public publication remains unauthorized.

The approved smoke matrix `matrix-1g8dydeuyj44q` finished on October 4. iPhone 11 Pro actually launched on iOS 16.6 (20G75) and passed the corruption-rejection test, but `testFirebaseSmoke` failed with a Hugging Face CDN connection timeout before model load. Its recovered report records `completed=false` and zero inference rows. iPhone 14 Pro ended with an inconclusive infrastructure failure and `Internal System Error 3`, after three attempts. Both devices' infrastructure attempts are retained. [Terminal cloud proof](../../ios/Benchmark/Results/firebase-gguf16-smoke-outcome-2026-10-04.json) distinguishes acquisition failure from infrastructure failure and retains the exact package/source fingerprints. These results establish no older-device inference, memory fit, throughput or cancellation result.

Tool Results reports ninety-five seconds for the 11 Pro test process, rounding to two physical execution minutes. That corresponds to about $0.17 without free allowance for this reported test time alone, using [Firebase's physical-device rate](https://firebase.google.com/docs/test-lab/usage-quotas-pricing). Remaining free minutes, storage, infrastructure-attempt billing and the actual invoice are unverified. This is not a total-job charge. No further cloud job or study replication is approved. Model acquisition needs investigation before another paid attempt. Cached local execution did not exercise this cold network path.


### Acquisition mitigation, local verification on 2026-10-04

After the older-iOS cloud timeout, the acquisition harness gained a three-attempt
transport retry limit and durable, sanitized acquisition events. It re-resolves
the original revision-pinned Hub URL, bypasses the local URL cache and retains
existing artifact byte/SHA checks. The existing 1800-second request timeout was
not increased. [Apple's connectivity documentation](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/waitsforconnectivity)
distinguishes connection establishment from an established connection dropping.
[Hugging Face's download reference](https://huggingface.co/docs/huggingface_hub/en/package_reference/file_download)
explains that resolved file addresses may be CDN links. Neither reference proves
the cause of this specific Firebase connection failure.

`Results/acquisition-retry-local-validation-f2abcb9fccf3.json` retains the exact
build/source/archive identity and nine passing native iPhone 16 tests. A unique
app temporary directory downloaded the complete pinned 396,705,472-byte GGUF from
`us.aws.cdn.hf.co`, HTTP 200, in 6,794.49 ms, followed by successful SHA verification.
The smoke reused the independently verified persistent cache and passed nine
Metal inference requests with cancellation/recovery. Six injected transport
controls passed on Mac and iPhone. These controls establish bounded retry and
rejection behavior, not a successful real-world failed-connection recovery. A
single successful local fresh download is not an OS/CDN cache cold-start metric,
an older-OS compatibility result, an inference ranking or a study replication.
No results were added to the study comparison cells. This new source cohort also
uses current shared-engine inputs, distinct from the historical older-iOS package.

The separately approved iPhone 11 Pro smoke retry ran on October 6 as matrix
`matrix-rkai0yp5no1ma`, requesting iOS 16.6, Xcode 26.2 and a five-minute limit.
It finished inconclusive after three automatic infrastructure attempts, all with
`Internal System Error 3`. No usable XCTest/inference attachment or device log was
exposed. The terminal result bucket contains only the uploaded package, whose
remote byte count/MD5 match the approved local ZIP. Actual OS and whether the app
ever started are unverified. [Terminal retry proof](../../ios/Benchmark/Results/firebase-iphone11pro-acquisition-retry-2026-10-06.json)
retains approval, source/package identities, metadata and all attempts.

The 648.094-second Tool Results step duration is not verified billable device time
or XCTest process time. The requested execution estimate was up to $0.42 without
free allowance, excluding storage and automatic infrastructure attempts. Remaining
free minutes and actual charges are unknown. No study cells were added, and no
further cloud job or study replication is approved. The original cloud acquisition
failure remains unresolved. Per-request timeouts remain 1800 seconds, so transport
retries do not guarantee completion within the five-minute job limit.


### First isolated Core ML study block, 2026-10-06

The current signed f1266a1174ae delegate build completes S1 block 0, attempt 0
on iPhone 16, iOS 26.6.2 (23G90). Both harness methods pass, six generations
complete and there is no runtime row error. Content is scored separately: 2/3
factual probes and 3/3 strict-formatting probes pass. Turn 5 returns `diet` rather
than `vegan`. Final JSON correctly returns Birch, Porto, 620 and vegan. That
inconsistent response does not demonstrate that all earlier facts were lost.

| Turn | Native logged prompt tokens | First text, seconds | Thermal start/end |
| --- | ---: | ---: | --- |
| 1 | 78 | 21.55 | nominal/nominal |
| 2 | 256 | 72.05 | nominal/nominal |
| 3 | 319 | 89.92 | nominal/nominal |
| 4 | 560 | 158.03 | nominal/fair |
| 5 | 817 | 230.98 | fair/fair |
| 6 | 1,505 | 427.60 | fair/serious |

Six ordered native observer records match the six report generation counts and
show roughly 3.5-3.6 prompt tokens/s. The latency pattern is consistent with
rebuilding growing history through this static one-token FP16 CPU/GPU export.
It is not a general Core ML limit or a cache-corruption diagnosis. Largest sampled
whole-process footprint including model load is 2,396.3 MiB. The initial nominal
guard passes and low-power mode is off. Charging during this run is unmeasured.
Thermal effects, runtime-only causation, Neural Engine placement and energy are
not isolated or measured. Report prompt-count fields remain nil, with these
counts retained as supplementary native log evidence.

[Terminal native proof](../../ios/Benchmark/Results/study-coreml-isolated-20261006T072830Z-verification.json)
retains raw XCTest, checkpoints and unchanged source/plan/executable controls.
[Grading and native-log interpretation](../../ios/Benchmark/Results/coreml-study-S1-first-block-observer-f1266a1174ae.json)
binds exact outputs, prompt hashes, counts and analysis code. Historical delegate
products are preserved. The exact local-tested package is prepared but no new
cloud job is approved or submitted. Ordinary OpenWeights is restored and its
live PID 70108 is verified after the run.

`Results/study-analysis-coreml-first-block-v3-2026-10-06.json` now includes forty
raw reports. The ledger still has eighteen of sixty-three replicated cells.
This single Core ML primary block is below the five-block threshold and is
excluded from the replicated comparison tables. The existing six-configuration
figures retain their frozen thirty-nine-report inputs and unchanged outputs.
Core ML repetition, other scenarios and multi-device replication remain open.


### Second isolated Core ML S1 block, 2026-10-06

The unchanged f1266a1174ae build completes independent primary block 1, attempt 0
on local iPhone 16, observed iOS 26.6.2 (23G90). Both native methods pass,
with six successful generation samples and no runtime row error. A separate
native snapshot immediately before this run reports nominal temperature,
unplugged battery state and 65-percent charge. This is not a measurement of
charging conditions throughout inference. Low-power mode is false.

| Independent primary block | Turn 1 first text | Turn 6 first text | Factual probes | Strict formatting | Largest sampled whole-process footprint |
|---|---:|---:|---:|---:|---:|
| 0 | 21.55 s | 427.60 s | 2/3 | 3/3 | 2,396.3 MiB |
| 1 | 21.46 s | 450.24 s | 2/3 | 3/3 | 2,369.1 MiB |

Both blocks return diet instead of vegan on turn 5, then return all four exact
facts in the final valid JSON. This repeated error does not establish loss of
all earlier facts or cache corruption. Block 1 again rebuilds each turn with
zero cached tokens. Its six native observer prompt counts match block 0,
from 78 to 1,505 tokens. Thermal start/end pairs again progress from 0/0 to
1/2. No causal thermal, energy, Neural Engine or general Core ML claim follows.

Forty-one raw study reports now retain eighteen of sixty-three replicated
planned cells. The two matching Core ML S1 blocks remain below five required
independent blocks, and are excluded from replicated comparisons. All earlier
raw reports and the twelve historical six-configuration figure outputs remain
preserved. Core ML S2/S3 and multi-device replication remain incomplete.

[Second block terminal evidence](../../ios/Benchmark/Results/study-coreml-S1-stable-facts-block1-20261006T075958Z-verification.json).
[Second block observer and grading](../../ios/Benchmark/Results/study-coreml-S1-stable-facts-block1-20261006T075958Z-observer.json).

One cloud Core ML S1 block on Firebase iPhone 16 Pro, catalog iOS 18.3, Xcode
26.2, is explicitly approved with a 45-minute limit. The exact package upload
completed and matrix matrix-q3m2ckgb6793a is queued on one iPhone 16 Pro.
No cloud inference result is available yet. This approves one primary block
only, not further paid replication jobs.

The cloud object byte count and MD5 match the exact local-tested ZIP. The
[immutable submission proof](../../ios/Benchmark/Results/firebase-coreml-S1-approved-submission-2026-10-06.json)
binds the approved command, device/toolchain/timeout, object generation and
twenty hashed evidence files. Queuing is not an inference or actual-OS result.


### Third isolated Core ML S1 block, 2026-10-06

Independent primary block 2, attempt 0 completes on the same iPhone 16 / iOS
26.6.2 (23G90), using unchanged f1266a1174ae binaries and artifacts. Both
native methods pass, with six generation samples and no runtime row error.
The native preflight at 08:23:46 UTC measures nominal temperature, unplugged
state and 55-percent charge before this run.

Block 2 first text is 22.23 seconds at turn 1 and 430.87 seconds at turn 6.
Largest sampled whole-process footprint including load is 2,391.8 MiB. Its
six outputs match the earlier two blocks: diet on turn 5, followed by final
valid JSON with Birch, Porto, 620 and vegan. Each block scores 2/3 factual
probes and 3/3 strict formatting probes. This repeated response error on a
synthetic prompt is not general quality, lost-context or cache-corruption proof.

Block 2's thermal start/end pairs are 0/0, 0/0, 0/1, 1/1, 1/2 and 2/2.
Compared with the first two blocks, it reaches fair/serious earlier. No
causal thermal or energy conclusion follows. Raw prompt-count fields remain
nil, with counts supplemented by six native observer records. The rejected
restricted native preflight and two failed checkpoint-collection attempts are
retained separately before successful system-access collection. Inference
was never restarted, and neither failure represents a measured model failure.

Forty-two retained reports still satisfy eighteen of sixty-three planned
replication cells. Three matching Core ML S1 primary blocks remain below five,
so the existing replicated comparisons and twelve figure outputs are preserved.
Core ML S2/S3 and the full multi-device study remain incomplete.

[Third block terminal evidence](../../ios/Benchmark/Results/study-coreml-S1-stable-facts-block2-20261006T082415Z-verification.json).
[Third block observer and grading](../../ios/Benchmark/Results/study-coreml-S1-stable-facts-block2-20261006T082415Z-observer.json).


### Fourth isolated Core ML S1 block, 2026-10-06

Primary block 3, attempt 0 passes both native methods with six completed
generations on the unchanged iPhone 16 / iOS 26.6.2 cohort. Turn 1 first text
is 20.79 seconds, and turn 6 is 440.20 seconds. Largest sampled whole-process
footprint including load is 2,368.6 MiB. All six outputs match the preceding
three blocks, with 2/3 factual probes, 3/3 formatting probes, diet on turn 5
and all four facts in final JSON. Native observer prompt counts again grow
from 78 to 1,505, with zero cached tokens and rebuild-each-turn policy.

Thermal pairs are 0/0, 0/0, 0/0, 0/1, 1/1 and 1/2. Preflight at 08:49:24 UTC
measures nominal/unplugged conditions and 40-percent charge before inference.
The final failed checkpoint pull is preserved separately from successful
terminal attachment recovery. All compiled inputs and historical delegates
remain unchanged. The two post-run ordinary-app installation attempts fail
with connection-reset transport errors. App restoration awaits reconnection
and is not claimed complete.

Forty-three raw reports retain eighteen replicated planned cells. Four
matching local Core ML S1 primary blocks remain below the required five.
The existing twelve historical figure files are unchanged.

[Fourth block observer and grading](../../ios/Benchmark/Results/study-coreml-S1-stable-facts-block3-20261006T085005Z-observer.json).
[Fourth block terminal evidence](../../ios/Benchmark/Results/study-coreml-S1-stable-facts-block3-20261006T085005Z-verification.json).


### Approved cloud Core ML S1 block completed, 2026-10-06

Matrix matrix-q3m2ckgb6793a finishes SUCCESS on its first attempt. Native
XCTest and the recovered raw attachment independently verify iPhone 16 Pro
(iPhone17,1), actual iOS 18.3.2 (22D82), rather than the catalog label 18.3.
Both native methods pass with no failures/skips. All six generations complete
with verified bundled asset hashes and unchanged study settings.

| Measure | Cloud Core ML S1 block 0 |
|---|---:|
| Turn 1 first text | 24.25 s |
| Turn 6 first text | 492.70 s |
| Model load | 33.87 s |
| Sum of six request durations | 1,191.38 s |
| Largest sampled whole-process footprint including load | 2,674.9 MiB |
| Factual probes | 2/3 |
| Strict formatting probes | 3/3 |

Outputs and all six rendered prompt hashes match the fourth local block.
Turn 5 returns diet instead of vegan. Final valid JSON retains all four facts.
Supplementary observer prompt counts grow from 78 to 1,505. Raw prompt-count
fields remain nil, cache counts zero, and policy rebuild-each-turn. Thermal
pairs are 0/0, 0/0, 0/1, 1/1, 1/1 and 1/2. There is no cloud charging/battery
preflight, energy measurement or verified Neural Engine placement. S1 does
not test cancellation, so its false cancellationPassed field is not a failed
cancellation check. Firebase prepares/signs the uploaded app. Its executing
resigned binary hash is not independently measured.

The final cloud reply takes longer than each of the four local blocks, but
this is one cloud block on different hardware and OS with different operating
conditions. It does not establish that the Pro is slower, or a thermal cause.
The measured static-step FP16 CPU/GPU artifact remains too slow for interactive
conversation in these runs. This is not a claim about Core ML generally.

Firebase reports 1,281 seconds of test-process time. At the published physical
device rate and minute rounding, estimated execution is $1.83 with no free
allowance, below the approved 45-minute $3.75 request limit. Actual invoice,
remaining free allowance and storage/transfer charges are unverified. Setup,
installation and results collection are excluded from this execution estimate.
[Firebase pricing](https://firebase.google.com/docs/test-lab/usage-quotas-pricing).

Forty-four raw reports now retain eighteen of sixty-three replicated cells.
Core ML has four matching local S1 blocks and one distinct cloud Pro S1 block,
each below five. Combining their block counts would violate the device/OS
cohort rule. Core ML S2/S3 and full device replication remain open. This single
paid-job approval is consumed. No additional paid replication is authorized.
The terminal matrix, exact package identity, ToolResults, native bundle,
attachment, logs, grading, actual OS and cost estimate are retained as 118
hashed files in a checked immutable archive.

[Cloud terminal evidence](../../ios/Benchmark/Results/firebase-coreml-S1-terminal-2026-10-06.json).
[Cloud observer and strict grading](../../ios/Benchmark/Results/firebase-coreml-S1-terminal-2026-10-06-observer.json).


### Bundled older-device GGUF packages prepared, 2026-10-06

A separate gguf-ios16.6-bundled-v1 package now includes the exact pinned
396,705,472-byte Q4_K_M model, verified before build and inside both signed
archives. The selected smoke and S1 methods use existing ModelStore bundle
verification rather than a Hugging Face download. All workload bytes, strict
graders, thread/offload/context/decoding controls remain unchanged. Raw runtime
metadata explicitly identifies the delivery variant, preventing cohort pooling.

The initial build guard rejected comparison with current shared-engine sources:
its older native archives correspond to earlier sources. The corrected recipe
binds all twelve reused libraries to their matching frozen source receipt and
archive. It copies that archive's Native headers and confirms the bridge headers
match current Swift callers. It does not compile current shared-engine changes
into old libraries or represent the old archives as current product binaries.

The first signed candidate includes Hugging Face download-cache files in its
resources. It remains retained and is superseded by clean build 0104eef7f0e4,
whose model folder contains only the pinned GGUF. App and test Mach-O minimum
OS are both 16.6. Signing, package/source archive integrity, exact model bytes
and selected smoke/S1 plans pass inspection. Canonical benchmark sources,
twelve frozen native libraries, five prior product directories and current
Core ML inputs remain unchanged.

Smoke package OpenWeightsGGUFBundledBench-smoke-6411575bf29e.zip is
396,313,417 bytes. S1 package OpenWeightsGGUFBundledBench-S1-e526baa0d3f9.zip
is 396,313,444 bytes. Both still require exact local validation before a new
older-device cloud proposal. The iPhone currently requires its passcode. No
inference, successful actual iOS 16.6 execution, repaired CDN timeout or new
replicated cell is claimed. No older-device cloud job is approved or submitted.
This supplement cannot replace the original seven-runtime/device matrix.

[Bundled delivery protocol](../../ios/Benchmark/Study/older-ios-bundled-gguf-addendum.json).
[Clean signed package proof](../../ios/Benchmark/Results/gguf16-bundled-package-revalidation-0104eef7f0e4.json).

### Five local Core ML S1 blocks verified, 2026-10-07

The fifth matching local primary block completed six generations and two XCTest
methods with no failures or skips. All five blocks retain four facts in the
final JSON and return the same wrong diet answer at the earlier vegan probe.
Turn-6 first text has a median of 440.20 seconds and an interquartile range of
430.87 to 447.56 seconds. The native logs retain prompt counts from 78 to 1,505
tokens. The 80-percent, unplugged, nominal preflight describes conditions before
block 4 only. Its final sample ends at serious temperature. No energy or Neural
Engine placement was measured.

The 45-report analysis retains failed and partial runs and now satisfies 19 of
63 planned device/runtime/scenario cells. The added seven-configuration S1
figure compares five matching complete blocks per configuration. Earlier
six-configuration S1-S3 figures remain unchanged. The separate cloud Core ML
cohort still has one block. Core ML S2/S3, multi-device replication and full
product parity remain incomplete. Nothing has been publicly published.

[Fifth-block raw interpretation](../../ios/Benchmark/Results/study-coreml-S1-stable-facts-block4-20261006T161607Z-observer.json).
[Reproduction proof](../../ios/Benchmark/Results/coreml-local-five-cloud-one-analysis-revalidation-2026-10-07.json).
