#!/bin/bash
# Build the local Vision worker from reviewed source for every architecture shipped by the app.
set -euo pipefail
cd "$(dirname "$0")/.."
output_dir="$PWD/build/ocr-native"
mkdir -p "$output_dir"
for architecture in arm64 x86_64; do
    xcrun swiftc -O -swift-version 5 -target "$architecture-apple-macos14.0" \
        -module-cache-path "$output_dir/ModuleCache.noindex" \
        Lingrove/Models/Context/OCRWorkerProtocol.swift native/ocr/main.swift \
        -framework Vision -framework CoreGraphics -framework NaturalLanguage \
        -o "$output_dir/ocr-$architecture"
done
lipo -create "$output_dir/ocr-arm64" "$output_dir/ocr-x86_64" \
    -output "$output_dir/lingrove-ocr-helper"
