#!/bin/bash
# Run with bash other/tests/run-playlist-startup-tests.sh. Never touches user data.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/iina-playlist-startup.XXXXXX")"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -module-cache-path "$work/module-cache" \
  "$root/iina/PlaylistStartupFallback.swift" "$root/other/tests/PlaylistStartupFallbackTests.swift" \
  -o "$work/playlist-startup-tests"
"$work/playlist-startup-tests"
for plist in "$root/iina/Info.plist" "$root/iina/en.lproj/InfoPlist.strings" \
             "$root/iina/zh-Hans.lproj/InfoPlist.strings" "$root/iina/zh-Hant.lproj/InfoPlist.strings"; do
  plutil -lint "$plist"
  [[ -n "$(/usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' "$plist")" ]]
done
echo "PASS: local-network permission description and English/Chinese localizations"
