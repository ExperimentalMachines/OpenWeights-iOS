# OpenWeights iOS

Native iOS product and benchmark harness, separated from the Android checkout.
Read ios/Product/README.md and ios/Benchmark/README.md for build commands.

- Preserve historical benchmark reports, failures, source hashes and signed build receipts.
- Keep generated builds, model weights and raw test bundles outside Git.
- Read migration/artifact-catalog.json and migration/build-artifact-catalog.json
  before treating an absent historical package or host build as lost evidence.
  An adjacent .remote.json receipt identifies each archived item. Restore needed
  packages with migration/archive_packages.py --restore before native or cloud use.
  Archive completed runs after verification, rather than retaining every large
  execution package and obsolete host build locally.
- Never copy credentials, signing profiles, private keys or access tokens into this repository.
- Public publication and app distribution require explicit authorization.
- Do not claim runtime improvements without real-device measurements.
- Native dependencies are pinned in native-dependencies.json. Prepare them with
  python3 prepare-native-dependencies.py, then verify with --check.
- The engine_session sources were copied from uncommitted Android work.
  migration/source-manifest.json records the origin and exact file hashes.
  Keep later shared-engine changes coordinated between the two repositories.
- Do not claim the migration is complete until an independent native build passes
  and active benchmark execution no longer depends on the original checkout.
- Never add a co-author to a commit message. No em dashes or en dashes in new prose.
