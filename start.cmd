@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%~dp0guardian.ps1""'"
echo DGUT monitor launched. Read guardian-status.json for status.
