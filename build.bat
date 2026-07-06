@echo off
setlocal

set META_EXE=build\meta.exe
set META_BUILD_SCRIPT=build-meta.bat

if not exist "build" (
    mkdir "build"
)

if "%~1"=="1" (
    if not exist "build/release" (
        mkdir "build/release"
    )
) else (
    if not exist "build/debug" (
        mkdir "build/debug"
    )
)

if not exist "%META_EXE%" (
    echo Metaprogram missing, building...
    call %META_BUILD_SCRIPT%
)

:: Run metaprogram
%META_EXE%

if %ERRORLEVEL% neq 0 (
    echo Meta program failed with exit code %ERRORLEVEL%.
    exit /b %ERRORLEVEL%
)

set BASE_FLAGS=entrypoints ^
    -collection:deps=deps ^
    -custom-attribute:shader_shared ^
    -custom-attribute:entity ^
    -show-timings ^
    -linker=radlink

:: If first arg is "1", do release; otherwise hotreloadable debug (with hotreload)
if "%~1"=="1" (
    set FLAGS=%BASE_FLAGS% ^
        -o:speed ^
        -out:build/release/main.exe
) else (
    echo Building with hotreload
    set FLAGS=%BASE_FLAGS% ^
        -debug ^
        -o:none ^
        -define:HOTRELOAD=true ^
        -define:GLFW_SHARED=true ^
        -out:build/debug/main.exe

    call .\hotreload.bat
)

odin build %FLAGS%

exit /b %ERRORLEVEL%
