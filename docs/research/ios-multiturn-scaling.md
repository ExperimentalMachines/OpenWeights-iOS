# iPhone 16 multi-turn scaling pilot

Date: 2026-10-02
Status: Implemented, executed and verified locally. All seven configurations have completed all six turns. The isolated Core ML retry succeeded after an earlier timeout. Corrected ExecuTorch MLX export verified. Cloud execution pending.

The isolated Core ML retry used the same export and workload with a 60-minute
allowance and completed in 18 minutes 38 seconds. Its earlier timeout remains
part of the evidence. The user previously confirmed the phone was unplugged,
and the retry required nominal temperature before loading.

This pilot checks six successive user turns with growing conversation history,
using the same Qwen3 0.6B checkpoint and quantization choices as the earlier
iPhone tests. ExecuTorch MLX required a larger exported prefill bound. The actual
assistant response becomes part of each subsequent prompt. It tests the current
adapters' conversation behavior, including their existing cache policies.

## Workload

W4-workshop-memory, version 1, is a hand-written synthetic conversation. The
initial message establishes a codename, city, budget and dietary rule. Logistics
notes expand the history, two decisions change, and turns 3, 5 and 6 test recall
of original and updated facts. It is a controlled context-growth test rather
than a diverse conversation dataset or a general quality benchmark.

The workload uses a 2,048-token ceiling and 64-token output cap. Baseline prompt
lengths grew from 92 to approximately 1,560 tokens. Each reported sequence uses
one conversation. Failed configurations were retried as documented below.
Prefix-enabled adapters then replay the same message arrays with
KV cache cleared before every request. ExecuTorch adapters already clear cache
internally, so they run one rebuild-each-turn sequence without a redundant replay.

The raw `memoryProbePassed` field requires both correct content and exact output
format. The analysis separately checks factual content, allowing a single JSON
code fence or surrounding punctuation on the one-word answer. This distinguishes
forgetting a fact from failing the requested formatting.

The inherited `cancellationPassed` row field remains false in this suite because
cancellation is not exercised here. Cancellation and recovery were verified in
the earlier single-turn pilot.

The first delegate attempt hit XCTest's default 600-second allowance during
Core ML turn 5, despite a maximum allowance of 1,800 seconds. `run.sh` now sets
both default and maximum to 1,800 seconds. The 30-minute retry also timed out,
during turn 6. Both partial checkpoints are retained. ExecuTorch MLX is run
separately so the Core ML timeout cannot prevent its measurement.

## Measurements

iPhone 16 (`iPhone17,3`), iOS 26.6.2 build 23G90, Release build with Xcode 26.5
and iOS 26.5 SDK. Low Power Mode was off. All baseline samples started and ended
at nominal thermal state. Model hashes were verified before timing. Two tests
passed with zero failures in 79.190 seconds. They cover 54 inference requests
and the strict probe grader. The corrected ExecuTorch MLX run passed two tests
with zero failures in 5.799 seconds, covering six requests and the grader. All
corrected MLX samples also started and ended at nominal thermal state. The
final baseline and delegate targets both compiled successfully.

These are single observations at each turn, not medians:

| ID | Configuration and current cache policy | Turn 1 first text, ms | Turn 6 first text, ms | Turn 1 tokens/s | Turn 6 tokens/s | Content probes | Strict probes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| O1 | llama.cpp CPU, retain prefix | 222.1 | 4,791.5 | 79.4 | 29.4 | 3/3 | 3/3 |
| O2 | ExecuTorch XNNPACK, rebuild history | 277.1 | 5,397.2 | 97.6 | 29.9 | 3/3 | 3/3 |
| O3 | llama.cpp full Metal, retain prefix | 94.7 | 1,537.0 | 103.5 | 77.8 | 3/3 | 3/3 |
| O4 | Standalone MLX Metal, retain prefix | 115.8 | 852.5 | 136.2 | 93.5 | 3/3 | 1/3 |
| O5 | llama.cpp partial Metal, retain prefix | 188.7 | 3,421.5 | 75.7 | 35.8 | 3/3 | 3/3 |
| O6 | ExecuTorch Core ML FP16, isolated retry, rebuild history | 25,503.7 | 449,893.9 | 3.5 | 3.4 | 3/3 | 2/3 |
| O7 | ExecuTorch MLX, corrected 2k prefill, rebuild history | 88.5 | 1,255.9 | 109.2 | 66.5 | 3/3 | 3/3 |

Standalone MLX retained all tested facts but wrapped both JSON responses in code
fences. That is a format failure, not evidence that it forgot the facts. Prompt
lengths differ slightly between engines because their generated responses become
history. Decoding throughput also depends on the particular generated tokens.

The CPU and full-Metal llama.cpp runs use the same GGUF and produced identical
conversation text in this pilot. Their throughput ratio grew from about 1.3x
at turn 1 to 2.6x at turn 6. This is a more controlled comparison than comparing
their quantized artifact with either MLX artifact, but it remains one sequence
with fixed runtime order.

## Core ML timeout and successful retry

The uncompressed FP16 Core ML CPU/GPU export completed five turns in the
30-minute retry. Its first-text times were 25.51, 79.18, 94.42, 170.98 and
547.29 seconds. Explicit prompt lengths were 92, 279, 334, 595 and 867 tokens.
The sixth request began, but no response completed before XCTest aborted the
test. The reconstructed next prompt contains 1,556 tokens and fits the context
with the output reserve. There is no measured turn-6 latency or throughput.

It passed both completed content probes. The final updated-facts probe is
unobserved. Thermal state rose from nominal to fair during turn 2 and stayed
fair through turn 5, so this run cannot isolate context growth from thermal
and resource effects. Its completed streaming rates were about 3.5 to 3.7
tokens/s for turns 1 through 4. Turn 5 generated only two tokens, making its
0.78 tokens/s estimate noisy.

This is a failed completion result for the current export and adapter. The
checkpoint's row remains `running` because XCTest terminated the process
before the harness could write a failure. `completed: false` and the recorded
XCTest timeout establish that it did not finish.

The subsequent isolated retry completed all six turns. Two XCTest tests passed
with zero failures in 1,118.344 seconds. Its first-text times were 25.50, 79.22,
93.81, 169.29, 246.03 and 449.89 seconds. Turn-6 streaming measured 3.448
tokens/s. The final JSON contained all four correct updated facts but was
wrapped in a code fence, so factual recall passed 3/3 and strict formatting
passed 2/3. Runtime test success does not imply every quality probe passed.

The model artifact manifest exactly matches the previous attempt. The first
five prompts and outputs were also identical. Turn 5 first text improved from
547.29 to 246.03 seconds. Thermal state stayed nominal through turn 3, became
fair during turn 4, and reached serious by the end of turn 6. Low Power Mode
was off. The user had confirmed the phone was unplugged before this retry.

The retry finished within the original 30-minute budget, despite being granted
60 minutes. A larger allowance alone therefore does not explain its completion.
Power, thermal and resource conditions were not independently controlled, so
the cause of the earlier extreme slowdown remains unresolved. The timeout is
not evidence that this export cannot complete a six-turn conversation. Both
attempts show that the current export is too slow for interactive chat.

## ExecuTorch MLX export boundary

The original MLX artifact declared a 512-token prefill chunk and 2,048-token
KV context. It completed turns 1 through 3 at 92, 280 and 339 prompt tokens,
then returned ExecuTorch error 16 (`NotSupported`) at turn 4. The reconstructed
next prompt contains 600 tokens, within the intended 2k context.

In the pinned export source, `LLMEdgeManager` bounds the dynamic input at
`max_seq_len - 1`, or 511 tokens for this artifact. The 1.5 runner's
`TextPrefiller` splits longer prompts into `max_seq_len` chunks, or 512 tokens.
The portable tensor implementation returns `NotSupported` when a resize exceeds
its bound. These source paths explain a likely off-by-one failure when chunking
first becomes necessary. The Release error does not expose the failing tensor,
so a dedicated 511/512-token native boundary test remains outstanding.

The local MLX export now sets `max_seq_length: 2048`, with an exported dynamic
input bound of 2,047. It uses the same checkpoint, quantization and 2k KV cache.
All prompts in this workload fit in one prefill, avoiding that chunk boundary.
This is a workload-specific export correction, not an upstream runner fix or
proof that arbitrary chunked prefill works. The original failed run and artifact
provenance remain separate from the corrected run. The corrected artifact is
646,789,248 bytes. It reproduced the first three outputs and histories exactly,
then completed all six turns and passed all three strict recall probes. Turn-6
prefill rebuilt 1,551 tokens. First text took 1,255.9 ms and streaming measured
66.5 tokens/s. Its peak sampled whole-process footprint reached 2,082.8 MiB.

The diagnosis uses the pinned ExecuTorch sources:
[dynamic export bounds](https://github.com/pytorch/executorch/blob/f7140a46ff38e919c557d45b102d3ff26097c8c9/extension/llm/export/builder.py),
[prefill chunking](https://github.com/pytorch/executorch/blob/v1.5.0/extension/llm/runner/text_prefiller.cpp),
and [bounded tensor resizing](https://github.com/pytorch/executorch/blob/v1.5.0/runtime/core/portable_type/tensor_impl.cpp).

## Cache observations

Standalone MLX reused 869 of 1,562 prompt tokens at turn 6. First text took
852.5 ms with reuse and 1,604.5 ms in the reset replay of the identical explicit
prompt. Its whole-process footprint peaked at 1,858.8 MiB in the retained-cache
sequence and 3,009.5 MiB during reset replay. Allocator and framework caches are
included, so these are not isolated KV cache sizes or proof of a memory leak.

The three llama.cpp configurations reused 604 tokens at turn 5, then only 72
at turn 6. This caused a large re-prefill. Source inspection found that
`Session::tokenize_prompt` looks for remembered reply text with a global first
match. The one-word reply `vegetarian` also appears in the seed user message.
Splicing the reply tokens at that occurrence changes the earlier prefix.

A host simulation using the pinned Qwen tokenizer reproduces divergence at
token 72, matching the device cache cutoff. It changes the final explicit
prompt from 1,559 to 1,561 tokens. `Session::reset` clears KV state but retains
reply records. This also explains why the reset replay of the first llama.cpp
prompt contains 94 tokens rather than its original 92.

This was a source-supported diagnosis with a matching tokenization simulation.
The subsequent [shared-engine fix](llama-reply-cache-fix.md) passed native sanitized
regressions and 99 iPhone requests. Corrected turn-6 cache reuse reached 866
tokens, and full-Metal first text measured 804.8 ms with unchanged outputs.
Its before/after evidence is tracked separately. The engine was not
changed during this original study. Consequently, llama.cpp reset
replays have identical message arrays but are not exact token-sequence controls.

## Limits and interpretation

The baseline data shows increased response latency and lower decoding throughput
as context grows. Prefix reuse helps, but its effectiveness depends on stable
tokenization. All seven configurations have now retained the tested original
and updated facts in a completed conversation. This establishes those three
probes in the tested conversations, not
general conversational reliability.

Comparisons use different quantizations, native templates and cache policies.
Runtime order is fixed, and reset replay follows the retained-cache sequence.
Very short probe responses yield noisy throughput estimates. Process memory
includes earlier work and framework caches. Power connection was not controlled
across all runs. The user reported charging during the post-Core ML cooldown
and unplugged before the successful MLX runs. Two MLX attempts stopped before
inference because the phone did not cool to nominal within three minutes.
No battery measurement, multiple devices, long-context overflow policy or
larger-model study was performed.

## Reproduce and evidence

From `ios/Benchmark`:

```sh
./build.sh
./run.sh YOUR_IPHONE_UDID --multi-turn
./build-delegates.sh
./run.sh YOUR_IPHONE_UDID --delegates --multi-turn
./run.sh YOUR_IPHONE_UDID --delegates --multi-turn --mlx-only
./run.sh YOUR_IPHONE_UDID --delegates --multi-turn --coreml-only --timeout-seconds=3600
.build/export-env/bin/python Export/analyze_multiturn.py \
  Results/iphone16-multiturn-baseline-2026-10-02.json \
  Results/iphone16-multiturn-coreml-30min-partial-2026-10-02.json \
  Results/iphone16-multiturn-mlx-512-failed-2026-10-02.json \
  Results/iphone16-multiturn-mlx-2k-2026-10-02.json \
  --allow-partial \
  --output Results/multiturn-analysis.json
```

The standalone app also offers the Six-turn conversation workload. Each request
is checkpointed to JSON, and the XCTest attaches complete or partial reports.
The default `run.sh` still selects only the original pilot test.

- [Workload fixture](../../ios/Benchmark/Resources/multiturn-workload.json).
- [Baseline raw report](../../ios/Benchmark/Results/iphone16-multiturn-baseline-2026-10-02.json).
- [Baseline source and executable fingerprint](../../ios/Benchmark/Results/iphone16-multiturn-baseline-source.json).
- [Multi-turn runner](../../ios/Benchmark/App/MultiTurnRunner.swift).
- [Analysis script](../../ios/Benchmark/Export/analyze_multiturn.py).
- [Checkpoint before the delegate timeout](../../ios/Benchmark/Results/iphone16-multiturn-coreml-timeout-partial-2026-10-02.json).
- [Core ML checkpoint after the 30-minute limit](../../ios/Benchmark/Results/iphone16-multiturn-coreml-30min-partial-2026-10-02.json).
- [Core ML source and executable fingerprint](../../ios/Benchmark/Results/iphone16-multiturn-coreml-source.json).
- [Original delegate export provenance](../../ios/Benchmark/Results/iphone16-coreml-fp16-export-provenance.json).
- [Original MLX export failed run](../../ios/Benchmark/Results/iphone16-multiturn-mlx-512-failed-2026-10-02.json) and [build fingerprint](../../ios/Benchmark/Results/iphone16-multiturn-mlx-512-source.json).
- [Corrected MLX raw report](../../ios/Benchmark/Results/iphone16-multiturn-mlx-2k-2026-10-02.json), [build fingerprint](../../ios/Benchmark/Results/iphone16-multiturn-mlx-2k-source.json), and [export provenance](../../ios/Benchmark/Results/iphone16-multiturn-mlx-2k-export-provenance.json).
- [Combined per-turn analysis and coverage](../../ios/Benchmark/Results/iphone16-multiturn-analysis-2026-10-02.json).
- [Successful Core ML retry raw report](../../ios/Benchmark/Results/iphone16-multiturn-coreml-retry-2026-10-02.json), [build fingerprint](../../ios/Benchmark/Results/iphone16-multiturn-coreml-retry-source.json), and [retry comparison analysis](../../ios/Benchmark/Results/iphone16-multiturn-coreml-retry-analysis-2026-10-02.json).

Baseline result bundle: `Results/pilot-multiturn-20261001T174510Z.xcresult`.
Baseline run ID: `B1D94E1D-66A7-4A01-AB08-1603DEE8E851`.

Corrected MLX result bundle: `Results/delegates-multiturn-mlx-20261001T185852Z.xcresult`.
Corrected MLX run ID: `5040981B-932D-4E45-9681-A0FE0CF97810`.

Build fingerprints retain the historical source hashes for each measured build.
The current harness adds isolated MLX selection and explicit timeout allowances.
Analysis preserves raw reports, distinguishes row failure from report completion,
and marks missing turns and probes as unobserved. The original combined analysis
retains the 30-minute Core ML timeout. The retry comparison is a separate file.

Successful Core ML retry result bundle: `Results/delegates-multiturn-coreml-20261001T190857Z.xcresult`.
Successful Core ML retry run ID: `294D5F3C-E43A-4DCD-B3ED-946A06464E03`.
