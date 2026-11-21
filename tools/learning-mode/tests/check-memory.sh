#!/bin/bash
# ./tests/check-memory.sh NEW_APP [PREVIOUS_APP] (absolute bundle paths)
set -eu
cd "$(dirname "$0")/.."
bundle=${1:?supply absolute path to RimeLearning.app}/Contents
old=${2:-$1}/Contents
tmp=$(mktemp -d /private/tmp/learning-memory.XXXXXX)
mkdir "$tmp/profile"
xcrun clang -Wall -Wextra -I include tests/MemoryChecks.c -L "$bundle/Frameworks" -lrime.1 \
  -Wl,-rpath,"$bundle/Frameworks" -o "$tmp/check"
"$tmp/check" "$old/SharedSupport" "$tmp/profile" seed
for phase in cancel teach recall forget check-forgot; do
  "$tmp/check" "$bundle/SharedSupport" "$tmp/profile" "$phase"
done
