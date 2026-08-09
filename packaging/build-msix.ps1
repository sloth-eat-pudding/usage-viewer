$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$publish = Join-Path $root 'dist'
$package = Join-Path $root 'packages\UsageViewer'
$makeAppx = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter makeappx.exe -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\x64\\makeappx\.exe$' } | Select-Object -First 1
if (-not $makeAppx) { throw 'Windows SDK makeappx.exe not found. Install Windows SDK to create an MSIX.' }
if (-not (Test-Path (Join-Path $publish 'UsageViewer.exe'))) { throw 'Run dotnet publish first.' }
New-Item -ItemType Directory -Force -Path (Join-Path $package 'Assets') | Out-Null
Copy-Item (Join-Path $publish '*') $package -Force
Copy-Item (Join-Path $PSScriptRoot 'AppxManifest.xml') $package -Force
Copy-Item (Join-Path $root 'packaging\Assets\*.png') (Join-Path $package 'Assets') -Force
& $makeAppx.FullName pack /d $package /p (Join-Path $root 'packages\UsageViewer.msix') /o
