@echo off
rem CD Catalogue - double-click to start it.
rem Each time, this makes (or refreshes) the CD Catalogue shortcut in this folder and in the Start menu,
rem then starts CD Catalogue from it. After the first run you can use the shortcut, the Start menu or
rem a pinned taskbar button instead: they start CD Catalogue without a console window.
rem The execution-policy bypass applies to CD Catalogue's own run only; no Windows settings are changed.
rem If CD Catalogue doesn't open, run   "CD Catalogue.cmd" debug   to start it in this window and see any errors.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if /i "%~1"=="debug" (
    "%PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0CD-Catalogue.ps1"
    pause
    exit /b
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-CDCatalogueShortcut.ps1" -Launch
if errorlevel 1 pause
