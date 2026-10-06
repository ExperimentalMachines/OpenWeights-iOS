# iPhone 16 runtime benchmark pilot

Date: 2026-10-01
Status: Implemented, executed locally, and verified by XCTest. Cloud execution pending.

The local iOS benchmark runner passed on iPhone 16. All five configurations
completed nine requests each, including cancellation and generation afterward.
MLX led streaming throughput for this Qwen3 0.6B artifact comparison. Full
llama.cpp Metal produced first text sooner. These measurements do not establish
a production runtime default or broad hardware rankings.

## Measurements

Device: iPhone 16 (`iPhone17,3`), iOS 26.6.2 build 23G90. Xcode 26.5, iOS 26.5
SDK, Release build. Low Power Mode was off. Thermal state remained nominal for
every sample. Model files were already downloaded and checksum-verified.

The table reports medians over three fresh-context short prompts. First text is
measured at the decoded text callback and includes preparation and detokenization.
Streaming throughput is `(generated tokens - 1) / (last callback - first callback)`.

| ID | Configuration | Artifact quantization | Streaming tokens/s | First text, ms | Output tokens |
| --- | --- | --- | ---: | ---: | ---: |
| O1 | llama.cpp CPU | GGUF Q4_K_M | 83.0 | 173.5 | 54 |
| O2 | ExecuTorch XNNPACK | 8da4w, int8 embeddings | 102.5 | 130.8 | 51 |
| O3 | llama.cpp Metal, all layers | Same GGUF Q4_K_M | 103.9 | 56.6 | 64 |
| O4 | MLX Metal | Affine 4-bit | 137.2 | 67.5 | 64 |
| O5 | llama.cpp partial Metal, 14 layers | Same GGUF Q4_K_M | 60.6 | 193.3 | 54 |

Every request used a 2,048-token context ceiling and 64-token output limit, greedy
decoding, repetition penalty disabled, and thinking disabled. O3 and O4 reached
the output limit on the short prompt. No answer-quality score was measured.
Outputs and stop reasons are retained in the raw report.

## Validation and fixes

Each configuration ran three fresh short conversations and their follow-ups, one
longer prompt, cancellation after three emitted tokens, and a fresh request after
cancellation. XCTest asserted that each runtime completed, returned nonempty
output, respected the token limit, streamed text, and recovered from cancellation.
The successful test took 30.735 seconds, excluding installation and earlier runs.

The first attempt crashed while ExecuTorch fell back from a tokenizer regex that
its packaged RE2 implementation could not parse. The benchmark now links the
official optional PCRE2 lookahead addon from the exact tokenizer revision used by
ExecuTorch 1.4. The model's tokenizer is unchanged. A subsequent diagnostic run
identified primitive-operator registration objects omitted by the linker.
Explicitly loading the core registration archive resolved model loading.

ExecuTorch's bundled tokenizer and the shared llama.cpp engine also export
overlapping Unicode symbols. The iOS CMake build prefixes the shared engine's
internal Unicode symbols so each tokenizer uses its own implementation. Android
runtime behavior remains behind its existing platform guards.

The runner checkpoints results before runtime loading and after each completed
request, disables automatic screen locking during execution, verifies cached
model hashes before timing, and retains reports as XCTest attachments.

## Evidence and limits

The [raw report](../../ios/Benchmark/Results/iphone16-pilot-2026-10-01.json)
contains all 45 samples, model revisions and file hashes, runtime versions,
prompts, outputs, cache counts when available, memory samples, and cancellation
latencies. The [source fingerprint](../../ios/Benchmark/Results/iphone16-pilot-source.json)
identifies the code and executable used in the successful run. Build and run
instructions are in [the benchmark README](../../ios/Benchmark/README.md).

This is one phone, one model family, a fixed runtime order, and three short-prompt
repeats. Quantization and tokenizer implementations differ. ExecuTorch resets its
cache before every request, while the other adapters reuse prefixes. The GGUF
runtime renders its own chat template. The explicit prompt hash applies to MLX
and ExecuTorch only. Fresh contexts are not cold filesystem-cache measurements,
and prior runs had warmed shader and framework caches.

Process footprint is sampled every 50 ms during load and generation. It includes
shared allocators, framework caches, model verification, and earlier stages in the
same process. The raw peaks must not be interpreted as isolated runtime memory
requirements. No battery-energy measurement or sustained thermal test was made.

A signed XCTest archive was prepared and its app signature verified using the
[Firebase packaging procedure](https://firebase.google.com/docs/test-lab/ios/run-xctest).
No cloud test was submitted. The read-only Firebase catalog check listed Xcode
26.2 for iOS 26.3, and Xcode 16.4 or 26.2 for iOS 18.3 and 18.4. The local build
used Xcode 26.5. The [catalog snapshot](../../ios/Benchmark/Results/firebase-compatibility-2026-10-01.json)
records this mismatch. Google documents possible incompatibility between build
and test Xcode versions in its [CLI guide](https://firebase.google.com/docs/test-lab/ios/command-line).
Before cloud measurements, rebuild with a supported Xcode toolchain and validate
the same suite, then run one cloud smoke test before expanding the matrix.
