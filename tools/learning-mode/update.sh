#!/bin/bash
# Replace only a previous Learning build. Keep the installed package and profile for recovery.
set -eu
cd "$(dirname "$0")"
built=${1:?usage: ./update.sh /path/to/RimeLearning.app}
dest="$HOME/Library/Input Methods/RimeLearning.app"
support="$HOME/Library/Application Support/RimeLearning"
id=local.rime.inputmethod.Learning
get() { /usr/libexec/PlistBuddy -c "Print $2" "$1/Contents/Info.plist"; }
[[ "$(get "$built" CFBundleIdentifier)" = "$id" && "$(get "$dest" CFBundleIdentifier)" = "$id" ]]
[[ "$(get "$built" CFBundleVersion)" = "2.9.1" ]]
codesign --verify --strict --deep "$built"
mkdir -p "$support/Backups"
backup=$(mktemp -d "$support/Backups/before-xiaohe.XXXXXX")
echo "Recovery folder: $backup"
ditto -c -k --keepParent "$dest" "$backup/RimeLearning.zip"
unzip -tq "$backup/RimeLearning.zip"
ditto "$built" "$backup/incoming"
codesign --verify --strict --deep "$backup/incoming"
# Only switch away if the installed Learning app is currently providing input.
selection=$(xcrun swift "$PWD/register-upgrade.swift" --prepare)
oldpid=$(pgrep -xf "$dest/Contents/MacOS/RimeLearning" || true)
if [[ -n "$oldpid" ]]; then
  "$dest/Contents/MacOS/RimeLearning" --quit || true
  for _ in {1..40}; do
    kill -0 "$oldpid" 2>/dev/null || break
    sleep .15
  done
  if kill -0 "$oldpid" 2>/dev/null; then echo "Old Learning process is still running. No changes applied." >&2; exit 1; fi
fi
# Preserve the previous profile (including user-learned entries) while its writer is stopped.
if [[ -d "$support/Xiaohe" ]]; then
  ditto -c -k --keepParent "$support/Xiaohe" "$backup/Xiaohe.zip"
  unzip -tq "$backup/Xiaohe.zip"
fi
mv "$dest" "$backup/previous.bundle"
if ! mv "$backup/incoming" "$dest"; then mv "$backup/previous.bundle" "$dest"; exit 1; fi
exe="$dest/Contents/MacOS/RimeLearning"
xcrun swift "$PWD/register-upgrade.swift"
"$exe" --enable-input-source "$id.Hans"
"$exe" --status | grep -Fx "$id.Hans"
if [[ "$selection" = restore-learning ]]; then "$exe" --select-input-source "$id.Hans"; fi
/usr/bin/open -g "$dest"
echo "Active profile: $support/Xiaohe. Earlier profile kept at $support/Profile."
