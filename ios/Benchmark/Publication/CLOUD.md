# Firebase publication pilot

Status on 2026-10-07: implemented, signed, locally validated and executed in
Firebase. Both approved jobs passed their selected native method, fresh model
download/hash verification and all six turns at nominal temperature. The actual
devices were two iPhone 16 Pro units on iOS 18.3.2 build 22D82. Factual and strict
format probes both passed 3/3 per backend. The completed attempt is
`outputs/firebase-lfm-pilot-20261007-attempt0`. Package hashes, provider object
verification and native outcomes are in `firebase-pilot-completion-2026-10-07.json`.

This pilot selects only LFM2.5-1.2B Instruct Q4_K_M, with one CPU job and one
Metal job on Firebase iPhone 16 Pro, catalog iOS 18.3, using Xcode 26.2.
Each job runs the unchanged S1 six-turn conversation once. The twelve requests
check delivery of the existing four measurements: first text, streaming speed,
sampled process footprint and factual recall. One repetition is a delivery
check, not a stable performance estimate. The five-model expansion and SE3
replication require separate decisions. The historical exhaustive study remains
parked.

## Prepare

Select the Xcode used for the signed GGUF-only build with `DEVELOPER_DIR`, then
run from `ios/Benchmark`:

```sh
python3 Publication/cloud.py prepare Publication/outputs/UNIQUE_CLOUD_ATTEMPT \
  --catalog .build/firebase/publication-20261007
```

Refresh the Firebase model/version catalogs before preparing a later attempt.
Preparation checks the signed build receipt, compiled source hashes, portable
test paths and ZIP member hashes. Each approximately 11 MB ZIP contains the
signed app, hosted tests and exactly one XCTest plan. Model weights are not in
the ZIP. A fresh cloud app downloads and verifies the pinned 730,895,168-byte
GGUF before inference timing begins. It emits acquisition evidence on success
or failure, then calls the unchanged publication conversation method.

Each job has a ten-minute provider limit, including acquisition and cooling.
Flaky-test retries are disabled. No automatic benchmark resubmission is allowed.
A download, timeout or inference failure stays part of that attempt's evidence.

`submission-proposal.json` contains the exact two commands and selected device.
Preparation never uploads or submits them. Explicit approval of these paid jobs
is required before execution. The twenty requested physical-device minutes have
a primary execution estimate of $1.67 without free minutes. Remaining allowance,
ancillary charges and infrastructure retries are unverified. Do not treat this
estimate as a guaranteed total charge.

## Collect

Keep each job's matrix/execution result, native outcome, provider logs and
downloaded XCTest result together. Export its attachments with the selected
Xcode's `xcresulttool export attachments`. Pass CPU attachments first and Metal
attachments second:

```sh
python3 Publication/cloud.py collect Publication/outputs/UNIQUE_CLOUD_ATTEMPT \
  --cpu-attachments /path/to/cpu-attachments \
  --metal-attachments /path/to/metal-attachments \
  --cpu-status passed --metal-status passed
```

Use the actual native outcomes, including `failed` when appropriate. Collection
retains raw attachments, checks acquisition evidence and delegates report
validation and scoring to the existing publication collector. Missing evidence
does not count as success. It writes one-conversation denominators and keeps warm
samples out of headline timings. Never collect into an already collected folder.
Keep local package validation in its own folder so it cannot stand in for a
Firebase result.

Firebase and the personal iPhone form separate device/OS cohorts. Cloud power,
temperature and physical-device assignment are not controlled by this wrapper.
Do not pool cloud and personal-phone measurements, infer hardware-only causes,
or interpret process footprint as total CPU-plus-GPU physical memory.

## Store terminal evidence

```sh
python3 Publication/archive.py package Publication/outputs/UNIQUE_CLOUD_ATTEMPT
python3 Publication/archive.py transfer Publication/outputs/UNIQUE_CLOUD_ATTEMPT --evict-large
```

The existing private Hugging Face workflow verifies a freshly downloaded archive
before removing large local results. Small reports, tables, logs and remote
receipts remain. Public publication is a separate approval.
