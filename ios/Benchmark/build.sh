#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p .build Results
tokenizer_revision=a7855194f5bf55f792f8142282dd0ae3613b1d37
if [[ ! -d .build/deps/tokenizers/.git ]]; then
  git clone --no-checkout --filter=blob:none https://github.com/meta-pytorch/tokenizers.git .build/deps/tokenizers
  git -C .build/deps/tokenizers checkout --detach "$tokenizer_revision"
fi
if [[ "$(git -C .build/deps/tokenizers rev-parse HEAD)" != "$tokenizer_revision" ]]; then
  echo 'Tokenizer source differs from the pinned ExecuTorch revision.' >&2
  exit 1
fi
git -C .build/deps/tokenizers submodule update --init --depth 1 third-party/pcre2
toolchain_build=$(xcodebuild -version | awk '/Build version/ {print $3}')
native_build=".build/native-$toolchain_build-ninja"
cmake -G Ninja -S Native -B "$native_build" \
  -DCMAKE_C_COMPILER="$(xcrun --find clang)" -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$native_build" -j 6
xcodegen generate
mkdir -p OpenWeightsBench.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved OpenWeightsBench.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

# The pinned MLX CUDA plugin returns no commands on Apple hosts. Xcode still asks
# for plugin trust before compiling it, so unattended builds need this flag.
xcodebuild -project OpenWeightsBench.xcodeproj -scheme OpenWeightsBench \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/packages \
  -onlyUsePackageVersionsFromResolvedFile -skipPackagePluginValidation \
  -allowProvisioningUpdates -jobs 6 build-for-testing "OW_NATIVE_BUILD=$native_build" "$@"
python3 Export/build_receipt.py stamp
