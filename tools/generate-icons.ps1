$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$icons = Join-Path $root 'browser-extension/icons'
$assets = Join-Path $root 'store/assets'
New-Item -ItemType Directory -Path $icons, $assets -Force | Out-Null

foreach ($size in 16, 32, 48, 128) {
    $bitmap = [System.Drawing.Bitmap]::new($size, $size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $scale = $size / 128.0
    $graphics.ScaleTransform($scale, $scale)
    $shape = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $shape.AddArc(16, 16, 36, 36, 180, 90)
    $shape.AddArc(76, 16, 36, 36, 270, 90)
    $shape.AddArc(76, 76, 36, 36, 0, 90)
    $shape.AddArc(16, 76, 36, 36, 90, 90)
    $shape.CloseFigure()
    $brush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#5853b5'))
    $graphics.FillPath($brush, $shape)
    $font = [System.Drawing.Font]::new('Segoe UI', 66, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $format = [System.Drawing.StringFormat]::new()
    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    $graphics.DrawString('S', $font, [System.Drawing.Brushes]::White, [System.Drawing.RectangleF]::new(16, 12, 96, 96), $format)
    $bitmap.Save((Join-Path $icons "icon$size.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $format.Dispose()
    $font.Dispose()
    $brush.Dispose()
    $shape.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
}
Copy-Item (Join-Path $icons 'icon128.png') (Join-Path $assets 'Teams Supercopy Icon.png') -Force
