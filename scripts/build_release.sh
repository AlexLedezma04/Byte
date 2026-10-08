#!/bin/bash

cd "$(dirname "$0")/.." || exit 1
scripts/build.sh release windows
scripts/build.sh release
cd build || exit 1
rm byte.zip 2>/dev/null
cp ../winlib/SDL2-2.0.10/x86_64-w64-mingw32/bin/SDL2.dll SDL2.dll
strip byte
strip byte.exe
strip SDL2.dll
zip byte.zip byte byte.exe SDL2.dll data -r
