#!/bin/bash

cd "$(dirname "$0")/.." || exit 1
scripts/build.sh release windows
scripts/build.sh release
cd build || exit 1
rm byte.zip 2>/dev/null
cp ../winlib/SDL3-3.4.18/x86_64-w64-mingw32/bin/SDL3.dll SDL3.dll
strip byte
strip byte.exe
strip SDL3.dll
zip byte.zip byte byte.exe SDL3.dll data -r
