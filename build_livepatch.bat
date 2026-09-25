@echo off
setlocal
set "PATCH_DIRECTORY=%~f1"
pushd "%~dp0"
if errorlevel 1 exit /b 1

if "%~1"=="" (
    call build.bat
) else (
    call build.bat "--patch-dir=%PATCH_DIRECTORY%"
)
set "BUILD_EXIT_CODE=%ERRORLEVEL%"
popd
exit /b %BUILD_EXIT_CODE%
