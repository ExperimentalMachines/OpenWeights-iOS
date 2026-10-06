#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
device_id=${1:?Usage: bash run.sh IPHONE_UDID}
products="$PWD/.build/DerivedData/Build/Products"
plan="$products/Product-current-host.xctestrun"
python3 - "$plan" <<'PY'
import hashlib, json, os, plistlib, sys
from pathlib import Path
root = Path.cwd()
products = root / '.build/DerivedData/Build/Products'
receipt = json.loads((products / 'openweights-product-build.json').read_text())
from build_receipt import source_hashes
if source_hashes() != receipt['sources']:
    raise SystemExit('Product sources changed or files were added. Rebuild before device validation.')
app = products / 'Release-iphoneos/OpenWeights.app'
for relative, expected in receipt['executables'].items():
    if hashlib.sha256((app / relative).read_bytes()).hexdigest() != expected:
        raise SystemExit('Product executable changed. Rebuild before device validation.')
plans = list(products.glob(f"*_iphoneos{receipt['sdk']}-*.xctestrun"))
assert len(plans) == 1
plan = plistlib.loads(plans[0].read_bytes())
identifier = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
for key, target in plan.items():
    if key != '__xctestrun_metadata__':
        # Xcode records the scheme's default identifier even when a build-setting override
        # signed the app with the existing free-profile slot. Bind launch to the actual app.
        target['TestHostBundleIdentifier'] = identifier
        if os.environ.get('OW_PRODUCT_SKIP_LARGE_DOWNLOAD') == '1':
            target['SkipTestIdentifiers'] = ['ProductTests/testDownloadedGGUFChatWorkflow']
        target['ParallelizationEnabled'] = False
        target['TestTimeoutsEnabled'] = True
        target['DefaultTestExecutionTimeAllowance'] = 600
        target['MaximumTestExecutionTimeAllowance'] = 600
Path(sys.argv[1]).write_bytes(plistlib.dumps(plan))
PY
mkdir -p Results .build/test-logs
run_name="product-workflow-$(date -u +%Y%m%dT%H%M%SZ)"
test_exit=0
xcodebuild test-without-building -xctestrun "$plan" -destination "id=$device_id" \
  -parallel-testing-enabled NO -resultBundlePath "Results/$run_name.xcresult" \
  > ".build/test-logs/$run_name.log" 2>&1 || test_exit=$?
xcrun xcresulttool export attachments --path "Results/$run_name.xcresult" \
  --output-path "Results/$run_name-attachments" >> ".build/test-logs/$run_name.log" 2>&1
rg 'Test Case .*passed|Test Case .*failed|error:|TEST EXECUTE' ".build/test-logs/$run_name.log" | tail -n 12
printf 'RESULT_BUNDLE=%s\n' "$run_name"
exit "$test_exit"
