#!/bin/bash
# Xcode's sandboxed copy phase embeds the already-prepared helper in either app identity.
set -euo pipefail
source_helper="$SRCROOT/build/tts-native/install/bin/lingrove-tts-helper"
destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/lingrove-tts-helper"
if [[ ! -x "$source_helper" ]]; then
    echo 'error: Prepare the pinned TTS helper with scripts/prepare_cotabby_workspace.sh first.' >&2
    exit 1
fi
# Refuse a bundle whose helper cannot run on an architecture advertised by the app.
read -r -a app_architectures <<< "$ARCHS"
lipo "$source_helper" -verify_arch "${app_architectures[@]}"
mkdir -p "$(dirname "$destination")"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
    # codesign creates a temporary sibling before replacing its input. Keep those scratch writes
    # in TEMP_DIR, where Xcode's script sandbox permits them, and only copy the final signed file.
    signing_directory=$(mktemp -d "${TEMP_DIR:-${TMPDIR:-/tmp}}/speech-sign.XXXXXX")
    trap 'rm -rf "$signing_directory"' EXIT
    /bin/cp "$source_helper" "$signing_directory/lingrove-tts-helper"
    codesign --force --timestamp=none --options runtime \
        --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$signing_directory/lingrove-tts-helper"
    source_helper="$signing_directory/lingrove-tts-helper"
fi
/bin/cp "$source_helper" "$destination"
