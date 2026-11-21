#!/bin/bash
# First install only. Keep the original input source and the current selection untouched.
set -eu
cd "$(dirname "$0")"
built=${1:-"$PWD/dist/xiaohe-2.7.6/RimeLearning.app"}
dest="$HOME/Library/Input Methods/RimeLearning.app"
[[ ! -e "$dest" ]] || { echo "An existing learning app is installed at $dest; no changes made." >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$built/Contents/Info.plist")" = "local.rime.inputmethod.Learning" ]]
codesign --verify --strict --deep "$built"
mkdir -p "$HOME/Library/Input Methods"
ditto "$built" "$dest"
exe="$dest/Contents/MacOS/RimeLearning"
"$exe" --register-input-source
"$exe" --enable-input-source local.rime.inputmethod.Learning.Hans
if ! "$exe" --status | grep -Fxq local.rime.inputmethod.Learning.Hans; then
  echo "Copied to $dest. macOS has not enabled it yet. Add 鼠须管·学英语 under Keyboard → Input Sources." >&2
  exit 1
fi
echo "Enabled 鼠须管·学英语 alongside Squirrel. Current input source unchanged."
