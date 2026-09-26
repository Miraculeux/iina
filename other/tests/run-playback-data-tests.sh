#!/bin/bash
# Run with bash other/tests/run-playback-data-tests.sh. Never touches user data.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$root/other/tests/.playback-data-$(uuidgen)"
mkdir "$work"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$work/module-cache" "$work/fixtures"

xcrun swiftc -module-cache-path "$work/module-cache" \
  "$root/iina/Lock.swift" "$root/iina/Atomic.swift" \
  "$root/iina/PlaybackHistory.swift" "$root/iina/HistoryController.swift" \
  "$root/iina/CacheManager.swift" "$root/other/tests/PlaybackDataTests.swift" \
  -o "$work/playback-data-tests"
"$work/playback-data-tests" "$work/fixtures"

menu="$root/iina/Base.lproj/MainMenu.xib"
legacy="$root/iina/Base.lproj/PrefUtilsViewController.xib"
[[ "$(xmllint --xpath 'count(//menu[@title="File"]/items/menuItem[connections/action[@selector="clearAll:"]][@keyEquivalent="K"][modifierMask[@shift="YES"][@command="YES"]])' "$menu")" == "1" ]]
[[ "$(xmllint --xpath 'count(//action[@selector="clearAllAction:"])' "$legacy")" == "1" ]]
[[ "$(xmllint --xpath 'count(//action[@selector="clearCacheBtnAction:" or @selector="clearHistoryBtnAction:" or @selector="clearWatchLaterBtnAction:"])' "$legacy")" == "0" ]]
echo "PASS: File menu shortcut and single legacy settings action are wired"

export SRCROOT="$work/source"
export TARGET_BUILD_DIR="$work/products"
export UNLOCALIZED_RESOURCES_FOLDER_PATH="IINA.app/Contents/Resources"
export EXECUTABLE_FOLDER_PATH="IINA.app/Contents/MacOS"
source_plugins="$SRCROOT/deps/plugins"
bundled_plugins="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/plugins"
binaries="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH"
mkdir -p "$source_plugins" "$bundled_plugins" "$binaries"
touch "$source_plugins/iina-plugin-opensub-1.iinaplgz" \
  "$source_plugins/iina-plugin-userscript-1.iinaplgz" \
  "$source_plugins/iina-plugin-ytdl-1.iinaplgz" \
  "$bundled_plugins/iina-plugin-opensub-old.iinaplgz" \
  "$bundled_plugins/iina-plugin-userscript-old.iinaplgz" \
  "$bundled_plugins/iina-plugin-ytdl-old.iinaplgz" \
  "$binaries/youtube-dl" "$binaries/iina-cli"
bash "$root/other/copy_default_components.sh"
[[ "$(ls "$bundled_plugins")" == "iina-plugin-opensub-1.iinaplgz" ]]
[[ ! -e "$binaries/youtube-dl" && -f "$binaries/iina-cli" ]]
[[ -f "$source_plugins/iina-plugin-userscript-1.iinaplgz" ]]
bash "$root/other/copy_default_components.sh"
echo "PASS: clean/incremental packaging keeps only OpenSubtitles and preserves dependency sources"

mv "$source_plugins/iina-plugin-opensub-1.iinaplgz" "$work/opensub.iinaplgz"
bash "$root/other/copy_default_components.sh"
[[ -z "$(ls -A "$bundled_plugins")" ]]
echo "PASS: builds without downloaded plugins remove stale bundled archives"

touch "$source_plugins/iina-plugin-opensub-1.iinaplgz" \
  "$source_plugins/iina-plugin-opensub-2.iinaplgz"
if bash "$root/other/copy_default_components.sh"; then
  echo "FAIL: ambiguous OpenSubtitles versions were accepted" >&2
  exit 1
fi
echo "PASS: ambiguous OpenSubtitles versions fail explicitly"
