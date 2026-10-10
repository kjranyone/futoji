param(
    [string]$Source = (Join-Path $PSScriptRoot '../assets/branding/futoji-master.png')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
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
try {
    Export-Icon 'assets/branding/app-store-1024.png' 1024
    Export-Icon 'assets/branding/google-play-512.png' 512 $true
    $densities = @{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
    foreach ($density in $densities.Keys) {
        Export-Icon "android/app/src/main/res/mipmap-$density/futoji_launcher.png" $densities[$density]
    }
    $catalogPath = Join-Path $root 'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json'
    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    foreach ($entry in $catalog.images) {
        $size = [double]::Parse(($entry.size -split 'x')[0], [Globalization.CultureInfo]::InvariantCulture)
        $scale = [int]($entry.scale -replace 'x', '')
        $entry.filename = "Futoji-$($entry.size)@$($entry.scale).png"
        Export-Icon "ios/Runner/Assets.xcassets/AppIcon.appiconset/$($entry.filename)" ([int]($size * $scale))
    }
    [IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 6) + "`n", [Text.UTF8Encoding]::new($false))
} finally { $sourceImage.Dispose() }
