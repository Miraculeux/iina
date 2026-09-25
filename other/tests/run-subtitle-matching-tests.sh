#!/bin/bash
# Standalone regression suite: ./other/tests/run-subtitle-matching-tests.sh
# Compiles the real FileGroup.swift and AutoFileMatcher.swift, not copies.
# No Xcode target, package dependency, media library, or user preferences needed.
# Test doubles replace playback, preferences, logging, and utility extensions.
# Empty media fixtures only test filename discovery; mpv subtitle loading and
# PlayerCore lifecycle/concurrency are outside this harness.
# In particular, stale cached matches are blocked at loading time by the real
# PlayerCore's `subAutoLoad != .disabled` guard before getMatchedSubs/loadExternalSubFile.
# That PlayerCore-only guard is NOT exercised here: disabled-mode regressions
# verify AutoFileMatcher creates no matches, not that cached matches cannot load.
#
# Build products and fixtures stay in a uniquely named repository-local directory
# (rather than a system temporary directory), removed even on failure.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$root/other/tests/.subtitle-matching-$(uuidgen)"
mkdir "$work"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$work/module-cache" "$work/fixtures"
xcrun swiftc -module-cache-path "$work/module-cache" \
  "$root/iina/FileGroup.swift" \
  "$root/iina/AutoFileMatcher.swift" \
  "$root/other/tests/SubtitleMatchingTestDoubles.swift" \
  "$root/other/tests/SubtitleMatchingTests.swift" \
  -o "$work/subtitle-matching-tests"
"$work/subtitle-matching-tests" "$work/fixtures"
