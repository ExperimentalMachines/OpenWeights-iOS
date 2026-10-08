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

## SE 3 native launch diagnostic, 2026-10-07

After the two retained infrastructure-only failures, a separately approved model-free control passed one native XCTest on SE 3, actual iOS 18.4 build 22E240. Matrix matrix-2pv90jl9ezi09 returned native logs and a device-conditions attachment. All 33 provider objects were downloaded at recorded generations and verified by size and MD5. The exact package, full proof and inactive signed build were retained in private Hugging Face storage after fresh-download SHA-256 and archive or full-tree checks.

This control contains no models or inference libraries. It establishes that this Firebase device cohort can launch XCTest and return an attachment. It does not explain the earlier infrastructure failures, establish model fit or complete a study cell. Verification and private restore locations are recorded in migration/firebase-SE-device-health-verification-2026-10-07.json in the separate iOS repository.

## SE 3 full-Metal smoke, 2026-10-07

The subsequent separately approved full smoke, matrix-2fgikhy1zqvy7, passed both native methods on SE 3, actual iOS 18.4 build 22E240. Its nine llama.cpp Metal requests include cancellation and recovery. Corruption rejection passed. All request thermal boundaries were nominal and Low Power Mode was off. The pinned 396,705,472-byte GGUF download appears in native logs. The unchanged source verifies its byte count and SHA-256 before adapter loading. This historical smoke has no per-file acquisition attachment.

All 36 provider objects were downloaded at recorded generations and verified by size and MD5. The 59-member proof and exact signed input package were retained privately after fresh-download SHA-256 and ZIP CRC checks. migration/firebase-SE3-full-smoke-verification-2026-10-07.json records the exact sources, signatures, raw report, native summary and private restore locations. This establishes the tested full-Metal smoke on SE 3. It does not explain earlier infrastructure-only failures, validate other configurations, establish growing-conversation fit or add any repeated-study cell. No hardware-only, energy or general-quality claim follows.


## SE 3 baseline acquisition failure, 2026-10-07

The separately approved five-configuration compatibility pilot,
matrix-2jipxlz5aijb0, finished with one native pass and one failure on SE 3,
actual iOS 18.4 build 22E240. Corruption rejection passed. The pilot failed
while downloading the pinned XNNPACK `Qwen3-0.6B-8da4w-2k.pte`, with
NSURLErrorDomain code -1005, network connection lost. Its retained partial
report has zero adapter rows and no inference requests. This provides no
runtime compatibility, memory-fit or performance result.

All 36 provider objects passed generation, size and MD5 checks. The complete
59-member failure proof and exact historical input package passed private HF
fresh-download SHA-256 and ZIP CRC verification before local ZIP eviction.
`migration/firebase-SE3-baseline-pilot-failure-retention-2026-10-07.json`
records the raw report, native summary, sanitized failure and private restore
locations. The original signed package lacks the bounded pinned-URL retries
already present in the separately validated current baseline build. A current
build candidate preserves its locally passed three-method plan and 45-request
pilot, with per-file acquisition events. Preparation does not establish that
Firebase downloads have recovered. A new job requires fresh approval. Local
phone tests remain held, and no repeated-study cell is added.


## Cloud Core ML block 4 storage failure and load-metric correction, 2026-10-07

Matrix matrix-2taqpjj8qiv6h passed probe grading but failed its study method on
Pro iOS 18.3.2 build 22D82. The raw metadata confirms S1 block 4, attempt 0,
with the exact separately submitted plan. All three bundled Core ML files
passed byte/hash verification. Model initialization then failed saving its
compiled model to disk, with ExecuTorch error 35. Device APFS syslog records
seven ENOSPC entries for OpenWeightsBench at the same time, meaning no space
left on the device. Zero inference samples were produced. The source of
occupied device space and any safely removable files remain unverified.

The failed primary attempt remains in the denominator. Core ML S1 on this
cloud cohort still has four of five complete matching primary blocks, and
overall replication remains 19 of 63 cells. Report-level `completed=true`
means the runner finished saving its terminal diagnostic. Its runtime row is
`failed`, so this report cannot satisfy replication.

The failure also exposed unmeasured load defaults of zero in the analysis.
Analysis schema 4 excludes zero/missing defaults from load-time and footprint
distributions, records their excluded counts, and retains real positive load
measurements even if generation fails later. Grading remains version 3.
The original schema-3 51-report analysis, report and analyzer are preserved
in the failure proof. In schema 4, this cloud load cohort has five primary
attempts but four measured loads and four complete conversations. New host
controls cover both cases. No zero-time or zero-memory load is claimed.

`migration/firebase-coreml-S1-block4-failure-retention-2026-10-07.json` records
raw/native evidence, exact input bindings, the device disk-write failure and
reproducible expanded analysis. This failure does not establish poor inference
quality, lack of RAM or a new runtime speed result. No further paid Pro job is
authorized, and local phone tests remain held.


## SE 3 current-build baseline compatibility, 2026-10-07

The separately approved retry, matrix-yuec0dllq1q3a, passes all three native methods on SE 3, actual iOS 18.4 build 22E240. The current separate-checkout baseline completes 45 requests across llama.cpp CPU, full Metal, partial Metal, standalone MLX and ExecuTorch XNNPACK. Each configuration completes its cancellation and recovery checks. Corruption rejection and the grading controls also pass. Every recorded request starts and ends at nominal thermal state, with Low Power Mode off. Cloud charging state and ambient temperature remain unknown.

The native attachment retains 24 acquisition events: 12 starts and 12 fresh download verifications, totaling 1,256,035,493 bytes. All files succeed on attempt 1 after the frozen ModelStore checks their exact sizes and SHA-256 values. No cloud transport retry is exercised. The six host acquisition controls establish the retry branch separately. This result does not prove improved network reliability. The earlier historical package's network failure remains preserved.

All 38 provider objects are downloaded at recorded generations and verified by size and MD5. The signed input package, source snapshot, exact test plan, immutable submission, native summary and complete evidence are bound in migration/firebase-SE3-current-baseline-pilot-verification-2026-10-07.json. This is compatibility evidence for the five tested configurations. Core ML, ExecuTorch MLX and growing-conversation study runs remain unverified on SE. No primary study block, replicated cell, universal memory-fit result, hardware-only, energy or general-quality claim is added.


## Pro read-only storage diagnostic, 2026-10-07

The separately approved model-free diagnostic, matrix-2vhswnu8naude, passed both native methods on iPhone17,1, actual iOS 18.3.2/22D82, using Xcode 26.2. Its exact signed package is 1f6471b04ea98e5fe5e097b2b4f4477739bfdff7189fb92a488f44cd6fe876cf. Full provider evidence verifies 37 objects and 2,443,300 bytes by stable generation, size and MD5. XCTest XML and xcresult agree on two passes, zero failures/skips. No models, inference or cleanup were performed.

At the recorded instant, filesystem free and available capacity both measured 81,467,404,288 bytes, approximately 75.9 GiB. Important-usage available capacity measured 85,360,284,861 bytes and may include purgeable space. The three default app-owned Core ML cache/trash/database directories were missing in this fresh diagnostic sandbox. This does not measure the prior app cache or Core ML peak disk demand. Private provider evidence establishes a different reported physical-device identifier from the failed block 4. The new snapshot therefore cannot establish the failed phone's capacity, occupied-space ownership, or an ENOSPC fix. Core ML Pro S1 remains 4 of 5 complete primary blocks, and the full study remains 19 of 63 replicated cells. All local phone tests remain held.

[Native diagnostic verification](../../migration/firebase-Pro-storage-diagnostic-verification-2026-10-07.json) binds exact input, source, executable, native attachments and full evidence retention. The read-only diagnostic does not authorize another paid job.


## Current SE S1 infrastructure outcome, 2026-10-07

The approved current-build S1 block 2, matrix-phcho7u3nupba, ended inconclusive with Internal System Error 3 after three automatic infrastructure attempts. The terminal Tool Results step explicitly reports infrastructure failure and has zero native case records or suite summaries. A full job-root listing contains only the exact submitted input ZIP, whose generation, size, MD5 and SHA-256 match the approved package. No native study attachment or inference measurement is observed. Actual physical device and OS are unknown. These records do not identify the infrastructure root cause or establish runtime incompatibility, model fit, memory failure or performance.

The original SE compatibility pilot remains a separate 45-request success. All three infrastructure-only SE study submissions remain in the execution ledger. The current job input and its identical provider-returned copy share one verified private HF object. All available provider metadata, approvals, source/plan receipts and restore locators are retained in migration/firebase-SE3-current-study-S1-block2-infrastructure-retention-2026-10-07.json. Study coverage remains nine of 63 source/build-matched cells, with 51 raw inference reports and 16 failed runtime rows. No synthetic inference report was added. The one-job approval is exhausted, and all local phone tests remain held.
