# 評価ハーネス (test/paper_net_eval_test.dart) 用に Windows 版 ONNX Runtime (MIT) を取得する。
# アプリは C API バージョン 16 を要求するため 1.16 以上が必要。
# 取得物は tools/ort/ (gitignore 済み) に置く。
param(
    [string]$Version = "1.20.1"
)
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $root "tools/ort"
$dll = Join-Path $dest "onnxruntime.dll"
if (Test-Path $dll) {
    Write-Host "already exists: $dll"
    exit 0
}

$name = "onnxruntime-win-x64-$Version"
$url = "https://github.com/microsoft/onnxruntime/releases/download/v$Version/$name.zip"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "$name.zip"
$extract = Join-Path ([System.IO.Path]::GetTempPath()) $name

Write-Host "downloading $url"
Invoke-WebRequest -Uri $url -OutFile $tmp
Expand-Archive -Path $tmp -DestinationPath ([System.IO.Path]::GetTempPath()) -Force

New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $extract "lib/*.dll") $dest
Copy-Item (Join-Path $extract "LICENSE") (Join-Path $dest "LICENSE") -ErrorAction SilentlyContinue
Remove-Item $tmp -Force
Remove-Item $extract -Recurse -Force
Write-Host "installed: $dll"
