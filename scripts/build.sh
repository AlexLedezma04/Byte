#!/bin/bash

cd "$(dirname "$0")/.." || exit 1
mkdir -p build/obj

cflags="-Wall -O3 -g -std=gnu11 -fno-strict-aliasing -Isrc"
lflags="-lm"

if [[ $* == *windows* ]]; then
  platform="windows"
  outfile="build/byte.exe"
  compiler="x86_64-w64-mingw32-gcc"
  cflags="$cflags -Iwinlib/SDL3-3.4.18/x86_64-w64-mingw32/include"
  lflags="$lflags -Lwinlib/SDL3-3.4.18/x86_64-w64-mingw32/lib -lSDL3"
  lflags="-lmingw32 $lflags -mwindows -o $outfile build/obj/res.res"
  x86_64-w64-mingw32-windres resources/res.rc -O coff -o build/obj/res.res
else
  platform="unix"
  outfile="build/byte"
  compiler="gcc"
  cflags="$cflags -DLUA_USE_POSIX"
  if [[ -z $SDL3_PREFIX && -d build/deps/sdl3 ]]; then
    SDL3_PREFIX="$PWD/build/deps/sdl3"
  fi
  if [[ -n $SDL3_PREFIX ]]; then
    export PKG_CONFIG_PATH="$SDL3_PREFIX/lib/pkgconfig:$SDL3_PREFIX/lib64/pkgconfig"
    sdl_static="--static"
  fi
  cflags="$cflags $(pkg-config --cflags sdl3)"
  lflags="$lflags $(pkg-config $sdl_static --libs sdl3) -lutil -o $outfile"
fi

if command -v ccache >/dev/null; then
  compiler="ccache $compiler"
fi


echo "compiling ($platform)..."
for f in `find src -name "*.c"`; do
  $compiler -c $cflags $f -o "build/obj/${f//\//_}.o"
  if [[ $? -ne 0 ]]; then
    got_error=true
  fi
done

if [[ ! $got_error ]]; then
  echo "linking..."
  $compiler build/obj/*.o $lflags
fi

ln -sfn ../data build/data

echo "cleaning up..."
rm -rf build/obj
echo "done: $outfile"
