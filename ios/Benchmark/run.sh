#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ $# -lt 1 ]]; then
  echo 'Usage: ./run.sh IPHONE_UDID [--delegates] [--multi-turn | --smoke] [--mlx-only | --coreml-only] [--timeout-seconds=1800]' >&2
  exit 2
fi
device_id=$1
shift
shopt -s nullglob
derived_data=.build/DerivedData
prefix=pilot
suite=pilot
mlx_only=false
coreml_only=false
timeout_seconds=1800
for argument in "$@"; do
  case "$argument" in
    --delegates) derived_data=.build/DerivedData-delegates; prefix=delegates ;;
    --multi-turn) suite=multi-turn ;;
    --smoke) suite=smoke ;;
    --mlx-only) mlx_only=true ;;
    --coreml-only) coreml_only=true ;;
    --timeout-seconds=*) timeout_seconds=${argument#*=} ;;
    *) echo "Unknown argument: $argument" >&2; exit 2 ;;
  esac
done
if [[ ! $timeout_seconds =~ ^[1-9][0-9]*$ ]]; then
  echo '--timeout-seconds must be a positive integer.' >&2
  exit 2
fi
if [[ $mlx_only == true && $coreml_only == true ]]; then
  echo 'Select either --mlx-only or --coreml-only.' >&2
  exit 2
fi
if [[ $mlx_only == true && ($suite != multi-turn || $prefix != delegates) ]]; then
  echo '--mlx-only requires --delegates and --multi-turn.' >&2
  exit 2
fi
if [[ $coreml_only == true && ($suite != multi-turn || $prefix != delegates) ]]; then
  echo '--coreml-only requires --delegates and --multi-turn.' >&2
  exit 2
fi
test_selection=(-only-testing:BenchmarkTests/BenchmarkTests/testPilotBenchmark)
if [[ $suite == smoke ]]; then
  prefix="$prefix-smoke"
  test_selection=(-only-testing:BenchmarkTests/BenchmarkTests/testFirebaseSmoke -only-testing:BenchmarkTests/BenchmarkTests/testArtifactVerificationRejectsCorruption)
fi
if [[ $suite == multi-turn ]]; then
  prefix="$prefix-multiturn"
  test_selection=(-only-testing:BenchmarkTests/BenchmarkTests/testMultiTurnBenchmark -only-testing:BenchmarkTests/BenchmarkTests/testMultiTurnProbeGrading)
  if [[ $mlx_only == true ]]; then
    prefix="$prefix-mlx"
    test_selection=(-only-testing:BenchmarkTests/BenchmarkTests/testMultiTurnExecuTorchMLX -only-testing:BenchmarkTests/BenchmarkTests/testMultiTurnProbeGrading)
  fi
  if [[ $coreml_only == true ]]; then
    prefix="$prefix-coreml"
    test_selection=(-only-testing:BenchmarkTests/BenchmarkTests/testMultiTurnExecuTorchCoreML -only-testing:BenchmarkTests/BenchmarkTests/testMultiTurnProbeGrading)
  fi
fi
plan_sdk=''
if [[ -f "$derived_data/Build/Products/openweights-build.json" ]]; then
  plan_sdk=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sdk"])' "$derived_data/Build/Products/openweights-build.json")
fi
if [[ -n $plan_sdk ]]; then
  plans=("$derived_data"/Build/Products/*_iphoneos"$plan_sdk"-*.xctestrun)
else
  plans=("$derived_data"/Build/Products/*.xctestrun)
fi
if [[ ${#plans[@]} -ne 1 ]]; then
  echo "Build first. Expected exactly one .xctestrun in $derived_data/Build/Products." >&2
  exit 1
fi
mkdir -p Results
run_name="$prefix-$(date -u +%Y%m%dT%H%M%SZ)"
test_status=0
xcodebuild test-without-building -xctestrun "${plans[0]}" \
  -destination "id=$device_id" -parallel-testing-enabled NO "${test_selection[@]}" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance "$timeout_seconds" \
  -maximum-test-execution-time-allowance "$timeout_seconds" \
  -resultBundlePath "Results/$run_name.xcresult" || test_status=$?
xcrun xcresulttool export attachments --path "Results/$run_name.xcresult" \
  --output-path "Results/$run_name-attachments"
exit "$test_status"
