#!/bin/bash

cd "$(dirname "$0")/.." || exit 1
mkdir -p build/obj

cflags="-Wall -O3 -g -std=gnu11 -fno-strict-aliasing -Isrc"
lflags="-lSDL2 -lm"

if [[ $* == *windows* ]]; then
  platform="windows"
  outfile="build/byte.exe"
  compiler="x86_64-w64-mingw32-gcc"
  cflags="$cflags -DLUA_USE_POPEN -Iwinlib/SDL2-2.0.10/x86_64-w64-mingw32/include"
  lflags="$lflags -Lwinlib/SDL2-2.0.10/x86_64-w64-mingw32/lib"
  lflags="-lmingw32 -lSDL2main $lflags -mwindows -o $outfile build/obj/res.res"
  x86_64-w64-mingw32-windres resources/res.rc -O coff -o build/obj/res.res
else
  platform="unix"
  outfile="build/byte"
  compiler="gcc"
  cflags="$cflags -DLUA_USE_POSIX"
  lflags="$lflags -lutil -o $outfile"
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
