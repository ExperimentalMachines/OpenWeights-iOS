#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Use prepared native libraries and the ordinary product namespace by default.
# Keep this runner's build separate from signed product and inference study outputs.
python3 - <<'PY'
import json
from pathlib import Path
from build_receipt import digest, source_hashes
sources = source_hashes()
for path in [Path('project-ui-validation.yml'), Path('build-ui-validation.sh'), *Path('UITests').glob('*.swift')]:
    sources[str(Path('ios/Product') / path)] = digest(path)
Path('.build/ui-validation-inputs-before.json').write_text(json.dumps(sources, indent=2, sort_keys=True) + '\n')
PY
xcodegen generate --spec project-ui-validation.yml
mkdir -p OpenWeightsUIValidation.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp App-Package.resolved OpenWeightsUIValidation.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -project OpenWeightsUIValidation.xcodeproj -scheme UIValidation -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath .build/DerivedData-ui-validation \
  -clonedSourcePackagesDirPath ../Benchmark/.build/packages -onlyUsePackageVersionsFromResolvedFile \
  -skipPackagePluginValidation -allowProvisioningUpdates -jobs 6 build-for-testing \
  PROVISIONING_PROFILE= PROVISIONING_PROFILE_SPECIFIER= "$@"
python3 - <<'PY'
import json, plistlib, subprocess
from pathlib import Path
from build_receipt import digest, source_hashes
sources = source_hashes()
for path in [Path('project-ui-validation.yml'), Path('build-ui-validation.sh'), *Path('UITests').glob('*.swift')]:
    sources[str(Path('ios/Product') / path)] = digest(path)
if sources != json.loads(Path('.build/ui-validation-inputs-before.json').read_text()):
    raise SystemExit('UI validation inputs changed during compilation.')
products = Path('.build/DerivedData-ui-validation/Build/Products')
executables = {}
for name in ['Release-iphoneos/OpenWeights.app/OpenWeights',
             'Release-iphoneos/NativeNavigationTests-Runner.app/NativeNavigationTests-Runner',
             'Release-iphoneos/NativeNavigationTests-Runner.app/PlugIns/NativeNavigationTests.xctest/NativeNavigationTests']:
    executables[name] = digest(products / name)
app = products / 'Release-iphoneos/OpenWeights.app'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
runner = products / 'Release-iphoneos/NativeNavigationTests-Runner.app'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(runner)], check=True)
app_identifier = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
test_info = plistlib.loads((runner / 'PlugIns/NativeNavigationTests.xctest/Info.plist').read_bytes())
if test_info.get('OWTargetAppBundleIdentifier') != app_identifier:
    raise SystemExit('Signed UI test target identifier does not match the signed product.')
receipt = {'sources': sources, 'executables': executables,
           'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
           'sdk': subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip(),
           'bundleIdentifier': app_identifier,
           'testTargetBundleIdentifier': test_info['OWTargetAppBundleIdentifier'],
           'purpose': 'native-touch-navigation-and-controlled-lifecycle-validation',
           'limits': ['Compilation is not native execution evidence.',
                      'Evidence applies only to the signed bundle identifier recorded here.',
                      'These flows do not establish VoiceOver behavior, external providers, full parity, OS-granted watches or natural process termination.']}
(products / 'openweights-ui-validation-build.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
print('UI validation build receipt saved.')
PY
