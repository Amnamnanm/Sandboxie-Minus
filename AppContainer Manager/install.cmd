@echo off
setlocal
set "TARGET_PS1=%~dp0install\Install.ps1"

if not exist "%TARGET_PS1%" (
    echo [ERROR] Missing "%TARGET_PS1%"
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',([char]34 + $env:TARGET_PS1 + [char]34))"
    exit /b %errorlevel%
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%TARGET_PS1%"