@echo off
rem Converts every raw-RGB CSV in RawRGB_input into a LAB / Delta E / hue workbook in output.
rem Uses only Windows PowerShell, so it runs on any Windows computer without installing anything.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0engine\Convert_RGB_to_LAB.ps1"
echo.
echo Results are in: %~dp0output
pause
