# CPU and Metal conversation benchmark on iPhone 16

Status: private review draft, 2026-10-07. Qwen pilot and five-model comparison
measured. Both private evidence archives passed fresh-download verification.
No public publication authorized.

An on-device chat model must start answering promptly, stream comfortably, fit
in memory, and retain useful facts across messages. This benchmark reports
those four properties using the same model file on CPU and Apple Metal.

## Pilot results

| Metric | llama.cpp CPU | llama.cpp Metal |
| --- | ---: | ---: |
| M1 Median first-response delay | 0.633 s | 0.200 s |
| M2 Median streaming speed | 57.8 tokens/s | 96.3 tokens/s |
| M3 Median conversation peak app memory | 407.0 MiB | 400.9 MiB |
| M4 Factual recall | 9/9 scorable probes | 9/9 scorable probes |
| Strict-format correctness | 6/9 probes | 6/9 probes |
| Completed conversations | 3/3 | 3/3 |
| Nominal-temperature turns | 18/18 | 18/18 |

The pilot used Qwen3-0.6B Q4_K_M. Metal produced about 1.67 times the streaming
speed with about 68% lower median first-response delay. This supports using
Metal for this small model on this phone. It does not establish results for
larger models, other devices, or other inference libraries. The 6.1 MiB memory
difference is descriptive and too small to establish a meaningful memory advantage.

Both backends retained every tested fact. Both sometimes returned
`dietary rule: vegan` when asked for one word. The fact is correct, but the
format is wrong. Nine probes are three repeats of three questions in one
conversation, not nine independent quality tasks. Recall uses earlier messages
still inside the context window. It does not test persistent memory beyond it.

| First-response delay by turn | CPU | Metal |
| --- | ---: | ---: |
| Turn 1 | 0.313 s | 0.092 s |
| Turn 6 | 3.373 s | 0.757 s |

Later replies took longer to start. The sixth prompt also differs from the first
and requests structured fact recall, so this is a growing-conversation observation,
not a controlled experiment isolating history length. Longer user turns include repeated logistics text, so this is a synthetic
stress conversation rather than a recorded real chat. Actual generated answers
are carried into subsequent turns. Prefix retention is enabled without reset replays.

## Method and evidence

Device: iPhone 16 (`iPhone17,3`), iOS 26.6.2 build 23G90, approximately 8 GB RAM.
JC confirmed the phone was unlocked, unplugged, cool and at least 60% charged.
All captured samples started and ended at nominal thermal state. Low Power
Mode was disabled in all six reports. Six distinct process IDs establish fresh
app invocations. Observed native backend labels were `CPU` and `MTL0`.

One signed GGUF-only Release build, Xcode 26.2 build 17C52, SDK 26.2,
llama.cpp commit `b2e5e9b28b2484fbf94b543432ece638996a8b97`.
Model revision `50968a4468ef4233ed78cd7c3de230dd1d61a56b`, file
`Qwen3-0.6B-Q4_K_M.gguf`, 396,705,472 bytes, SHA-256
`ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a`.

Each backend completed three six-turn S1 stable-facts conversations. Settings:
2,048-token context, greedy decoding, thinking disabled, maximum 64 generated
tokens per reply. Headline throughput excludes replies shorter than eight tokens.
Fifteen of eighteen replies per backend qualify for throughput. The longest
recorded prompt is 1,517 tokens, within the 2k context including the reply cap.
First response measures first text callback, including prompt preparation and
detokenization. Memory is sampled whole-process footprint every 50 ms, including
loading. This is iOS process footprint, not total CPU-plus-GPU device memory.
Do not interpret lower Metal footprint as total physical-memory savings. GPU
allocation residency is not measured separately. Warm filesystem caches are possible. No energy measurement was taken.

The six measurement invocations totaled 69.695 seconds of host execution.
Downloads and bounded result extraction were separate. Native runs passed on
their first attempt. The initial host collector rejected XCTest export shapes.
Its corrections and raw evidence are retained without rerunning inference.
Factual scoring was finalized using the pilot before freezing the five-model
protocol. Host orchestration subsequently added a first-repetition calibration
stage with unchanged metric calculations and factual scoring.

Small local evidence is retained under
`ios/Benchmark/Publication/outputs/qwen-pilot-20261007-attempt2`: `summary.csv`,
`turns.csv`, `index.json`, `retained-reports/`, source/build snapshots and correction
history. The complete evidence ZIP is privately archived in
`zeraphim/openweights-ios-artifacts`, with fresh-download SHA-256 and ZIP-CRC
verification before local execution-bundle eviction. Archive SHA-256:
`71c5dac79deb00e91772e90953d4f7469903fab15c07356041c5c4f0813683db`.

## Five-model results

All thirty conversations and 180 requests passed on the same iPhone 16.
The cumulative measurement clock, including launches, cache verification and
cooling, was 2,028.774 seconds (33.8 minutes), below the 60-minute limit.
Acquisition took 137.490 seconds separately. There were no measurement retries.
The initial ten conversations took 8.5 minutes and projected 38.3 minutes for
the full batch with headroom. They count toward these final results.

| Model | Backend | First response (s) | Streaming (tokens/s) | Process footprint (MiB) | Facts correct/scorable | Nominal turns/18 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Gemma 3 1B IT | CPU | 0.759 | 38.6 | 793.0 | 9/9 | 18/18 |
| Gemma 3 1B IT | Metal | 0.295 | 45.3 | 792.9 | 9/9 | 18/18 |
| LFM2.5 1.2B Instruct | CPU | 1.070 | 43.4 | 720.8 | 9/9 | 18/18 |
| LFM2.5 1.2B Instruct | Metal | 0.370 | 65.3 | 720.9 | 9/9 | 18/18 |
| Qwen3 1.7B | CPU | 1.344 | 19.0 | 1778.0 | 9/9 | 18/18 |
| Qwen3 1.7B | Metal | 0.438 | 25.5 | 385.8 | 8/8 | 17/18 |
| Llama 3.2 3B Instruct | CPU | 3.031 | 14.6 | 1234.7 | 8/8 | 17/18 |
| Llama 3.2 3B Instruct | Metal | 0.745 | 22.0 | 401.5 | 8/8 | 17/18 |
| SmolLM3 3B | CPU | 2.798 | 14.0 | 436.5 | 7/7 | 16/18 |
| SmolLM3 3B | Metal | 0.997 | 23.4 | 321.3 | 6/6 | 12/18 |

Every configuration completed 3/3 conversations and observed all nine raw
recall probes. Eleven of 180 turns were temperature-excluded from headline
metrics, including eight probes. The remaining 82 probes were all factually
correct, with zero unscorable probes. Missing headline probes are temperature
exclusions, not forgotten facts. Raw warm results remain available.

| Model | CPU throughput samples | Metal throughput samples | CPU memory conversations | Metal memory conversations | CPU strict format | Metal strict format |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Gemma 3 1B IT | 15/18 | 15/18 | 3/3 | 3/3 | 3/9 | 3/9 |
| LFM2.5 1.2B Instruct | 15/18 | 15/18 | 3/3 | 3/3 | 9/9 | 9/9 |
| Qwen3 1.7B | 15/18 | 14/18 | 3/3 | 2/3 | 9/9 | 8/8 |
| Llama 3.2 3B Instruct | 14/18 | 14/18 | 2/3 | 2/3 | 8/8 | 8/8 |
| SmolLM3 3B | 13/18 | 10/18 | 1/3 | 2/3 | 7/7 | 6/6 |

Throughput requires nominal temperature and at least eight output tokens.
Memory requires a wholly nominal conversation. Each format score uses only
temperature-qualified probes, with nine planned per configuration. Memory
medians are descriptive and based on one to three eligible conversations.
The low Metal footprints do not prove lower total device-memory use.

| Model | CPU turn 1 response | CPU turn 6 response | Metal turn 1 response | Metal turn 6 response |
| --- | ---: | ---: | ---: | ---: |
| Gemma 3 1B IT | 0.357 s (n=3) | 2.594 s (n=3) | 0.132 s (n=3) | 0.896 s (n=3) |
| LFM2.5 1.2B Instruct | 0.479 s (n=3) | 3.752 s (n=3) | 0.187 s (n=3) | 1.291 s (n=3) |
| Qwen3 1.7B | 0.565 s (n=3) | 5.918 s (n=3) | 0.223 s (n=3) | 1.690 s (n=2) |
| Llama 3.2 3B Instruct | 1.307 s (n=3) | 12.138 s (n=2) | 0.428 s (n=3) | 3.565 s (n=2) |
| SmolLM3 3B | 1.416 s (n=3) | 11.439 s (n=1) | 0.604 s (n=2) | 3.550 s (n=2) |

### What these results support

F1. Metal had higher observed headline streaming speed in every tested model,
with ratios of approximately 1.17 to 1.67 versus CPU. First response was also
faster. These are workload medians with unequal thermal exclusions in some
configurations. They do not isolate GPU kernels or establish performance for
other libraries and devices.

F2. LFM2.5 had the highest streaming speed in this five-model set, 65.3 tokens/s
on Metal, and matched every eligible formatting probe. Gemma had the shortest
median first response, 0.295 seconds on Metal, but passed only 3/9 formatting
probes on each backend despite retaining the facts. Those are useful engineering
tradeoffs for a chat app, without establishing which model is generally smarter.

F3. Later replies started more slowly. Llama and SmolLM3 took about 11 to 12
seconds to start their sixth CPU reply, versus about 3.6 seconds on Metal.
Later prompts are longer and ask different questions. This demonstrates the
observed growing-conversation behavior without isolating history length.

F4. Back-to-back testing makes cooling operationally significant. All 180
requests completed, while eleven turns warmed and lost headline eligibility.
One full SmolLM3 Metal conversation contributed no nominal samples. Unequal
turn coverage can affect pooled medians, so the per-turn table and counts belong
alongside any published summary. No energy or battery-efficiency claim is made.

### Artifact and workload boundaries

Gemma, LFM2.5, Llama and SmolLM3 use Q4_K_M. Qwen3-1.7B uses Q8_0.
Exact revisions, byte sizes, SHA-256 hashes and pinned URLs are in
`ios/Benchmark/Publication/comparison-models.json`. CPU and Metal use identical
bytes within each model. Quantizations and tokenizers differ across models.
Tokens/s is not literal words/s across those tokenizers.

The synthetic conversation introduces workshop facts (Birch, Porto, 620 credits,
vegan), adds repeated logistics text, and asks for recall at turns 3, 5 and 6.
Six turns run back-to-back with no simulated user pause. The longest recorded
prompt was 1,594 tokens, and every reply respected the 64-token cap. These
measurements do not cover chats exceeding the 2k context or arbitrary user tasks.
Recall uses messages still in context, not persistent memory beyond it.

The Android study used different prompts, output caps and sampler settings.
Historical Android file hashes have not been established. This study supports
CPU versus Metal comparisons within each pinned artifact, not a controlled
Android versus iPhone claim. A single fact-recall conversation does not measure
general intelligence. Experimental Machines is the proposed primary publication
home for this engineering comparison. The recall results support a narrow
formatting observation rather than an intelligence leaderboard.

### Reproducibility and private storage

All thirty reports identify distinct app process IDs and the selected native
CPU or MTL0 backend. The same signed Release build and unchanged fixture served
the pilot and comparison. The fixture SHA-256 is
`c584c1da2ca3871e3022b8505758993683d78ba79755d46795a288137903be29`.
`protocol-freeze-2026-10-07.json` and
`calibration-orchestration-2026-10-07.json` bind the scoring freeze and the host
change that counted calibration toward the single cumulative budget.

The batch is `ios/Benchmark/Publication/outputs/five-models-20261007-attempt0`.
It retains `summary.csv`, `turns.csv`, `index.json`, `analysis-denominators.json`,
small raw reports and exact protocol/model/workload/source/build snapshots.
The canonical raw reports are those referenced by `index.json`, not every
historical JSON file in the folder. `remote-receipt.json` identifies the complete private evidence archive. Its
fresh download passed SHA-256 and ZIP-CRC checks before local execution-bundle
removal. The tables reproduce byte-for-byte afterwards. Archive SHA-256:
`9a436f65d032eceb3d12b688e634d88bb5013a45a45988d0715af82c01c1aebb`. Public publication remains
pending explicit approval. The archived review draft preserves its pre-transfer
status, while this repository draft records the completed verification.
