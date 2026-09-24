@echo off
setlocal

if not exist "build" (
    mkdir "build"
    if errorlevel 1 exit /b 1
)

odin build build.odin -file -o:none -out:build/build.exe
if errorlevel 1 exit /b %ERRORLEVEL%

build\build.exe %*
exit /b %ERRORLEVEL%
