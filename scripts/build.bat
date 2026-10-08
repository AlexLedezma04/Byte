@echo off

rem download this:
rem https://nuwen.net/mingw.html

rem build from the repository root, whatever the current folder is
cd /d "%~dp0.."
if not exist build mkdir build

echo compiling (windows)...

windres resources/res.rc -O coff -o build/res.res
gcc src/*.c src/api/*.c src/lib/lua52/*.c src/lib/stb/*.c src/lib/libterminal/*.c^
    -O3 -s -std=gnu11 -fno-strict-aliasing -Isrc -DLUA_USE_POPEN^
    -Iwinlib/SDL2-2.0.10/x86_64-w64-mingw32/include^
    -lmingw32 -lm -lSDL2main -lSDL2 -Lwinlib/SDL2-2.0.10/x86_64-w64-mingw32/lib^
    -mwindows build/res.res^
    -o build/byte.exe
del build\res.res

rem Byte loads its Lua code from data\ next to the executable
xcopy data build\data /e /i /y /q >nul

echo done: build\byte.exe
