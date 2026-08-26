@echo off
setlocal
set "publishedExe=%~dp0..\dist\UsageViewer.exe"
if not exist "%publishedExe%" (
  echo WPF UsageViewer.exe was not found in dist. Publish the desktop app first.
  exit /b 1
)
"%publishedExe%" %*
