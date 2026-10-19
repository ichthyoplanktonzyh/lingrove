#!/bin/bash
# Build the isolated, pinned llama.cpp audio helper without changing completion's native package.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
runtime_root="$root/build/tts-native"
source_dir="$runtime_root/llama.cpp"
revision="$(tr -d '\n' < native/tts/llama-revision.txt)"
mkdir -p "$runtime_root"
if [[ ! -d "$source_dir/.git" ]]; then
    git init "$source_dir"
    git -C "$source_dir" remote add origin https://github.com/ggml-org/llama.cpp.git
fi
if ! git -C "$source_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
    if [[ -n "$(git -C "$source_dir" ls-files --others)" ]]; then
        echo 'Uninitialized TTS checkout contains files; preserve them before retrying.' >&2
        exit 1
    fi
    git -C "$source_dir" fetch --depth 1 origin "$revision"
    git -C "$source_dir" checkout --detach FETCH_HEAD
fi
if [[ "$(git -C "$source_dir" rev-parse HEAD)" != "$revision" ]]; then
    echo 'TTS source checkout does not match the pinned revision; preserve it before rebuilding.' >&2
    exit 1
fi
streaming_patch="$root/patches/llama-tts-streaming.patch"
# Accept exactly our reviewed overlay, never arbitrary dependency edits. Applying it here
# keeps the decoder correction reproducible in CI without changing autocomplete's ABI.
if git -C "$source_dir" diff --exit-code --quiet HEAD --; then
    git -C "$source_dir" apply --check "$streaming_patch"
    git -C "$source_dir" apply "$streaming_patch"
elif ! git -C "$source_dir" diff --binary | cmp -s - "$streaming_patch"; then
    echo 'TTS source checkout has changes beyond the pinned streaming patch; preserve them before rebuilding.' >&2
    exit 1
fi
if [[ -n "$(git -C "$source_dir" ls-files --others)" ]]; then
    echo 'TTS source checkout contains untracked files; preserve them before rebuilding.' >&2
    exit 1
fi
# Build slices separately: ggml chooses architecture-specific CPU code at CMake configure
# time, so passing a universal architecture list to one configuration would select wrong code.
# A universal helper also keeps the app's Release archive usable on both Mac architectures.
IFS='; ' read -r -a architectures <<< "${CMAKE_OSX_ARCHITECTURES:-arm64;x86_64}"
helpers=()
for architecture in "${architectures[@]}"; do
    case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported TTS architecture: $architecture" >&2; exit 1 ;; esac
    build_dir="$runtime_root/cmake-$architecture"
    # Preserve the already-prepared host cache from the original single-architecture setup.
    if [[ "$architecture" == "$(uname -m)" && -f "$runtime_root/cmake/CMakeCache.txt" ]]; then
        build_dir="$runtime_root/cmake"
    fi
    cmake -S "$root/native/tts" -B "$build_dir" -G Ninja \
        -DLLAMA_SOURCE_DIR="$source_dir" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES="$architecture" \
        -DCMAKE_INSTALL_PREFIX="$runtime_root/install-$architecture"
    cmake --build "$build_dir" --target lingrove-tts-helper --parallel "${TTS_BUILD_JOBS:-4}"
    cmake --install "$build_dir" --component Unspecified
    helpers+=("$runtime_root/install-$architecture/bin/lingrove-tts-helper")
done
mkdir -p "$runtime_root/install/bin"
if [[ "${#helpers[@]}" -eq 1 ]]; then
    cp "${helpers[0]}" "$runtime_root/install/bin/lingrove-tts-helper.next"
else
    lipo -create "${helpers[@]}" -output "$runtime_root/install/bin/lingrove-tts-helper.next"
fi
chmod +x "$runtime_root/install/bin/lingrove-tts-helper.next"
mv "$runtime_root/install/bin/lingrove-tts-helper.next" "$runtime_root/install/bin/lingrove-tts-helper"
