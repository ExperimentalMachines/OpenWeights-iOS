# Reduced benchmark continuation goal

Paste the following instruction after `/goal` if you want autonomous continuation.
This replaces the broad goal for active work. Its historical evidence and parked
checklist stay preserved. This file does not itself resume phone tests.

```text
Finish the reduced OpenWeights iOS publication benchmark using the existing
Publication profile in:
/Users/zeraphim/Documents/Files/ThisIsZeraphim/Open Source/ExperimentalMachines/openweights-ios

Read AGENTS.md and ios/Benchmark/Publication/README.md. Keep all work in the
separate private ExperimentalMachines/OpenWeights-iOS repository. Preserve the
previous A1-A3 evidence and docs/testing/2026-10-07-benchmark-and-test-checklist.md.
That broad study and app-parity work are parked. Do not resume them.

G1. Finish the narrow runner's signed Release build and necessary host checks.
Reuse one build per batch. Keep acquisition separate from measurement, prevent
downloads during measurements, and capture every completed turn automatically.
Use direct hosted XCTest, serial configurations, native keep-awake, bounded
cooling/timeouts, checkpointing, fresh-process evidence and no automatic retries.

G2. Validate the reusable protocol first with pinned Qwen3-0.6B GGUF on llama.cpp
CPU and full Metal on my iPhone 16. Use the unchanged S1 stable-facts six-turn
conversation, three repetitions per configuration, 2k context, greedy decoding,
thinking disabled, and maximum 64 generated tokens per reply. Skip reset replays,
interruption tests and other runtime suites. Report four metrics: first-response
delay, streaming tokens/s, peak app memory and factual recall, separating strict
format correctness. Exclude replies below eight tokens from headline throughput.
Show first-versus-sixth-turn timing and explicit missing/failed denominators.

G3. Pin and check GGUF compatibility for the five Android comparison models:
Gemma 3 1B IT, LFM2.5 1.2B Instruct, Qwen3 1.7B, Llama 3.2 3B Instruct and
SmolLM3 3B. Use identical GGUF bytes for CPU versus Metal. Identify any difference
from the Android artifacts or workload and avoid direct hardware claims from
unmatched studies. Add no ExecuTorch/Core ML/MLX exports for this first article.
Freeze the protocol after the pilot. Estimate the broader batch's duration before
launching it. If it will not fit, propose a smaller workload and wait for my answer.

G4. Run the five-model comparison with a hard 60-minute measurement budget per
batch. Preparation/downloads and bounded post-run result extraction are separate.
Retain incomplete/failed runs and stop new launches at the first failure or budget
exhaustion. Investigate only what prevents collecting these four metrics. Do not
expand into another comprehensive correctness or platform-parity campaign.

G5. Produce a review-ready comparison table, CSV, small raw JSON reports, artifact
hashes, workload/protocol snapshots, source/build provenance and clear limitations.
Archive large completed evidence privately in zeraphim/openweights-ios-artifacts,
verify by downloading and checking hashes/archive integrity, then retain remote
receipts and remove only those verified local copies. Automate this archival
handoff if needed. Reuse the repository's existing storage workflow.
Prepare conclusions suitable for Experimental Machines and, if the evidence
warrants it, Experimental Intelligence. Do not publish publicly without approval.

All phone tests remain held until I explicitly confirm the phone is ready for
this new benchmark. Finish independent preparation meanwhile. Ask once for
readiness, then wait rather than repeatedly polling, rebuilding or asking for
unlock. If a run locks or fails, preserve it and report the blocker before another
attempt. Do not use computer use. Do not submit Firebase jobs or incur paid cloud
execution. Do not accept new licenses without approval. Do not commit or push
unless I request it. Report implementation, compilation and measured validation
as separate statuses. Finish with the results and any specific remaining blockers.
```
