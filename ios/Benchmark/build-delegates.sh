#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -f Resources/model-manifest-delegates.json || ! -f Models/coreml/model.pte || ! -f Models/executorch-mlx/model.pte ]]; then
  echo 'Run export-delegates.sh before building.' >&2
  exit 1
fi
xcodegen generate --spec project-delegates.yml
mkdir -p OpenWeightsDelegatesBench.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package-delegates.resolved OpenWeightsDelegatesBench.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -project OpenWeightsDelegatesBench.xcodeproj -scheme OpenWeightsBench \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .build/DerivedData-delegates -clonedSourcePackagesDirPath .build/packages-delegates \
  -onlyUsePackageVersionsFromResolvedFile -allowProvisioningUpdates -jobs 6 build-for-testing "$@"
python3 Export/build_receipt.py stamp --delegates
