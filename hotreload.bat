@echo off
setlocal

set FLAGS=src ^
    -build-mode:dll ^
    -collection:deps=deps ^
    -custom-attribute:shader_shared ^
    -custom-attribute:entity ^
    -show-timings ^
    -extra-linker-flags:/NODEFAULTLIB:libcmt ^
    -linker=radlink ^
    -debug ^
    -o:none ^
    -out:build/debug/game.dll

odin build %FLAGS% || exit /b %ERRORLEVEL%

exit /b 0
