#!/bin/bash

cd "$(dirname "$0")/.." || exit 1

version="3.4.18"
sha256="9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3"
url="https://github.com/libsdl-org/SDL/releases/download/release-$version/SDL3-$version.tar.gz"
deps="$PWD/build/deps"
src="$deps/SDL3-$version"
prefix="$deps/sdl3"
builddir="$src/build"

if [[ $(uname) == Darwin ]]; then
  jobs=$(sysctl -n hw.ncpu)
  sha256sum() { shasum -a 256 "$@"; }
else
  jobs=$(nproc)
fi

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

if [[ $* == *windows* ]]; then
  off+=(RENDER OPENGL RENDER_D3D RENDER_D3D11 RENDER_D3D12 DIRECTX)
  prefix="$deps/sdl3-windows"
  builddir="$src/build-windows"
  cross=(-DCMAKE_SYSTEM_NAME=Windows
         -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc
         -DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++
         -DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres
         -DCMAKE_FIND_ROOT_PATH=/usr/x86_64-w64-mingw32
         -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
         -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
         -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY)
elif [[ $(uname) == Darwin ]]; then
  cross=(-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
         -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0)
fi

flags=(-DCMAKE_BUILD_TYPE=MinSizeRel -DSDL_STATIC=ON -DSDL_DEPS_SHARED=ON
       -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX="$prefix"
       -DCMAKE_C_FLAGS="-ffunction-sections -fdata-sections" "${cross[@]}")
for o in "${off[@]}"; do flags+=("-DSDL_$o=OFF"); done

echo "building SDL3 $version..."
cmake -S "$src" -B "$builddir" "${flags[@]}" >/dev/null || exit 1
cmake --build "$builddir" -j"$jobs" >/dev/null || exit 1
cmake --install "$builddir" >/dev/null || exit 1
echo "done: $prefix"
