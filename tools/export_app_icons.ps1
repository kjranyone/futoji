param(
    [string]$Source = (Join-Path $PSScriptRoot '../assets/branding/futoji-master.png')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
# 元画像 (藍の地にアイボリーの記号) から記号だけを抜き出すアルファを作る。PowerShell のループでは遅いので C# で書く
Add-Type -TypeDefinition @'
public static class FutojiIconMask {
    // bgra: 32bpp ARGB の画素列。地と記号の色を推定し、記号の不透明度だけを持つ画素列 (色は outB/G/R) を返す
    public static byte[] Extract(byte[] bgra, int width, int height, byte outB, byte outG, byte outR, out double maxRadius, out string backgroundHex) {
        int border = width / 50;
        double[] bg = new double[3], fg = new double[3];
        long bgCount = 0, fgCount = 0;
        for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
            int i = (y * width + x) * 4;
            bool edge = x < border || y < border || x >= width - border || y >= height - border;
            bool bright = bgra[i] > 230 && bgra[i + 1] > 230 && bgra[i + 2] > 230;
            if (edge) { bgCount++; for (int c = 0; c < 3; c++) bg[c] += bgra[i + c]; }
            else if (bright) { fgCount++; for (int c = 0; c < 3; c++) fg[c] += bgra[i + c]; }
        }
        for (int c = 0; c < 3; c++) { bg[c] /= bgCount; fg[c] /= fgCount; }
        backgroundHex = string.Format("#{0:X2}{1:X2}{2:X2}", (int)System.Math.Round(bg[2]), (int)System.Math.Round(bg[1]), (int)System.Math.Round(bg[0]));
        double[] axis = { fg[0] - bg[0], fg[1] - bg[1], fg[2] - bg[2] };
        double axisLength2 = axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2];
        double cx = (width - 1) / 2.0, cy = (height - 1) / 2.0, maxR2 = 0;
        byte[] mask = new byte[bgra.Length];
        for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
            int i = (y * width + x) * 4;
            double t = 0;
            for (int c = 0; c < 3; c++) t += (bgra[i + c] - bg[c]) * axis[c];
            // 地のムラと記号の色ムラを吸収するため、両端 10% は完全に透明・不透明に寄せる
            double a = System.Math.Min(1, System.Math.Max(0, (t / axisLength2 - 0.1) / 0.8));
            mask[i] = outB; mask[i + 1] = outG; mask[i + 2] = outR;
            mask[i + 3] = (byte)System.Math.Round(a * 255);
            if (a >= 0.5) maxR2 = System.Math.Max(maxR2, (x - cx) * (x - cx) + (y - cy) * (y - cy));
        }
        maxRadius = System.Math.Sqrt(maxR2);
        return mask;
    }
}
'@
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceImage = [Drawing.Image]::FromFile([IO.Path]::GetFullPath($Source))
function Export-Icon([string]$RelativePath, [int]$Size, [bool]$Alpha = $false) {
    $path = Join-Path $root $RelativePath
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    $format = [Drawing.Imaging.PixelFormat]::Format24bppRgb
    if ($Alpha) { $format = [Drawing.Imaging.PixelFormat]::Format32bppArgb }
    $bitmap = [Drawing.Bitmap]::new($Size, $Size, $format)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([Drawing.ColorTranslator]::FromHtml('#3B4A9F'))
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($sourceImage, [Drawing.Rectangle]::new(0, 0, $Size, $Size))
        $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
function New-SymbolMask([Drawing.Color]$Color) {
    $width = $sourceImage.Width; $height = $sourceImage.Height
    $rect = [Drawing.Rectangle]::new(0, 0, $width, $height)
    $format = [Drawing.Imaging.PixelFormat]::Format32bppArgb
    $source = [Drawing.Bitmap]::new($sourceImage)
    try {
        $data = $source.LockBits($rect, [Drawing.Imaging.ImageLockMode]::ReadOnly, $format)
        $bytes = [byte[]]::new($data.Stride * $height)
        [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        $source.UnlockBits($data)
    } finally { $source.Dispose() }
    $maxRadius = 0.0; $backgroundHex = ''
    $maskBytes = [FutojiIconMask]::Extract($bytes, $width, $height, $Color.B, $Color.G, $Color.R, [ref]$maxRadius, [ref]$backgroundHex)
    $mask = [Drawing.Bitmap]::new($width, $height, $format)
    $data = $mask.LockBits($rect, [Drawing.Imaging.ImageLockMode]::WriteOnly, $format)
    [Runtime.InteropServices.Marshal]::Copy($maskBytes, 0, $data.Scan0, $maskBytes.Length)
    $mask.UnlockBits($data)
    [pscustomobject]@{ Bitmap = $mask; MaxRadius = $maxRadius; BackgroundHex = $backgroundHex }
}
# アダプティブアイコンの 1 層 (108dp 四方、透明地)。記号の外接円の半径を $SymbolRadiusDp に合わせる
function Export-AdaptiveLayer([string]$RelativePath, [int]$Size, $Mask, [double]$SymbolRadiusDp) {
    $path = Join-Path $root $RelativePath
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    $bitmap = [Drawing.Bitmap]::new($Size, $Size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $drawn = $Mask.Bitmap.Width * ($SymbolRadiusDp / 108 * $Size) / $Mask.MaxRadius
        $offset = ($Size - $drawn) / 2
        $graphics.DrawImage($Mask.Bitmap, [Drawing.RectangleF]::new($offset, $offset, $drawn, $drawn))
        $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
$foreground = $null; $monochrome = $null
try {
    Export-Icon 'assets/branding/app-store-1024.png' 1024
    Export-Icon 'assets/branding/google-play-512.png' 512 $true
    # API 25 以前のランチャー用 (正方形の全面画像)
    $densities = @{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
    foreach ($density in $densities.Keys) {
        Export-Icon "android/app/src/main/res/mipmap-$density/futoji_launcher.png" $densities[$density]
    }
    # API 26 以降のアダプティブアイコン。マスクで切られないよう記号は直径 66dp の安全領域 (半径 33dp) に収める。
    # monochrome はテーマアイコン (Android 13 以降) 用で、アルファだけが使われる
    $foreground = New-SymbolMask ([Drawing.Color]::FromArgb(0xFE, 0xFB, 0xF3))
    $monochrome = New-SymbolMask ([Drawing.Color]::White)
    foreach ($density in $densities.Keys) {
        $size = $densities[$density] * 108 / 48
        Export-AdaptiveLayer "android/app/src/main/res/mipmap-$density/futoji_launcher_foreground.png" $size $foreground 31
        Export-AdaptiveLayer "android/app/src/main/res/mipmap-$density/futoji_launcher_monochrome.png" $size $monochrome 31
    }
    # 背景はストア用アイコンと同じ見た目になるよう元画像の地の色をそのまま使う
    $colorPath = Join-Path $root 'android/app/src/main/res/values/futoji_launcher_background.xml'
    $colorXml = "<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<resources>`n    <color name=`"futoji_launcher_background`">$($foreground.BackgroundHex)</color>`n</resources>`n"
    [IO.File]::WriteAllText($colorPath, $colorXml, [Text.UTF8Encoding]::new($false))
    $catalogPath = Join-Path $root 'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json'
    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    foreach ($entry in $catalog.images) {
        $size = [double]::Parse(($entry.size -split 'x')[0], [Globalization.CultureInfo]::InvariantCulture)
        $scale = [int]($entry.scale -replace 'x', '')
        $entry.filename = "Futoji-$($entry.size)@$($entry.scale).png"
        Export-Icon "ios/Runner/Assets.xcassets/AppIcon.appiconset/$($entry.filename)" ([int]($size * $scale))
    }
    [IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 6) + "`n", [Text.UTF8Encoding]::new($false))
} finally {
    if ($foreground) { $foreground.Bitmap.Dispose() }
    if ($monochrome) { $monochrome.Bitmap.Dispose() }
    $sourceImage.Dispose()
}
