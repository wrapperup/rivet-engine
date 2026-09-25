@echo off
setlocal

if not exist "build" (
    mkdir "build"
    if errorlevel 1 exit /b 1
)

if not defined ODIN set "ODIN=odin"
if not exist "build\build.exe" goto build_tool

rem check if the build script src is newer than exe
for %%s in (build.odin meta\*.odin) do (
    xcopy /d /l /y "%%s" "build\build.exe" | findstr /b /c:"0 " >nul
    if errorlevel 1 goto build_tool
)
goto run_build

:build_tool
"%ODIN%" build build.odin -file -o:none -out:build/build.exe
if errorlevel 1 exit /b %ERRORLEVEL%

:run_build
build\build.exe %*
exit /b %ERRORLEVEL%
