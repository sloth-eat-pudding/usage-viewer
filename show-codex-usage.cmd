@echo off
setlocal
set CODEX_USAGE_SOURCE=cli
node "%~dp0codex-usage-read.js"
pause
