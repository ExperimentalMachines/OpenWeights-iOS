#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
root="$PWD"
derived_data=DerivedData
archive=OpenWeightsBench-tests.zip
suite=pilot
receipt_args=()
for argument in "$@"; do
  case "$argument" in
    --delegates) derived_data=DerivedData-delegates; archive=OpenWeightsDelegatesBench-tests.zip; receipt_args+=(--delegates) ;;
    --gguf-only) derived_data=DerivedData-gguf16; archive=OpenWeightsGGUFBench-tests.zip; receipt_args+=(--gguf-only) ;;
    --suite=*) suite=${argument#*=} ;;
    --scenario=*|--block=*|--attempt=*|--runtime=*) receipt_args+=("$argument") ;;
    --firebase) receipt_args+=(--firebase) ;;
    *) echo 'Usage: ./package.sh [--delegates|--gguf-only] [--suite=pilot|smoke|multi-turn|mlx-multi-turn|coreml-multi-turn|study] [--firebase]' >&2; exit 2 ;;
  esac
done
products="$root/.build/$derived_data/Build/Products"
codesign --verify --deep --strict "$products/Release-iphoneos/OpenWeightsBench.app"
mkdir -p "$root/.build/package-$derived_data" Results
plan="$root/.build/package-$derived_data/OpenWeights-$suite.xctestrun"
python3 Export/build_receipt.py plan "${receipt_args[@]}" --suite "$suite" --output "$plan"
archive=${archive%-tests.zip}-$suite-tests.zip
rm -f "Results/$archive"
cd "$products"
zip -qr "$root/Results/$archive" Release-iphoneos
cd "$(dirname "$plan")"
zip -qj "$root/Results/$archive" "$(basename "$plan")"
cp "$products/openweights-build.json" "$root/Results/${archive%.zip}-build.json"
echo "$root/Results/$archive"
