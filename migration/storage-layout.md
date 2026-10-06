# Benchmark artifact storage

Status: selected private transfers executed and verified on 2026-10-07.
Ten execution packages and 27 inactive host build directories were moved to
zeraphim/openweights-ios-artifacts after downloading and checking their remote
copies. About 14.3 GB of original files were removed locally. The bucket reports
about 8.6 GB including compressed build archives and manifests. Available disk
space increased from about 13 GiB to about 28 GiB.

Proof: archive-move-verification-2026-10-07.json. Catalogs:
artifact-catalog.json and build-artifact-catalog.json. All 74 remote archive
objects and manifests were checked. One package was restored to its original
path, verified, then rearchived. Current source copies still match all 492
source-manifest entries. The three prepared next-job packages remain local.

The existing ios tree occupies about 56 GiB of allocated disk space. Benchmark
and product .build directories account for about 47 GiB. Their Results
directories account for about 7.8 GiB. Build directories also contain evidence,
models and scripts, so they cannot be deleted as undifferentiated caches.

## A1: GitHub source

ExperimentalMachines/OpenWeights-iOS is private. Keep app and benchmark sources,
protocols, analysis scripts, dependency pins, small fixtures and reports here.
Exclude models, DerivedData, raw xcresult bundles and Firebase execution packages.

## A2: Private working archives

Private bucket: zeraphim/openweights-ios-artifacts.

Use paths such as studies/<study-id>/runs/<run-id>/ for raw reports, native test
bundles, checkpoint observations, source snapshots and build receipts.
Store each package once under packages/<sha256>/ and reference it from runs.
Each run gets a manifest containing relative paths, byte counts and SHA-256 hashes.
Never overwrite a completed run. Buckets are mutable, so this convention must be
enforced by the archive writer rather than assumed from the storage service.

The current verified batch uses packages/<sha256>/<filename> for execution ZIPs
and builds/<sha256>/<directory-name>.tar.gz for inactive host builds. Each removed
local item has an adjacent .remote.json receipt. Full file manifests are retained
for build directories, including symbolic link targets.

## A3: Publication dataset

Proposed dataset: zeraphim/openweights-ios-benchmarks.

Publish reviewed measurements as JSONL or Parquet, workload definitions,
artifact hashes, analysis versions and a dataset card describing limitations.
Use versioned revisions for citations. Review raw logs and device identifiers
before publication. Keep signed app packages in private working storage.

## A4: Local working storage and cleanup

Keep active builds and models locally or on an external SSD. Preserve old paths
until the currently running benchmark reaches a terminal state. Before deleting
a completed artifact, upload it, retrieve it to a temporary location, verify its
manifest and archive integrity, and retain the remote locator locally. Classify
old build outputs separately from unique proof files and reproducibility inputs.
Uploading without removing a verified local copy does not free local disk space.

Before starting another batch, keep its currently selected builds, test plans,
model inputs and prepared cloud package local. After a terminal run, preserve the
small raw report and receipt locally, select completed large artifacts in a new
transfer plan, then archive and verify them. The scripts take --plan for a named
plan, so the completed transfer plans remain a record of this batch.

To restore an archived execution ZIP, run from this checkout:

```sh
/Users/zeraphim/.hf-cli/venv/bin/python migration/archive_packages.py --restore openweights/ios/Benchmark/Results/OpenWeightsBench-tests.zip
```

Substitute its original catalogued path. This downloads and checks the package
before restoring it. Inactive host compiler outputs can normally be regenerated;
their exact archived tar files and manifests remain available if needed for a
historical verification. Update the plan's path scopes when execution moves to
this independent checkout. The host-build archiver accepts selected inactive
directories under either checkout's ios/Product/.build. Independent signed product
compilation and six selected iPhone migration checks now pass. The baseline
benchmark build and execution cutover remain pending.

Reusable package/tool caches now live under .benchmark-work/Benchmark at the
workspace root. Both checkouts link to them. The same shared directory holds
working Results and active Models, with original paths preserved. These folders
were renamed locally rather than copied. Historical compiled products remain
in place and their source fingerprints are not rewritten. Future result collection
and build commands should use the separate iOS checkout after its native
benchmark validation passes.

Hugging Face currently documents 100 GB private storage for free accounts and
1 TB for PRO, shared across Hub storage types. Available account quota has not
been checked. Public free storage is best-effort, not an unlimited backup tier.

Sources:
- https://huggingface.co/docs/hub/storage-limits
- https://huggingface.co/docs/hub/storage-buckets
