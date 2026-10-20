#!/bin/bash
set -euo pipefail
source_helper="$SRCROOT/build/dictionary-native/lingrove-dictionary-helper"
destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/lingrove-dictionary-helper"
read -r -a app_architectures <<< "$ARCHS"
lipo "$source_helper" -verify_arch "${app_architectures[@]}"
mkdir -p "$(dirname "$destination")"
/bin/cp "$source_helper" "$destination"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
    codesign --force --timestamp=none --options runtime --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$destination"
fi
