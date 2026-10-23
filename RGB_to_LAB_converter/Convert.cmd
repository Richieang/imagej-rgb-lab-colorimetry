@echo off
rem Converts every raw-RGB CSV in RawRGB_input into a LAB / Delta E / hue workbook in output.
rem Uses only Windows PowerShell, so it runs on any Windows computer without installing anything.
if not exist "%~dp0engine\Convert_RGB_to_LAB.ps1" (
  echo The converter files were not found next to Convert.cmd.
  echo This happens when Convert.cmd is started from inside the ZIP file.
  echo.
  echo Please extract the ZIP first: right-click it, choose "Extract All...",
  echo then put your CSV into RawRGB_input of the extracted folder and run Convert.cmd there.
  echo.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0engine\Convert_RGB_to_LAB.ps1"
echo.
echo Results are in: %~dp0output
pause
