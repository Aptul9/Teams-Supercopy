$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$source = Join-Path $root 'assets/icon.png'
$icons = Join-Path $root 'browser-extension/icons'
$assets = Join-Path $root 'store/assets'
New-Item -ItemType Directory -Path $icons, $assets -Force | Out-Null

# Chrome Web Store asks for 96 px artwork inside the 128 px icon; toolbar sizes use the full canvas.
$artwork = @{ 16 = 16; 32 = 32; 48 = 48; 128 = 96 }

$image = [System.Drawing.Image]::FromFile($source)
try {
    foreach ($size in 16, 32, 48, 128) {
        $art = $artwork[$size]
        $offset = ($size - $art) / 2
        $bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $attributes = [System.Drawing.Imaging.ImageAttributes]::new()
        try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
            $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $attributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
            $target = [System.Drawing.Rectangle]::new($offset, $offset, $art, $art)
            $graphics.DrawImage($image, $target, 0, 0, $image.Width, $image.Height, [System.Drawing.GraphicsUnit]::Pixel, $attributes)
            $bitmap.Save((Join-Path $icons "icon$size.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $attributes.Dispose()
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }
}
finally {
    $image.Dispose()
}
Copy-Item (Join-Path $icons 'icon128.png') (Join-Path $assets 'Teams Supercopy Icon.png') -Force
