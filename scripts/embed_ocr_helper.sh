#!/bin/bash
set -euo pipefail
source_helper="$SRCROOT/build/ocr-native/lingrove-ocr-helper"
destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/lingrove-ocr-helper"
read -r -a app_architectures <<< "$ARCHS"
lipo "$source_helper" -verify_arch "${app_architectures[@]}"
mkdir -p "$(dirname "$destination")"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
    # Sign a scratch copy before touching the final output, matching the other bundled helpers.
    signing_directory=$(mktemp -d "${TEMP_DIR:-${TMPDIR:-/tmp}}/ocr-sign.XXXXXX")
    trap 'rm -rf "$signing_directory"' EXIT
    /bin/cp "$source_helper" "$signing_directory/lingrove-ocr-helper"
    codesign --force --timestamp=none --options runtime --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
        "$signing_directory/lingrove-ocr-helper"
    source_helper="$signing_directory/lingrove-ocr-helper"
fi
/bin/cp "$source_helper" "$destination"
