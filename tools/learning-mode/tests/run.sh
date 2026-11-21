#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
# Intentionally fresh and isolated: no access to the active text field or selected input source.
tmp=$(mktemp -d /private/tmp/rime-learning-test.XXXXXX)
swiftc -parse-as-library -target "$(uname -m)-apple-macos26.4" -module-cache-path "${TMPDIR:-/tmp}/rime-learning-module-cache" \
  Sources/EnglishDraft.swift Sources/LearningTranslation.swift tests/StateChecks.swift -o "$tmp/state-checks"
"$tmp/state-checks"
mkdir -p "$tmp/Application Support/Profile"
touch "$tmp/Application Support/Profile/.rime-learning-profile"
LEARNING_TESTS=1 ./build.sh "$tmp/app"
./tests/check-memory.sh "$tmp/app/RimeLearning.app"
"$tmp/app/RimeLearning.app/Contents/MacOS/RimeLearning" --test "$tmp/Application Support/Profile" "$tmp"
echo "Test profile and rendered panels: $tmp"
