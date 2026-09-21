@echo off
REM Double-click wrapper for build.ps1 (bypasses PowerShell execution policy).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
