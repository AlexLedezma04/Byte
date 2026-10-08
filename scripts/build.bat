@echo off

rem download this:
rem https://nuwen.net/mingw.html

rem build from the repository root, whatever the current folder is
cd /d "%~dp0.."
if not exist build mkdir build

echo compiling (windows)...

windres resources/res.rc -O coff -o build/res.res
gcc src/*.c src/api/*.c src/lib/lua/*.c src/lib/stb/*.c src/lib/libterminal/*.c src/lib/libvterm/*.c^
    -Os -s -ffunction-sections -fdata-sections -Wl,--gc-sections^
    -std=gnu11 -fno-strict-aliasing -Isrc^
    -Iwinlib/SDL3-3.4.18/x86_64-w64-mingw32/include^
    -lmingw32 -lm -lSDL3 -Lwinlib/SDL3-3.4.18/x86_64-w64-mingw32/lib^
    -mwindows build/res.res^
    -o build/byte.exe
del build\res.res

rem Byte loads its Lua code from data\ next to the executable
xcopy data build\data /e /i /y /q >nul
copy /y winlib\SDL3-3.4.18\x86_64-w64-mingw32\bin\SDL3.dll build >nul

echo done: build\byte.exe
