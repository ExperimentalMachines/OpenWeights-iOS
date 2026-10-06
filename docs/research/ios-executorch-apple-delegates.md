# ExecuTorch Apple delegate benchmark on iPhone 16

Date: 2026-10-02
Status: Implemented, executed locally, and verified by XCTest. Core ML answer quality is unacceptable in this export. Cloud execution pending.

ExecuTorch MLX and Core ML now run through the same benchmark harness as the
initial five configurations. Both passed the runtime checks. MLX returned
coherent answers at 111.4 streaming tokens/s. The baseline Core ML export ran at
4.0 tokens/s and produced repetitive, incorrect text. It is not a suitable chat
candidate in its current form. No Neural Engine performance result was obtained.

These are the initial channelwise-int4 Core ML measurements. A subsequent
[export validation](ios-coreml-export-validation.md) isolates compression error
and switches the current CPU/GPU export to uncompressed FP16. The results and
fingerprints below remain evidence for the original artifact.

## Measurements

Device: iPhone 16 (`iPhone17,3`), iOS 26.6.2 build 23G90. Xcode 26.5, iOS 26.5
SDK, Release build. Low Power Mode was off and every sample started and ended at
nominal thermal state. Model checksums were verified before timing.

Medians over three fresh-context short prompts:

| ID | Configuration | Weight compression and cache | Streaming tokens/s | First text, ms | Output tokens |
| --- | --- | --- | ---: | ---: | ---: |
| O6 | ExecuTorch Core ML, CPU_AND_GPU | Channelwise int4, FP16 KV cache | 4.0 | 10,323.1 | 64 |
| O7 | ExecuTorch MLX Metal delegate | TorchAO int4 linear weights, group 32, FP16 embeddings and KV cache | 111.4 | 49.3 | 61 |

Streaming throughput uses `(generated tokens - 1) / (last callback - first
callback)`. First text includes prompt preparation and detokenization. Core ML
uses static single-token steps for both prefill and decode. MLX supports dynamic
prefill chunks up to 512 tokens. Both reset cache before each request, use a 2k
context ceiling, and decode greedily with thinking disabled and a 64-token limit.

The [initial five-configuration pilot](ios-benchmark-pilot.md) measured standalone
MLX at 137.2 tokens/s. That was a separate run with a different quantized artifact
and prefix reuse. These numbers do not isolate the overhead of an ExecuTorch
delegate or establish a production default.

## Runtime validation and answer quality

The successful XCTest ran for 399.051 seconds with one test and zero failures.
Each candidate completed three short conversations and their follow-ups, one
longer prompt, cancellation after three callbacks, and generation afterward.
The suite checks successful execution, nonempty streamed output, the output
limit, cancellation, and recovery. Passing these checks is not an answer-quality
grade.

The original five-configuration suite also passed after these shared runner
changes: 45 requests, one XCTest, zero failures, 32.052 seconds. The original
pilot report and fingerprint remain unchanged.

Core ML's repeated short answers incorrectly referred to chlorophenol and became
repetitive. Its longer answer copied the garden description repeatedly rather
than summarizing it. MLX's corresponding answers used chlorophyll and summarized
the garden in two sentences. The full outputs are retained. The cause of the
Core ML degradation has not been established. Quantization and numerical
differences need investigation before using this candidate for chat.

The first Core ML export failed because coremltools does not accept symbolic
scalar values across its tensor-only delegate boundary. The local export adapter
keeps those operations outside Core ML. An iPhone load then rejected the int8
gather generated from the boolean causal mask. An additive float mask preserves
the attention rule and avoids that conversion. The adapter checks boolean-mask
and additive-mask attention equivalence with PyTorch before export.

An ALL-compute-units attempt subsequently failed Neural Engine compilation and
the XCTest process was killed during model loading. The result bundle reported
`Test crashed with signal kill.` It did not establish the cause of the kill.
The successful configuration explicitly permits CPU and GPU execution and uses
FP16 cache instead of FP32. These are separate configuration changes, so the
successful run does not establish which change prevented the process exit.
Neither ANE throughput nor per-operation device placement was measured.

## Integration and evidence

The delegate suite uses a separate app build because ExecuTorch MLX bundles its
own MLX C++ library. Linking it alongside standalone MLX Swift would combine
independently pinned implementations with overlapping symbols. The separate
target compiles the same Swift runner with two configurations. It targets iOS 18
and uses the official ExecuTorch 1.5 Swift package. Its packaged tokenizer already
includes the PCRE2 lookahead fallback required by Qwen.

Both models were exported locally from `Qwen/Qwen3-0.6B` revision
`c1899de289a04d12100db370d81485cdf75e47ca`. Python, Swift package, source checkpoint,
export configuration and artifact hashes are recorded. The models are bundled
with the delegate test app, totaling 980,353,614 bytes including tokenizers and
provenance. They have not been published to Hugging Face.

- [Raw results](../../ios/Benchmark/Results/iphone16-delegates-2026-10-02.json), all 18 samples.
- [Source and executable fingerprint](../../ios/Benchmark/Results/iphone16-delegates-source.json).
- [Export provenance](../../ios/Benchmark/Results/iphone16-delegates-export-provenance.json).
- [Build, export and run instructions](../../ios/Benchmark/README.md#executorch-apple-delegates).
- [Upstream Qwen3 export instructions](https://github.com/pytorch/executorch/blob/v1.5.0/examples/models/qwen3/README.md).
- [Pinned iOS package](https://github.com/pytorch/executorch/blob/56cc93a96d5fb8d21554ec5f00fbad5a5b228bc4/Package.swift).

Process footprint samples include allocators and caches from earlier work in the
same process. They are not isolated engine memory requirements. No battery-energy
measurement, sustained-load study or formal answer-quality benchmark was made.
This remains one phone and three short-prompt repeats. The signed delegate XCTest
archive was prepared locally. No Firebase test was submitted. A supported Xcode
toolchain is still needed before cloud execution.


## Later product quality diagnostic, 2026-10-06

The earlier benchmark completion and content checks did not test the later exact arithmetic prompt. [Controlled reference evidence](../../ios/Benchmark/Results/executorch-mlx-arithmetic-controls-f9f127e33691.json) now preserves twenty short greedy evaluations across HF FP32/FP16, converted ExecuTorch FP32 without cache/export, HF int4 and native Mac MLX. Each mode passes Cedar and fails three arithmetic requests. The exact iPhone wrong 2 for 2 + 2 reproduces with original unquantized weights and independently converted FP32 inference. Canonical prompt bytes, token IDs, original public weight provenance and all 311 converted tensor values are verified. The MLX export, int4 transform and app cache are not necessary for that reproduction. Quantization does change the 3 + 5 answer from wrong 9 to wrong 5 in the tested controls. Keep both strict native failures and the experimental product label. These diagnostic results add no runtime ranking, speed, energy, fit, default-model or study-replication claim.
