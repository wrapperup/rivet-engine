@echo off
setlocal

set "BUILD_TOOL=build\build.exe"
set "PENDING_BUILD_TOOL=build\build.next.exe"
set "BUILD_TOOL_RESTART_EXIT_CODE=75"

if exist "build" goto build_directory_ready
mkdir "build"
if errorlevel 1 exit /b %ERRORLEVEL%

:build_directory_ready

if exist "%BUILD_TOOL%" goto run_build_tool
echo Build tool missing; compiling build.odin...
odin build build.odin -file -o:none -out:%BUILD_TOOL%
if errorlevel 1 exit /b %ERRORLEVEL%

:run_build_tool
"%BUILD_TOOL%" %*
set "BUILD_EXIT_CODE=%ERRORLEVEL%"

if not "%BUILD_EXIT_CODE%"=="%BUILD_TOOL_RESTART_EXIT_CODE%" (
    exit /b %BUILD_EXIT_CODE%
)

if not exist "%PENDING_BUILD_TOOL%" (
    echo Build tool requested a restart, but %PENDING_BUILD_TOOL% was not created.
    exit /b 1
)

move /y "%PENDING_BUILD_TOOL%" "%BUILD_TOOL%" >nul
if errorlevel 1 (
    echo Failed to replace %BUILD_TOOL% with the rebuilt executable.
    exit /b %ERRORLEVEL%
)

goto run_build_tool
