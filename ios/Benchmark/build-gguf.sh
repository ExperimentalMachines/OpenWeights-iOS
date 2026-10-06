#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build Results
llama_source=../../core/engine/src/main/cpp/llama.cpp
if [[ "$(git -C "$llama_source" rev-parse HEAD)" != b2e5e9b28b2484fbf94b543432ece638996a8b97 ]]; then
  echo 'The older-iOS comparison requires the pinned llama.cpp revision.' >&2
  exit 1
fi
# Only the recorded graph-offset patch may modify the pinned dependency.
llama_status=$(git -C "$llama_source" status --porcelain)
if [[ -n "$llama_status" && "$llama_status" != ' M ggml/src/ggml.c' ]]; then
  echo 'Unexpected changes in the pinned llama.cpp submodule.' >&2
  exit 1
fi
cmake -P ../../core/engine/src/main/cpp/PatchGGMLGraphOffset.cmake
toolchain_build=$(xcodebuild -version | awk '/Build version/ {print $3}')
native_build=".build/native-gguf16-$toolchain_build-ninja"
before="$PWD/.build/gguf-build-inputs-before.json"
python3 Export/build_receipt.py capture --gguf-only --output "$before"
cmake -G Ninja -S Native -B "$native_build" \
  -DCMAKE_C_COMPILER="$(xcrun --find clang)" -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.6 \
  -DCMAKE_BUILD_TYPE=Release -DOW_GGUF_ONLY=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$native_build" -j 6
xcodegen generate --spec project-gguf.yml
xcodebuild -project OpenWeightsGGUFBench.xcodeproj -scheme OpenWeightsGGUFBench \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .build/DerivedData-gguf16 -allowProvisioningUpdates -jobs 6 \
  build-for-testing "OW_NATIVE_BUILD=$native_build" "$@"
python3 Export/build_receipt.py stamp --gguf-only --expected "$before"
