#!/bin/bash
# Build alongside the stock input method; never modify its bundle.
set -eu
cd "$(dirname "$0")"
stock="/Library/Input Methods/Squirrel.app/Contents"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$stock/Info.plist")
[[ "$version" = "1.1.2" ]] || { echo "Requires stock Squirrel 1.1.2 (found: $version)" >&2; exit 1; }
out=${1:-"$PWD/dist/xiaohe-2.9.7"}
if [[ -e "$out/RimeLearning.app" ]]; then
  echo "Existing build kept. Specify a fresh output directory: ./build.sh <directory>" >&2
  exit 1
fi
mkdir -p "$out"
stage=$(mktemp -d "$out/.build.XXXXXX")
app="$stage/RimeLearning.app"
c="$app/Contents"
mkdir -p "$c/MacOS" "$c/Frameworks"
for name in Info.plist Resources; do /usr/bin/ditto "$stock/$name" "$c/$name"; done
/usr/bin/ditto "$stock/Frameworks/librime.1.dylib" "$c/Frameworks/librime.1.dylib"
./prepare-profile.py "$c/SharedSupport"
python3 bundle_info.py "$c"
cp -R Licenses "$c/Resources/"
cp vendor/rime-frost/README.md "$c/Resources/Licenses/Rime-Frost-sources.md"
extra=()
header=Sources/Squirrel-Bridging-Header.h
if [[ "${LEARNING_TESTS:-0}" = 1 ]]; then
  xcrun clang -mmacosx-version-min=26.4 -fobjc-arc -c tests/ProbeClient.m -o "$stage/probe.o" -Wno-protocol
  cat "$header" tests/ProbeClient.h > "$stage/test-bridge.h"
  header="$stage/test-bridge.h"
  extra+=(-D LEARNING_TESTS tests/LearningChecks.swift "$stage/probe.o")
fi
xcrun swiftc -O -swift-version 5 -enable-bare-slash-regex -module-name Squirrel \
  -target "$(uname -m)-apple-macos26.4" -module-cache-path "${TMPDIR:-/tmp}/rime-learning-module-cache" \
  -import-objc-header "$header" -I include \
  -L "$c/Frameworks" -lrime.1 -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  ${extra[@]+"${extra[@]}"} Sources/*.swift -o "$c/MacOS/RimeLearning"
codesign --force --sign - --identifier local.rime.inputmethod.Learning "$app"
codesign --verify --deep --strict "$app"
mv "$app" "$out/RimeLearning.app"
if [[ "${LEARNING_TESTS:-0}" != 1 ]]; then rmdir "$stage"; fi
echo "$out/RimeLearning.app"
