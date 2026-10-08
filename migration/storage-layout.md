# Benchmark artifact storage

Status: selected private transfers executed and verified on 2026-10-07.
The initial batch moved ten execution packages and 27 inactive host build directories to
zeraphim/openweights-ios-artifacts after downloading and checking their remote
copies. About 14.3 GB of original files were removed locally. That initial inventory held
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
this independent checkout. The build archiver accepts selected inactive
directories under either checkout's ios/Product/.build, the exact completed
historical Core ML S1 build, and the exact Android engine .cxx and build directories. Independent signed product
compilation and six selected iPhone migration checks now pass. The independent
baseline passes three native methods and 45 requests. The rebuilt delegates pass
three methods and 18 requests. See native-validation-2026-10-07.json for exact
receipts. The selected execution cutover is verified. Full study replication and
Android parity remain incomplete.

Reusable package/tool caches now live under .benchmark-work/Benchmark at the
workspace root. Both checkouts link to them. The same shared directory holds
working Results and active Models, with original paths preserved. These folders
were renamed locally rather than copied. Historical compiled products remain
in place and their source fingerprints are not rewritten. Future result collection
and build commands now use the separate iOS checkout. Historical immutable
packages retain their original source identities.

Hugging Face currently documents 100 GB private storage for free accounts and
1 TB for PRO, shared across Hub storage types. On 2026-10-07, the authenticated
account reports a free account and one private bucket using 8,556,418,131 bytes
before this continuation's evidence transfers. Against the documented 100 GB
allowance, that leaves about 91.4 GB before new transfers. This is an estimate
from the documented allowance and account inventory, not a billing quota API.
Check inventory again before each batch. Public free storage is best-effort.

For the selected native migration methods, run retain_benchmark_validation.py
with the completed run label and optional --delegates. It checks the execution,
compiled inputs, binary hashes, selected plan, native log and raw report, then
creates a ZIP containing the full xcresult, attachments, source inputs and a
member manifest. Transfer the ZIP with a named archive_packages.py plan. Keep
the small verification JSON, raw reports and remote locator locally.

Sources:
- https://huggingface.co/docs/hub/storage-limits
- https://huggingface.co/docs/hub/storage-buckets

The continuation now also retains the first local Core ML S2 block, its
reproduced analysis/report, the passing three-method native UI cohort, the failed
UI startup, and all three failed Android regression attempts plus the passing
engine unit/library proof. Completed Android .cxx and build directories were
archived with fresh-download SHA and full-tree checks before removal. Their
combined logical content was 1,024,871,587 bytes. Approved SDK/JDK and Gradle
dependencies remain local. current-private-storage-inventory-2026-10-07.json
records the latest private bucket snapshot. The later signed UI build archive brings it to
100 objects and 9,246,128,327 bytes at that earlier snapshot.

The later cloud Core ML S1 block 1 now has complete retained native results and
matching actual iOS 18.3.2 provenance. Its execution package and complete evidence
ZIP passed fresh-download SHA and CRC checks before local eviction. Its report
brings the matching cloud cell to two of five blocks. The complete historical
Core ML S1 build also passed fresh-download SHA and every-file/symlink checks
before removing its 2,056,638,934 bytes of local logical content. All five local
plans remain recoverable inside that archive. The first local plan was absent
from its older native evidence ZIP, so the full build archive preserves it.

The latest inventory has 114 private objects totaling 12,292,735,682 bytes.
The Mac reports 86 GiB available. This is the observed APFS free-space value,
not an assertion that removing logical bytes immediately reclaimed the same
physical space. The approved cloud block 2 package remains local while uploading.
All local phone tests are held by the user. Active product/UI/delegate builds,
models and toolchains remain local. See firebase-coreml-S1-block1-retention-2026-10-07.json,
completed-coreml-S1-build-retention-2026-10-07.json and
goal-continuation-2026-10-07.json for exact receipts and current execution state.

To recover an inactive build, use its exact entry in build-artifact-catalog.json.
Download remotePath from the named private bucket to an empty temporary folder,
check its SHA-256, and call migration/archive_builds.py verify_archive with the
entry's fileManifest. Extract the verified tar into a separate empty directory
and restore it to localRelativePath only when that original location is absent.
Keep the approved active SDK and shared toolchain paths available, since archived
compiler outputs retain their original absolute dependency paths.
