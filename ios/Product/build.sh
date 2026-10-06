#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
toolchain_build=$(xcodebuild -version | awk '/Build version/ {print $3}')
native_build="../Benchmark/.build/native-$toolchain_build-ninja"
if [[ ! -f "$native_build/libopenweights_apple.a" ]]; then
  echo 'Build the benchmark native libraries using the same selected Xcode toolchain first.' >&2
  exit 1
fi
build_args=()
unsigned_build=false
for argument in "$@"; do
  case "$argument" in
    PRODUCT_BUNDLE_IDENTIFIER=org.experimentalmachines.openweights.benchmark)
      build_args+=("OW_APP_BUNDLE_ID=org.experimentalmachines.openweights.benchmark" "OW_SCRIPT_BINDING_CONDITION=OW_BENCHMARK_SLOT") ;;
    PRODUCT_BUNDLE_IDENTIFIER=org.experimentalmachines.openweights.ios)
      build_args+=("OW_APP_BUNDLE_ID=org.experimentalmachines.openweights.ios") ;;
    PRODUCT_BUNDLE_IDENTIFIER=*)
      echo 'The script extension currently binds only to the product or existing benchmark bundle identifier.' >&2; exit 1 ;;
    CODE_SIGNING_ALLOWED=NO) unsigned_build=true; build_args+=("$argument") ;;
    BACKGROUND_DOWNLOAD_VALIDATION=YES)
      build_args+=("OW_BACKGROUND_VALIDATION_CONDITION=OW_BACKGROUND_DOWNLOAD_VALIDATION") ;;
    SCRIPT_SECURITY_VALIDATION=YES)
      build_args+=("OW_SCRIPT_VALIDATION_CONDITION=OW_SCRIPT_SECURITY_VALIDATION") ;;
    INFERENCE_MEMORY_LIMIT=YES)
      build_args+=("OW_INFERENCE_ENTITLEMENTS=InferenceExtension/InferenceMemory.entitlements") ;;
    *) build_args+=("$argument") ;;
  esac
done
python3 prepare_inference_dependencies.py
xcodegen generate
mkdir -p OpenWeights.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp App-Package.resolved OpenWeights.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
cmake -P ../../core/engine/src/main/cpp/PatchGGMLGraphOffset.cmake
python3 build_receipt.py capture
cmake -S Native/Script -B .build/script-ios -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$PWD/../Benchmark/.build/build-tools/bin/ninja" \
  -DCMAKE_C_COMPILER="$(xcrun --find clang)" -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release
cmake --build .build/script-ios -j 6
# The product links this shared archive. An existing archive alone does not prove
# that its objects were built from the engine sources captured in this receipt.
cmake --build "$native_build" -j 6
xcodebuild -project OpenWeights.xcodeproj -scheme OpenWeights -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath ../Benchmark/.build/packages -onlyUsePackageVersionsFromResolvedFile \
  -skipPackagePluginValidation -allowProvisioningUpdates -jobs 6 build-for-testing "OW_NATIVE_BUILD=$native_build" "${build_args[@]}"
if [[ "$unsigned_build" == false ]]; then
  python3 build_receipt.py stamp --expected .build/product-source-inputs-before.json
else
  echo 'Unsigned compilation completed. No signed product receipt was stamped.'
fi
