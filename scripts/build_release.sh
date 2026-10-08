#!/bin/bash

cd "$(dirname "$0")/.." || exit 1
set -e

pack() {
  local name=$1 zip="$PWD/build/$1" stage
  shift
  stage=$(mktemp -d)
  mkdir "$stage/byte"
  cp "$@" "$stage/byte/"
  cp -r data "$stage/byte/data"
  rm -f "$zip"
  (cd "$stage" && python3 -m zipfile -c "$zip" byte)
  rm -rf "$stage"
  echo "packed: build/$name ($(du -h "$zip" | cut -f1))"
}

scripts/build.sh release
pack byte-linux.zip build/byte

if command -v x86_64-w64-mingw32-gcc >/dev/null; then
  scripts/build.sh release windows
  if [[ -d build/deps/sdl3-windows ]]; then
    pack byte-windows.zip build/byte.exe
  else
    x86_64-w64-mingw32-strip -o build/SDL3.dll \
      winlib/SDL3-3.4.18/x86_64-w64-mingw32/bin/SDL3.dll
    pack byte-windows.zip build/byte.exe build/SDL3.dll
    rm build/SDL3.dll
  fi
else
  echo "skipped windows: x86_64-w64-mingw32-gcc not found"
fi
