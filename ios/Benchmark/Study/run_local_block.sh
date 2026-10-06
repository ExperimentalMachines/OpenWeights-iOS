#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 1 ]]; then
  echo 'Usage: Study/run_local_block.sh IPHONE_UDID [--delegates|--gguf-only] [--scenario=S1-stable-facts|S2-workshop-corrections|S3-interruption-recovery] [--block=0] [--attempt=0] [--runtime=NAME]' >&2
  exit 2
fi
device_id=$1
shift
derived_data=DerivedData
plan_arguments=()
for argument in "$@"; do
  case "$argument" in
    --delegates) derived_data=DerivedData-delegates; plan_arguments+=(--delegates) ;;
    --gguf-only) derived_data=DerivedData-gguf16; plan_arguments+=(--gguf-only) ;;
    --scenario=*|--block=*|--attempt=*|--runtime=*) plan_arguments+=("$argument") ;;
    *) echo "Unknown argument: $argument" >&2; exit 2 ;;
  esac
done
run_name="study-$derived_data-$(date -u +%Y%m%dT%H%M%SZ)"
plan="$PWD/.build/$derived_data/Build/Products/$run_name.xctestrun"
if [[ ${#plan_arguments[@]} -gt 0 ]]; then
  python3 Export/build_receipt.py plan --suite=study "${plan_arguments[@]}" --output "$plan"
else
  python3 Export/build_receipt.py plan --suite=study --output "$plan"
fi
if [[ "$derived_data" == DerivedData-gguf16 ]]; then
  python3 Study/snapshot_build.py --gguf-only >/dev/null
elif [[ "$derived_data" == DerivedData-delegates ]]; then
  python3 Study/snapshot_build.py --delegates >/dev/null
else
  python3 Study/snapshot_build.py >/dev/null
fi
test_exit=0
xcodebuild test-without-building -xctestrun "$plan" -destination "id=$device_id" \
  -parallel-testing-enabled NO -resultBundlePath "Results/$run_name.xcresult" || test_exit=$?
xcrun xcresulttool export attachments --path "Results/$run_name.xcresult" --output-path "Results/$run_name-attachments"
collection_arguments=()
if [[ "$derived_data" == DerivedData-delegates ]]; then collection_arguments+=(--delegates); fi
if [[ "$derived_data" == DerivedData-gguf16 ]]; then collection_arguments+=(--gguf-only); fi
if [[ "${OW_UNPLUGGED_CONFIRMED:-0}" == 1 ]]; then collection_arguments+=(--unplugged-confirmed); fi
if [[ ${#collection_arguments[@]} -gt 0 ]]; then
  python3 Study/collect_local.py "Results/$run_name.xcresult" "${collection_arguments[@]}"
else
  python3 Study/collect_local.py "Results/$run_name.xcresult"
fi
exit "$test_exit"
