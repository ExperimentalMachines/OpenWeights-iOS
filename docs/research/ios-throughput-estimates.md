# iOS weight-based speed estimates and GGUF timing correction

Status: implemented, signed and verified for the selected flows on 2026-10-04. Full P21 and A1-A3 remain open.

The product now shows approximate prompt-processing and decoding rates in GGUF selection and installed dashboard rows. Each estimate scales a measured rate by source weight bytes divided by target weight bytes, on the same backend. Observed source rates, tokens, milliseconds and weight size remain visible separately. There is no default-model or backend change.

Calibration requires a ready, currently present weight artifact with known byte counts and SHA-256 metadata. New ledger rows bind their measurements to a canonical weight manifest. Storage refresh verifies presence and individual sizes. Runtime loading verifies hashes. The refresh alone cannot detect a same-size modification. Deleted, truncated, paused or replaced weights cannot supply calibration. Legacy rows reopen without fabricated metadata. Each phase chooses the model with the largest measured token work independently. CPU, Metal, MLX and XNNPACK measurements never substitute for one another. XNNPACK has no split-time calibration.

## Timing correction

The shared engine previously ended its Metal prefill timer after asynchronous work submission, before completion. Actual short probes exposed one- and two-millisecond values. The pinned llama API documents explicit synchronization and result-read synchronization. Generation and successful warming now call `llama_synchronize(ctx_)` before ending prefill timing.

New GGUF rows set `prefillIncludesCompute=true`. Older Metal ledger rows preserve their original raw values, token/cache counts and decode rates. Their incomplete prompt intervals are excluded from prompt-speed and total-computing-time aggregates and calibration. Historical benchmark raw data stays unchanged. Unsynchronized GGUF Metal `prefill_ms` is unsuitable for full GPU prompt-throughput claims. First-text, cache-count and decode interval definitions are unchanged. This is a measurement correction, not evidence of a performance improvement or a complete GPU timing audit.

## Native prediction probe

Two pinned Qwen3 Q4_K_M artifacts have 396,705,472 and 1,107,409,472 weight bytes. Their revisions and full hashes are retained in the [combined proof](../../ios/Product/Results/throughput-synchronized-native-bdecc5496e4c.json). Each backend runs the same fresh 36-token prompt, greedy decoding, thinking off, 2,048 context and 48 output tokens. Decode timing counts 47 tokens after the first output. One small-model observation predicts the larger model. Actual larger-model observations are independent of that calibration.

| Backend | Larger-model phase | Predicted tokens/s | Observed tokens/s | Prediction relative to observation |
|---|---|---:|---:|---:|
| CPU | Prompt processing | 56.56 | 59.11 | -4.3% |
| CPU | Decoding | 27.20 | 27.36 | -0.6% |
| Metal | Prompt processing | 204.70 | 153.85 | +33.1% |
| Metal | Decoding | 37.84 | 38.65 | -2.1% |

Four fresh requests, one per artifact/backend, do not establish a prediction accuracy range or a replicated benchmark. Different model architecture, quantization, context, cache and temperature can change the outcome. No energy, general quality or memory-fit claim follows. Light/dark images of the actual estimate component were inspected. Native navigation, gestures, Dynamic Type and VoiceOver remain unverified.

## Verification and reproducibility

The combined proof binds the signed Xcode 26.2 build, 221 core and 151 canonical-controller passes, six initial and three regression native passes with no failures/skips, exact source/tool archives and raw attachments. Accounting, actual storage/dashboard, cached chat and shared settings pass. The normal product reopens.

Strict CPU ASan/UBSan initially aborted on pinned ggml null-pointer arithmetic during graph-size planning. A one-line integer-offset correction now applies through the hash-guarded `PatchGGMLGraphOffset.cmake` before Android, iOS and host builds. It accepts only the exact pinned original or patched file and refuses unexpected source. Fresh-source reproduction, idempotence and refusal checks pass. Build receipts include the effective ggml source and patch helper. The submodule revision remains `b2e5e9b28b2484fbf94b543432ece638996a8b97`, with this recorded local patch.

[Sanitizer proof](../../ios/Product/Results/throughput-sanitizer-pass-bb88a433eae6.json) retains all seven Session regression groups passing with 295 instrumented C/C++ objects, immediate UBSan abort and macOS leak detection disabled. The actual CPU Session performs generation. Host Xcode 26.5 is separate from the Xcode 26.2 device build. An earlier Xcode 26.2 ASan startup deadlock and the original ggml failure remain retained. Android compilation still awaits SDK license approval. Use the canonical [host regression instructions](../../core/engine/src/test/cpp/README.md) with a working host sanitizer runtime.

Measured memory fit, broader families, first-run bandwidth calibration, full native navigation/accessibility and P21 remain open. Multi-device/Core ML replication, actual OS lifecycle, the known instruction/length and Canvas repair failures, and full A1-A3 remain incomplete. No cloud job, publication, distribution, commit or push occurred.
