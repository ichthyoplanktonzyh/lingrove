#!/bin/bash
set -euo pipefail
source_helper="$SRCROOT/build/dictionary-native/lingrove-dictionary-helper"
destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/lingrove-dictionary-helper"
read -r -a app_architectures <<< "$ARCHS"
lipo "$source_helper" -verify_arch "${app_architectures[@]}"
mkdir -p "$(dirname "$destination")"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
    # Xcode grants this sandboxed phase the final output file, not temporary siblings beside
    # it. Sign in the phase's writable scratch area, then copy the completed Mach-O signature.
    signing_directory=$(mktemp -d "${TEMP_DIR:-${TMPDIR:-/tmp}}/dictionary-sign.XXXXXX")
    trap 'rm -rf "$signing_directory"' EXIT
    /bin/cp "$source_helper" "$signing_directory/lingrove-dictionary-helper"
    codesign --force --timestamp=none --options runtime --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
        "$signing_directory/lingrove-dictionary-helper"
    source_helper="$signing_directory/lingrove-dictionary-helper"
fi
/bin/cp "$source_helper" "$destination"
