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
/bin/cp "$source_helper" "$destination"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
    codesign --force --timestamp=none --options runtime \
        --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$destination"
fi
