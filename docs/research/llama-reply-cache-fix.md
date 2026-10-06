# Reply-token cache fix

Date: 2026-10-02
Status: Implemented and verified with native sanitized regressions and 99 iPhone
requests. Android build blocked by absent Android SDK.

The six-turn iPhone pilot exposed a shared `Session` bug: the final assistant
reply `vegetarian` also appeared in the first user message. The matcher inserted
the generated reply tokens at that earlier occurrence. This changed token 72 of
the prompt and discarded most cached history. The CPU, full-Metal and
partial-Metal configurations all showed the same cache cutoff. The original
measurements remain in [the multi-turn pilot](ios-multiturn-scaling.md).

The fix binds each saved reply to its assistant message index. It obtains the
assistant field's byte range from the actual chat template by replacing that
field with a unique marker in a separate render. A range is accepted only when
putting the original field back reproduces the real prompt byte for byte.
Only a complete matching field may receive that turn's generated tokens.
User text, system text, quotations and edited assistant messages stay normally
tokenized. Ambiguous or content-rewriting templates fall back to normal
tokenization. This avoids assuming that every model uses ChatML boundaries.

Each match now carries its saved-record index. Identical replies cannot select
another turn's tokens, and the second text-based lookup that indexed an offset
table before checking its length is removed. Regenerating a turn replaces its
previous token record.

`reset()` remains a cache-only operation for internal rollback and re-reading
the same conversation. `reset_conversation()` also clears saved replies and
verified assistant ranges. Android's public JNI reset and the iOS benchmark
reset use the fresh-conversation operation. Media text stretches pass their
absolute prompt offset when selecting assistant ranges.

## Verification

The host test uses the actual shared `Session`, the pinned Qwen3 0.6B Q4_K_M
GGUF, its chat template and its tokenizer. Six assertion groups passed with
AddressSanitizer and UndefinedBehaviorSanitizer in 16.99 seconds, including two
real greedy generations. Coverage includes assistant ownership, repeated text,
different token boundaries, regeneration, edited messages, reasoning offset
tables, media text offsets, both reset types and ambiguous-template fallback.
No multimodal model inference was performed.

An isolated control substituted the original matcher and span structure into
the otherwise current engine. The new regression failed with:
`system/user quotations must stay plain, only the owning assistant field may splice`.
This establishes that the test detects the original matcher bug. It is a focused
control, not a reconstruction of the complete original binary.

The iPhone Release target compiled successfully. Two multi-turn tests passed
with zero failures in 75.016 seconds, covering 54 inference requests. All
samples started and ended at nominal thermal state. Low Power Mode was off,
and the user confirmed the phone was unplugged. The three llama.cpp sequences
reproduced every original prompt message array and output exactly, using the
unchanged GGUF artifact and workload.

Their final turn now retains 866 of 1,559 prompt tokens, compared with 72 of
1,561 before the fix. Newly evaluated tokens fell from 1,489 to 693. The remaining
four-token boundary change before the latest assistant reply comes from the
Qwen thinking opener and is separate from the corrected user-text splice.

| Configuration | Original turn-6 first text | Corrected turn-6 first text | Reduction |
| --- | ---: | ---: | ---: |
| O1, llama.cpp CPU | 4,791.5 ms | 3,049.0 ms | 36.4% |
| O3, llama.cpp full Metal | 1,537.0 ms | 804.8 ms | 47.6% |
| O5, llama.cpp partial Metal | 3,421.5 ms | 2,193.7 ms | 35.9% |

These are single-run observations, not repeated medians. Model, actual history
and outputs match, and temperature was nominal, but runtime order and other
device conditions were not independently randomized. The cache-count correction
is directly verified. The percentages describe these two measurements.

All three llama.cpp sequences passed 3/3 strict recall probes. Fresh reset
replays now start with the original 92-token prompt rather than the contaminated
94-token prompt. Later warm and fresh requests can still tokenize historical
assistant text differently because only the warm path retains generated token
boundaries. The public reset now starts a genuinely independent conversation.

The existing single-turn pilot also passed one test with zero failures in
33.667 seconds, covering another 45 requests. All five adapters passed
cancellation and subsequent recovery. Total iPhone verification: 99 requests.

Android Gradle configuration reached build-logic compilation with the installed
JDK 23, then failed because no Android SDK is installed. The JDK 21 path in
`AGENTS.md` is also absent on this Mac. Android compilation and device execution
remain unverified.

## Evidence and reproduction

- [Native verification and source hashes](../../ios/Benchmark/Results/llama-reply-cache-native-verification-2026-10-02.json).
- [Native tests and commands](../../core/engine/src/test/cpp/README.md).
- [Original iPhone report](../../ios/Benchmark/Results/iphone16-multiturn-baseline-2026-10-02.json).
- [Corrected multi-turn report](../../ios/Benchmark/Results/iphone16-multiturn-cache-fixed-2026-10-02.json) and [source fingerprint](../../ios/Benchmark/Results/iphone16-multiturn-cache-fixed-source.json).
- [Before/after analysis](../../ios/Benchmark/Results/iphone16-multiturn-cache-fixed-analysis-2026-10-02.json).
- [Cancellation/recovery report](../../ios/Benchmark/Results/iphone16-cache-fixed-pilot-2026-10-02.json) and [source fingerprint](../../ios/Benchmark/Results/iphone16-cache-fixed-pilot-source.json).

From `ios/Benchmark`, rebuild with `./build.sh`, then execute
`./run.sh YOUR_IPHONE_UDID --multi-turn` on an unlocked, cool device. Original
reports and source fingerprints are preserved separately from corrected runs.
