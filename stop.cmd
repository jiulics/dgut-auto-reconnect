@echo off
powershell.exe -NoProfile -Command "New-Item -ItemType File -Path '%~dp0guardian.stop' -Force | Out-Null"
echo Stop requested. In-flight checks can take up to about 24 seconds.
