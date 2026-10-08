#!/bin/bash

cd "$(dirname "$0")/.." || exit 1

version="3.4.18"
sha256="9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3"
url="https://github.com/libsdl-org/SDL/releases/download/release-$version/SDL3-$version.tar.gz"
deps="$PWD/build/deps"
src="$deps/SDL3-$version"

mkdir -p "$deps"
if [[ ! -d $src ]]; then
  echo "downloading SDL3 $version..."
  curl -fsSL -o "$deps/sdl3.tar.gz" "$url" || exit 1
  echo "$sha256  $deps/sdl3.tar.gz" | sha256sum -c --quiet || exit 1
  tar xf "$deps/sdl3.tar.gz" -C "$deps" && rm "$deps/sdl3.tar.gz"
fi

off=(
  AUDIO JOYSTICK HAPTIC HIDAPI SENSOR CAMERA POWER GPU VULKAN DIALOG TRAY
  RENDER_GPU RENDER_VULKAN OPENGLES KMSDRM DUMMYVIDEO PIPEWIRE PULSEAUDIO
  ALSA JACK SNDIO LIBUDEV LIBURING FRIBIDI LIBTHAI X11_XTEST X11_XSHAPE
  X11_XDBE X11_XSCRNSAVER TEST_LIBRARY TESTS EXAMPLES SHARED
)
flags=(-DCMAKE_BUILD_TYPE=MinSizeRel -DSDL_STATIC=ON -DSDL_DEPS_SHARED=ON
       -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX="$deps/sdl3")
for o in "${off[@]}"; do flags+=("-DSDL_$o=OFF"); done

echo "building SDL3 $version..."
cmake -S "$src" -B "$src/build" "${flags[@]}" >/dev/null || exit 1
cmake --build "$src/build" -j"$(nproc)" >/dev/null || exit 1
cmake --install "$src/build" >/dev/null || exit 1
echo "done: $deps/sdl3"
