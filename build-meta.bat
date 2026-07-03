@echo off
setlocal

set FLAGS=^
    -collection:deps=deps ^
    -custom-attribute:shader_shared ^
    -custom-attribute:entity ^
    -debug ^
    -o:none ^
    -show-timings ^
    -define:GENERATING_META=true

odin build meta -out:build/meta.exe %FLAGS% || exit /b %ERRORLEVEL%
