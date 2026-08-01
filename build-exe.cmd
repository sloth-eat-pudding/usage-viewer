@echo off
setlocal
pushd "%~dp0"
dotnet publish ".\src\UsageViewer\UsageViewer.csproj" -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true
if errorlevel 1 exit /b %errorlevel%
copy /Y ".\src\UsageViewer\bin\Release\net7.0-windows\win-x64\publish\UsageViewer.exe" ".\UsageViewer.exe" >nul
echo Built .\UsageViewer.exe
popd
