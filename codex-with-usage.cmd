@echo off
setlocal
set CODEX_USAGE_SOURCE=any
node "%~dp0codex-usage-read.js"
echo.
codex %*
