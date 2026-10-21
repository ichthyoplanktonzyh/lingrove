#!/bin/bash
# Both app identities embed the same transport client; it reads its containing bundle at runtime.
set -euo pipefail
destination="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
mkdir -p "$destination"
install -m 755 "${BUILT_PRODUCTS_DIR}/lingrove" "$destination/lingrove"
