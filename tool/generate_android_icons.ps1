$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$projectRoot = Split-Path $PSScriptRoot -Parent
$source = [System.Drawing.Bitmap]::new((Join-Path $projectRoot 'assets/home/shadownetwork_logo.png'))
# Isolate the network emblem above the wordmark in the original 1024px artwork.
$emblem = $source.Clone([System.Drawing.Rectangle]::new(270, 250, 490, 410), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$silhouette = [System.Drawing.Bitmap]::new($emblem.Width, $emblem.Height)
for ($y = 0; $y -lt $emblem.Height; $y++) {
    for ($x = 0; $x -lt $emblem.Width; $x++) {
        if ($emblem.GetPixel($x, $y).A -gt 0) {
            $silhouette.SetPixel($x, $y, [System.Drawing.Color]::White)
        }
    }
}

function Write-Icon([System.Drawing.Bitmap]$Artwork, [int]$Size, [double]$Fraction, [bool]$Opaque, [string]$RelativePath) {
    $target = Join-Path $projectRoot $RelativePath
    [System.IO.Directory]::CreateDirectory((Split-Path $target -Parent)) | Out-Null
    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        if ($Opaque) { $graphics.Clear([System.Drawing.Color]::White) }
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $width = [float]($Size * $Fraction)
        $height = [float]($width * $Artwork.Height / $Artwork.Width)
        $graphics.DrawImage($Artwork, [System.Drawing.RectangleF]::new(($Size - $width) / 2, ($Size - $height) / 2, $width, $height))
        if ($Artwork -eq $silhouette) {
            for ($maskY = 0; $maskY -lt $Size; $maskY++) {
                for ($maskX = 0; $maskX -lt $Size; $maskX++) {
                    $alpha = $bitmap.GetPixel($maskX, $maskY).A
                    $bitmap.SetPixel($maskX, $maskY, [System.Drawing.Color]::FromArgb($alpha, 255, 255, 255))
                }
            }
        }
        $bitmap.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

try {
    $densities = @{mdpi = 1; hdpi = 1.5; xhdpi = 2; xxhdpi = 3; xxxhdpi = 4}
    foreach ($entry in $densities.GetEnumerator()) {
        $density = $entry.Key
        $scale = $entry.Value
        Write-Icon $emblem ([int](48 * $scale)) 0.68 $true "android/app/src/main/res/mipmap-$density/ic_launcher.png"
        # Keep the triangular tips inside Android's 66dp adaptive-icon safe circle.
        Write-Icon $emblem ([int](108 * $scale)) 0.48 $false "android/app/src/main/res/drawable-$density/ic_launcher_foreground.png"
        Write-Icon $silhouette ([int](108 * $scale)) 0.48 $false "android/app/src/main/res/drawable-$density/ic_launcher_monochrome.png"
        Write-Icon $silhouette ([int](24 * $scale)) 0.84 $false "android/app/src/main/res/drawable-$density/ic_stat_shadow_network.png"
        Write-Icon $emblem ([int](64 * $scale)) 0.76 $true "android/app/src/main/res/drawable-$density/ic_notification_logo.png"
    }
} finally {
    $source.Dispose()
    $emblem.Dispose()
    $silhouette.Dispose()
}
