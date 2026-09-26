#!/bin/bash
set -euo pipefail

: "${SRCROOT:?}"
: "${TARGET_BUILD_DIR:?}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
: "${EXECUTABLE_FOLDER_PATH:?}"

destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/plugins"
mkdir -p "$destination"

# Remove obsolete bundled components left by incremental builds, not user plugins.
find "$destination" -maxdepth 1 -type f -name '*.iinaplgz' -delete
rm -f "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/youtube-dl"

shopt -s nullglob
plugins=("$SRCROOT"/deps/plugins/iina-plugin-opensub-*.iinaplgz)
if [[ ${#plugins[@]} -eq 0 ]]; then
  echo "OpenSubtitles package not found; no default plugins will be bundled."
elif [[ ${#plugins[@]} -eq 1 ]]; then
  cp "${plugins[0]}" "$destination/"
  echo "Bundled OpenSubtitles. User Scripts, Online Media and yt-dlp are not bundled."
else
  echo "Multiple OpenSubtitles packages found. Run other/download_libs.sh to refresh them." >&2
  exit 1
fi
