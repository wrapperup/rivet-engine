@echo off
setlocal

set "FONT_DISTANCE_RANGE=1"

if not exist "%~dp0msdf" (
    mkdir "%~dp0msdf"
    if errorlevel 1 exit /b 1
)

msdf-atlas-gen ^
    -font "%~dp0f_roboto_regular.ttf" ^
    -type mtsdf ^
    -size 48 ^
    -emrange %FONT_DISTANCE_RANGE% ^
    -chars "[0x20,0x7E]" ^
    -yorigin top ^
    -format png ^
    -imageout "%~dp0msdf\f_roboto_regular_mtsdf.png" ^
    -json "%~dp0msdf\f_roboto_regular_mtsdf.json"

msdf-atlas-gen ^
    -varfont "%~dp0f_dm_sans_variable.ttf?Weight=400" ^
    -type mtsdf ^
    -size 48 ^
    -emrange %FONT_DISTANCE_RANGE% ^
    -chars "[0x20,0x7E]" ^
    -yorigin top ^
    -format png ^
    -imageout "%~dp0msdf\f_dm_sans_regular_mtsdf.png" ^
    -json "%~dp0msdf\f_dm_sans_regular_mtsdf.json"

msdf-atlas-gen ^
    -varfont "%~dp0f_nunito_variable.ttf?Weight=400" ^
    -type mtsdf ^
    -size 48 ^
    -emrange %FONT_DISTANCE_RANGE% ^
    -chars "[0x20,0x7E]" ^
    -yorigin top ^
    -format png ^
    -imageout "%~dp0msdf\f_nunito_regular_mtsdf.png" ^
    -json "%~dp0msdf\f_nunito_regular_mtsdf.json"
