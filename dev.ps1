<#
.SYNOPSIS
  MyMusicBook の開発用メンテナンススクリプト。

.DESCRIPTION
  使い方: ./dev.ps1 <コマンド> [オプション]

  run        実機でアプリを起動する (既定: debug。ホットリロード可)
  install    APK をビルドして実機にインストールする (既定: release)
  logs       実機のアプリのログを表示する (Ctrl+C で終了)
  devices    接続中のデバイス一覧
  analyze    flutter analyze
  test       flutter test (評価ハーネスは評価データが無ければスキップ)
  eval       紙面検出モデルを評価する (training_data/eval)
  pull       実機に貯めた切り抜き結果を training_data/eval に取り込む
  selftest   実機で紙面検出の自己診断 (画像を送り、推論時間と精度を回収する)
  train      紙面検出モデル (v2) を学習する (tools/.venv を自動作成)
  doctor     flutter / adb / 学習環境 / ORT の状態を確認する
  clean      flutter clean + pub get

.EXAMPLE
  ./dev.ps1 run                    # 実機で debug 起動
  ./dev.ps1 run -Mode profile      # 速度確認は profile (release に近い性能 + DevTools)
  ./dev.ps1 install                # release APK を入れる
  ./dev.ps1 logs -Filter PaperNet  # 紙面検出のログだけ
  ./dev.ps1 eval -Model build/paper_seg_v2.onnx
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('run', 'install', 'logs', 'devices', 'analyze', 'test', 'eval', 'pull',
                 'train', 'doctor', 'clean', 'selftest', 'help')]
    [string]$Command = 'help',

    # run / install のビルドモード
    [ValidateSet('debug', 'profile', 'release')]
    [string]$Mode,

    # 対象デバイス ID (省略時は接続中の最初の Android 実機)
    [string]$Device,

    # logs: この文字列を含む行だけ表示
    [string]$Filter,

    # eval: 評価するモデル
    [string]$Model = 'assets/models/paper_seg.onnx',

    # eval: 評価データ (<id>.jpg + <id>.json)。training_data/eval_heldout は学習に未使用の実写
    [string]$Data = 'training_data/eval',

    # train: 学習ステップ数
    [int]$Steps = 2500,

    # 残りの引数はそのまま flutter などへ渡す
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$AppId = 'com.kjranyone.mymusicbook'
$CaptureDir = "/sdcard/Android/data/$AppId/files/training_captures"
$SelfTestDir = "/sdcard/Android/data/$AppId/files/selftest"
Set-Location $Root

# ------------------------------------------------------------------ ツール探索

function Find-Flutter {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @()
    if ($env:FLUTTER_ROOT) { $candidates += (Join-Path $env:FLUTTER_ROOT 'bin/flutter.bat') }
    $candidates += 'C:\lib\flutter\bin\flutter.bat', 'C:\flutter\bin\flutter.bat',
                   'C:\src\flutter\bin\flutter.bat', (Join-Path $HOME 'flutter\bin\flutter.bat')
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    throw 'flutter が見つかりません。PATH に追加するか FLUTTER_ROOT を設定してください。'
}

function Find-Adb {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $sdks = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk')) |
        Where-Object { $_ }
    foreach ($s in $sdks) {
        $adb = Join-Path $s 'platform-tools\adb.exe'
        if (Test-Path $adb) { return $adb }
    }
    throw 'adb が見つかりません。Android SDK の platform-tools を入れてください。'
}

$script:FlutterExe = $null
function Invoke-Flutter {
    if (-not $script:FlutterExe) { $script:FlutterExe = Find-Flutter }
    & $script:FlutterExe @args
    if ($LASTEXITCODE -ne 0) { throw "flutter $($args -join ' ') が失敗しました (exit $LASTEXITCODE)" }
}

function Get-AndroidDevice {
    if ($Device) { return $Device }
    $flutter = Find-Flutter
    $json = & $flutter devices --machine 2>$null | Out-String
    $devices = @()
    try { $devices = @($json | ConvertFrom-Json) } catch { }
    $android = @($devices | Where-Object { $_.targetPlatform -like 'android*' -and -not $_.emulator })
    if ($android.Count -eq 0) {
        $android = @($devices | Where-Object { $_.targetPlatform -like 'android*' })
    }
    if ($android.Count -eq 0) {
        throw @'
Android 実機が見つかりません。
  - USB で接続し、端末の「USB デバッグ」を ON にしてください
  - 端末に出る「USB デバッグを許可しますか?」を許可してください
  - ./dev.ps1 devices で認識を確認できます
'@
    }
    if ($android.Count -gt 1) {
        Write-Host "複数の Android 端末があります。先頭を使います (-Device で指定可):" -ForegroundColor Yellow
        $android | ForEach-Object { Write-Host "  $($_.id)  $($_.name)" }
    }
    Write-Host "device: $($android[0].name) ($($android[0].id))" -ForegroundColor Cyan
    return $android[0].id
}

function Get-PubspecBuildNumber {
    $line = Select-String -Path (Join-Path $Root 'pubspec.yaml') -Pattern '^version:\s*[^+\s]+\+(\d+)' |
        Select-Object -First 1
    if ($line) { return [int]$line.Matches[0].Groups[1].Value }
    return 1
}

# 端末に入っているアプリの versionCode (未インストールなら 0)
function Get-InstalledVersionCode([string]$id) {
    $adb = Find-Adb
    $out = & $adb -s $id shell dumpsys package $AppId 2>$null | Out-String
    $m = [regex]::Match($out, 'versionCode=(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}

# 端末の ABI → flutter の --target-platform
function Get-TargetPlatform([string]$id) {
    $adb = Find-Adb
    $abi = (& $adb -s $id shell getprop ro.product.cpu.abi 2>$null | Out-String).Trim()
    switch ($abi) {
        'arm64-v8a' { return 'android-arm64' }
        'armeabi-v7a' { return 'android-arm' }
        'x86_64' { return 'android-x64' }
        default { throw "未対応の ABI です: '$abi'" }
    }
}

# 端末の版より古い versionCode で入れると、インストールが失敗し、
# flutter run はアプリをアンインストールして入れ直す (= 端末内の教材データが消える)。
# ビルド前にこれを検出して止める。対処は pubspec.yaml の +ビルド番号 を上げること。
function Assert-NoDowngrade([string]$id) {
    $installed = Get-InstalledVersionCode $id
    $build = Get-PubspecBuildNumber
    if ($installed -gt $build) {
        throw @"
端末の versionCode ($installed) が pubspec.yaml のビルド番号 ($build) より新しいため中止しました。
このまま入れると flutter run はアプリをアンインストールして入れ直し、端末内のデータが消えます。
pubspec.yaml の version の +$build を $installed より大きい値に上げてください。
"@
    }
    Write-Host "versionCode: 端末 $installed / ビルド $build" -ForegroundColor DarkGray
}

function Get-VenvPython {
    $py = Join-Path $Root 'tools/.venv/Scripts/python.exe'
    if (Test-Path $py) { return $py }
    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if (-not $uv) { throw 'uv が見つかりません (winget install astral-sh.uv)。' }
    Write-Host '学習環境 tools/.venv を作成します (初回のみ, torch CPU 版をダウンロード)' -ForegroundColor Cyan
    # 壊れた system Python (miniconda 等) を拾わないよう uv 管理の Python を使う
    & uv venv (Join-Path $Root 'tools/.venv') --python-preference only-managed --python 3.12
    & uv pip install --python $py torch torchvision --index-url https://download.pytorch.org/whl/cpu
    & uv pip install --python $py numpy pillow onnx onnxruntime opencv-python-headless
    if (-not (Test-Path $py)) { throw 'tools/.venv の作成に失敗しました。' }
    return $py
}

function Ensure-Ort {
    if (-not (Test-Path (Join-Path $Root 'tools/ort/onnxruntime.dll'))) {
        & (Join-Path $Root 'tools/setup_ort_windows.ps1')
    }
}

# ------------------------------------------------------------------ コマンド

switch ($Command) {
    'run' {
        $m = if ($Mode) { $Mode } else { 'debug' }
        $id = Get-AndroidDevice
        Assert-NoDowngrade $id
        Write-Host "flutter run ($m)  r: ホットリロード / R: 再起動 / q: 終了" -ForegroundColor Cyan
        Invoke-Flutter run -d $id "--$m" @Rest
    }
    'install' {
        $m = if ($Mode) { $Mode } else { 'release' }
        $id = Get-AndroidDevice
        Assert-NoDowngrade $id
        $platform = Get-TargetPlatform $id
        # 端末の ABI だけを含む APK (全 ABI 入りより大幅に小さい)
        Invoke-Flutter build apk "--$m" --target-platform $platform @Rest
        $apk = Join-Path $Root "build/app/outputs/flutter-apk/app-$m.apk"
        $adb = Find-Adb
        & $adb -s $id install -r $apk
        if ($LASTEXITCODE -ne 0) { throw 'adb install が失敗しました。' }
        & $adb -s $id shell monkey -p $AppId -c android.intent.category.LAUNCHER 1 *> $null
        Write-Host "インストールして起動しました: $apk" -ForegroundColor Green
    }
    'logs' {
        $id = Get-AndroidDevice
        $adb = Find-Adb
        $appPid = (& $adb -s $id shell pidof -s $AppId 2>$null | Out-String).Trim()
        if (-not $appPid) { throw 'アプリが起動していません。先に run / install してください。' }
        Write-Host "logcat (pid $appPid)  Ctrl+C で終了" -ForegroundColor Cyan
        if ($Filter) {
            & $adb -s $id logcat --pid=$appPid | Select-String -SimpleMatch $Filter
        } else {
            & $adb -s $id logcat --pid=$appPid
        }
    }
    'devices' {
        Invoke-Flutter devices
    }
    'analyze' {
        Invoke-Flutter analyze @Rest
    }
    'test' {
        Invoke-Flutter test @Rest
    }
    'eval' {
        Ensure-Ort
        if (-not (Test-Path $Model)) { throw "モデルがありません: $Model" }
        if (-not (Get-ChildItem $Data -Filter *.json -ErrorAction SilentlyContinue)) {
            throw "評価データがありません: $Data (./dev.ps1 pull で取り込み)"
        }
        # 評価条件ごとに出力先を分ける (同じモデル・データでも上書きしない)
        $suffix = ''
        if ($env:PAPER_SIM_STREAM -eq '1') { $suffix += '_live' }
        if ($env:PAPER_SNAP -eq '1') { $suffix += '_snap' }
        if ($env:PAPER_PAD) { $suffix += "_pad$($env:PAPER_PAD)" }
        if ($env:PAPER_OPEN) { $suffix += "_open$($env:PAPER_OPEN)" }
        $outDir = "build/paper_eval/$([IO.Path]::GetFileNameWithoutExtension($Model))_$(Split-Path $Data -Leaf)$suffix"
        $env:PAPER_MODEL = $Model
        $env:PAPER_EVAL_DIR = $Data
        $env:PAPER_EVAL_OUT = $outDir
        try {
            Invoke-Flutter test test/paper_net_eval_test.dart @Rest
        } finally {
            Remove-Item Env:PAPER_MODEL, Env:PAPER_EVAL_DIR, Env:PAPER_EVAL_OUT -ErrorAction SilentlyContinue
        }
        Write-Host "レポート: $outDir/report.md" -ForegroundColor Green
    }
    'selftest' {
        # 端末にインストール済みのアプリで実行する (先に run / install しておく)
        $id = Get-AndroidDevice
        $adb = Find-Adb
        $src = if ($PSBoundParameters.ContainsKey('Data')) { $Data } else { 'training_data/eval_heldout' }
        if (-not (Get-ChildItem $src -Filter *.jpg -ErrorAction SilentlyContinue)) { throw "画像がありません: $src" }
        & $adb -s $id shell rm -rf $SelfTestDir
        & $adb -s $id shell mkdir -p $SelfTestDir
        Get-ChildItem $src -File | Where-Object { $_.Extension -in '.jpg', '.json' } | ForEach-Object {
            & $adb -s $id push $_.FullName "$SelfTestDir/$($_.Name)" | Out-Null
        }
        # 毎回違うトークン (アプリは処理済みトークンでは再実行しない)
        & $adb -s $id shell "echo $([guid]::NewGuid()) > $SelfTestDir/RUN"
        & $adb -s $id logcat -c
        & $adb -s $id shell am force-stop $AppId
        & $adb -s $id shell monkey -p $AppId -c android.intent.category.LAUNCHER 1 *> $null
        Write-Host "自己診断を実行中 ($src)..." -ForegroundColor Cyan
        $deadline = (Get-Date).AddMinutes(5)
        $lines = @()
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            $lines = @(& $adb -s $id logcat -d -s flutter:I | Select-String 'MMB_SELFTEST')
            if ($lines | Select-String 'MMB_SELFTEST (DONE|ERROR)') { break }
        }
        $lines | ForEach-Object { $_.Line -replace '^.*MMB_SELFTEST ', '' } | Write-Host
        $out = Join-Path $Root 'build/selftest'
        New-Item -ItemType Directory -Force $out | Out-Null
        & $adb -s $id pull "$SelfTestDir/result.json" (Join-Path $out 'result.json') | Out-Null
        # 保存処理の出力 (紙ありの画像のみ) も回収して目視確認できるようにする
        $saved = @(& $adb -s $id shell ls $SelfTestDir | Where-Object { $_ -like 'saved_*.webp' })
        foreach ($f in $saved) { & $adb -s $id pull "$SelfTestDir/$($f.Trim())" (Join-Path $out $f.Trim()) | Out-Null }
        if (-not ($lines | Select-String 'MMB_SELFTEST DONE')) { throw '自己診断が完了しませんでした (上のログを確認)' }
        Write-Host "結果: $out/result.json" -ForegroundColor Green
    }
    'pull' {
        $id = Get-AndroidDevice
        $adb = Find-Adb
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "mmb_captures_$(Get-Date -Format yyyyMMddHHmmss)"
        New-Item -ItemType Directory -Force $tmp | Out-Null
        & $adb -s $id pull $CaptureDir $tmp
        if ($LASTEXITCODE -ne 0) { throw "取り出しに失敗しました ($CaptureDir が無い可能性: アプリで保存を ON にして切り抜きを確定してください)" }
        $src = Join-Path $tmp 'training_captures'
        $dst = Join-Path $Root 'training_data/eval'
        New-Item -ItemType Directory -Force $dst | Out-Null
        $added = 0
        Get-ChildItem $src -File | ForEach-Object {
            $target = Join-Path $dst $_.Name
            if (-not (Test-Path $target)) { Copy-Item $_.FullName $target; $added++ }
        }
        Remove-Item $tmp -Recurse -Force
        $total = (Get-ChildItem $dst -Filter *.json).Count
        Write-Host "取り込み: $added ファイル追加 / 評価データ $total 件 ($dst)" -ForegroundColor Green
    }
    'train' {
        $py = Get-VenvPython
        & $py tools/prepare_quad_labels.py
        if ($LASTEXITCODE -ne 0) { throw 'prepare_quad_labels.py が失敗しました。' }
        & $py -u tools/train_paper_net_v2.py --steps $Steps --batch 16 --workers 3 @Rest
        if ($LASTEXITCODE -ne 0) { throw 'train_paper_net_v2.py が失敗しました。' }
        $trained = 'build/paper_seg_v2.onnx'
        $i = [array]::IndexOf([string[]]$Rest, '--out')
        if ($i -ge 0 -and $i + 1 -lt $Rest.Count) { $trained = $Rest[$i + 1] }
        Write-Host @"
学習済み: $trained
  評価 (学習に未使用の実写。採用前に必ず現行モデルと比べる):
    ./dev.ps1 eval -Model $trained -Data training_data/eval_heldout
    ./dev.ps1 eval -Model $trained -Data training_data/eval_heldout_rot90
  採用: Copy-Item $trained assets/models/paper_seg.onnx  → ./dev.ps1 install → ./dev.ps1 selftest
"@ -ForegroundColor Green
    }
    'doctor' {
        $ok = { param($name, $value) Write-Host ("  [OK] {0,-10} {1}" -f $name, $value) -ForegroundColor Green }
        $ng = { param($name, $value) Write-Host ("  [--] {0,-10} {1}" -f $name, $value) -ForegroundColor Yellow }
        try { & $ok 'flutter' (Find-Flutter) } catch { & $ng 'flutter' $_.Exception.Message }
        try { & $ok 'adb' (Find-Adb) } catch { & $ng 'adb' $_.Exception.Message }
        try {
            $adb = Find-Adb
            $list = & $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\S' }
            if ($list) { $list | ForEach-Object { & $ok 'device' $_ } } else { & $ng 'device' '未接続' }
        } catch { }
        $py = Join-Path $Root 'tools/.venv/Scripts/python.exe'
        if (Test-Path $py) { & $ok 'venv' $py } else { & $ng 'venv' 'tools/.venv なし (train で自動作成)' }
        $ort = Join-Path $Root 'tools/ort/onnxruntime.dll'
        if (Test-Path $ort) { & $ok 'ort' $ort } else { & $ng 'ort' 'tools/ort なし (eval で自動取得)' }
        $n = if (Test-Path 'training_data/eval') { (Get-ChildItem 'training_data/eval' -Filter *.json).Count } else { 0 }
        if ($n -gt 0) { & $ok 'eval data' "$n 件" } else { & $ng 'eval data' 'なし (pull で取り込み)' }
    }
    'clean' {
        Invoke-Flutter clean
        Invoke-Flutter pub get
    }
    default {
        $h = Get-Help $PSCommandPath
        Write-Host ($h.description | ForEach-Object Text | Out-String).Trim()
        Write-Host "`n例:"
        Write-Host ($h.examples.example.code | Out-String).TrimEnd()
    }
}
