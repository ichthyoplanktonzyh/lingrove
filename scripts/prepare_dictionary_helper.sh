#!/bin/bash
# Compile our small helper for both app architectures; no third-party binary is downloaded.
set -euo pipefail
cd "$(dirname "$0")/.."
output_dir="$PWD/build/dictionary-native"
mkdir -p "$output_dir"
for architecture in arm64 x86_64; do
    xcrun clang -arch "$architecture" -mmacosx-version-min=14.0 -O2 -fobjc-arc \
        native/dictionary/system_dictionary.m -framework Foundation -framework CoreServices \
        -o "$output_dir/dictionary-$architecture"
done
lipo -create "$output_dir/dictionary-arm64" "$output_dir/dictionary-x86_64" \
    -output "$output_dir/lingrove-dictionary-helper"
