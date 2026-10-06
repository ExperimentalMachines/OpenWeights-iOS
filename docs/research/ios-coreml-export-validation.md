# Core ML CPU/GPU export validation

Date: 2026-10-02
Status: Exported and numerically validated on Mac. Signed Release build and iPhone XCTest verified. Cloud execution pending.

The initial Core ML CPU/GPU export produced incorrect, repetitive answers.
Removing channelwise int4 compression reproduced FP32 source inference on both
pilot prompts. The current benchmark export therefore uses uncompressed FP16
weights. It remains an ExecuTorch `.pte` with a Core ML delegate, rather than a
native Core ML app loading a `.mlpackage` directly.

## Numerical comparison

All three exports use the same pinned Qwen3 0.6B source checkpoint, static
single-token input, 2k context ceiling, FP16 cache, additive causal mask, and
CPU_AND_GPU compute units. Only Core ML weight compression changes. The source
reference runs with Transformers on CPU in FP32. Comparisons run on the Mac's
ExecuTorch Core ML runtime. These are correctness checks, not phone performance
measurements.

| Configuration | File bytes | Short top-1 agreement | Short logit RMSE | Long top-1 agreement | Long logit RMSE |
| --- | ---: | ---: | ---: | ---: | ---: |
| FP16, no compression | 1,205,798,090 | 64/64 | 0.0071 | 12/12 | 0.0068 |
| Channelwise int4, `c4w` | 310,715,840 | 46/64 | 3.2131 | 11/12 | 3.7747 |
| Blockwise int4, `b4w`, block 32 | 346,973,053 | 50/64 | 1.4461 | 10/12 | 1.3820 |

Teacher forcing gives each export the same source-generated prefix before
comparing its next-token logits. Counts include the reference's EOS when present.
Free greedy generation is checked separately. All evaluated logits were finite.
FP16's free-generated short and long outputs exactly matched the source outputs.
Channelwise int4 reproduced the chlorophenol error and repeated garden text seen
on the phone. Blockwise int4 reduced numerical error but its short answer still
repeated itself after the requested three sentences.

The result isolates compression as the cause of the observed divergence in this
export. It does not establish broad answer quality. The source itself returned
one sentence for the two-sentence garden request, and its short answer reached
the 64-token cap. Matching the source is an export-fidelity check, not a claim
that the source follows every instruction.

## Reproduce

From `ios/Benchmark`, after `./export-delegates.sh`:

```sh
.build/export-env/bin/python Export/validate_coreml.py Models/coreml/model.pte \
  --output Results/coreml-export-validation.json
```

The validator loads source weights locally, uses the exact short and long
benchmark prompts, compares teacher-forced logits, and records independent
greedy outputs. Its JSON includes weights and artifact hashes, validator hash,
runtime versions, prompt bytes, generated tokens, and per-step numerical errors.
It fails on nonfinite logits. Agreement values require review, and do not
automatically grade semantic quality.

To reproduce the compression controls, copy `Export/coreml.yaml` and set
`backend.coreml.quantize` to `c4w` or `b4w`, with a separate
`export.output_name`. Export through `Export/coreml_export.py` and pass the
resulting files as additional positional arguments to the validator. The two
experimental compressed artifacts remain local ignored files.

## iPhone verification

The corrected export passed on iPhone 16 (`iPhone17,3`), iOS 26.6.2 build 23G90,
with Xcode 26.5 and the iOS 26.5 SDK. One XCTest passed with zero failures in
415.822 seconds. Core ML and the unchanged ExecuTorch MLX artifact each completed
nine requests. Low Power Mode was off and every sample started and ended at
nominal thermal state. Bundled artifact hashes were verified before timing.

Medians over three fresh-context short prompts:

| Configuration | Streaming tokens/s | First text, ms | Load, ms | Peak process footprint, MiB |
| --- | ---: | ---: | ---: | ---: |
| Core ML CPU_AND_GPU, FP16 | 3.53 | 11,442.5 | 14,011.9 | 2,392.4 |
| ExecuTorch MLX, int4 linear weights | 111.14 | 49.7 | 828.2 | 1,192.3 |

The initial channelwise-int4 Core ML run measured 4.03 tokens/s and 10,323.1 ms
to first text, with incorrect repetitive output. FP16 fixes that observed output
problem, but this single-token export remains too slow for interactive chat.
The 480-token long prompt took 134,423.5 ms to first text. Its output was
`The garden has trees, flowers, and a pond.` and stopped at EOS.

All three Core ML short outputs were identical and described chlorophyll and
photosynthesis coherently. Follow-ups returned a coherent one-sentence answer.
The 64-token cap truncated each short answer, as it also did in the source
reference. The phone's short output differs from the Mac reference near the
third sentence, so the Mac's exact token agreement must not be attributed to
iPhone execution. No device-level logit comparison or formal quality grade was
performed.

Core ML cancellation stopped after three callbacks with a measured 0.0505 ms
from the cancellation request to return. The fresh request afterward reproduced
the earlier short answer. This measures stopping between callbacks, not
interrupting an in-flight Core ML operation. MLX also passed cancellation and
recovery.

Process footprint is sampled every 50 ms and includes allocators and framework
caches. MLX runs after Core ML in the same process. These figures are not
isolated engine memory requirements, and no battery energy was measured.
CPU_AND_GPU specifies permitted compute devices. Per-operation CPU/GPU placement
was not profiled. The two artifacts differ in weight precision and prefill
strategy, so their timing difference cannot be attributed solely to runtimes.

## Evidence

- [Numerical results and outputs](../../ios/Benchmark/Results/coreml-export-validation-2026-10-02.json).
- [Initial iPhone delegate results](ios-executorch-apple-delegates.md).
- [Validator](../../ios/Benchmark/Export/validate_coreml.py).
- [Current export configuration](../../ios/Benchmark/Export/coreml.yaml).
- [Updated iPhone raw results](../../ios/Benchmark/Results/iphone16-coreml-fp16-2026-10-02.json).
- [Source and executable fingerprint](../../ios/Benchmark/Results/iphone16-coreml-fp16-source.json).
- [Export provenance](../../ios/Benchmark/Results/iphone16-coreml-fp16-export-provenance.json).
- [ExecuTorch Core ML export documentation](https://docs.pytorch.org/executorch/stable/backends/coreml/coreml-overview.html).

The FP16 artifact is about 3.9 times the initial compressed file size. Xcode's
first updated-device attempt requested an unlock, then timed out before launch.
The retry after unlocking passed and produced the measurements above. The result
bundle is `Results/delegates-20261001T170949Z.xcresult`, and the raw report run ID
is `6B0AA1CF-1B98-4E36-A6B8-954198119339`. No Firebase test or model upload was
submitted.
