# Draws the WhatWorks launcher icons (teal disc + white task_alt-style tick)
# Outputs:
#   assets/icon/app_icon.png            (legacy: teal disc, transparent corners)
#   assets/icon/app_icon_foreground.png (adaptive foreground: white glyph only)
Add-Type -AssemblyName System.Drawing

$size = 1024
$teal = [System.Drawing.Color]::FromArgb(255, 0x07, 0x5E, 0x54)
$white = [System.Drawing.Color]::White

function New-Canvas {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    return @($bmp, $g)
}

function Draw-Glyph($g, $cx, $cy, $ringR, $penW) {
    $pen = New-Object System.Drawing.Pen($white, $penW)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    # Ring
    $g.DrawEllipse($pen, $cx - $ringR, $cy - $ringR, 2 * $ringR, 2 * $ringR)
    # Check mark (tail extends past the ring at top-right, like Icons.task_alt)
    $s = $ringR / 300.0
    $p1 = New-Object System.Drawing.PointF(($cx - 150 * $s), ($cy + 10 * $s))
    $p2 = New-Object System.Drawing.PointF(($cx - 35 * $s), ($cy + 125 * $s))
    $p3 = New-Object System.Drawing.PointF(($cx + 290 * $s), ($cy - 200 * $s))
    $g.DrawLines($pen, [System.Drawing.PointF[]]@($p1, $p2, $p3))
    $pen.Dispose()
}

$outDir = "g:\flutter projects\whatworks\assets\icon"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# 1) Legacy icon: teal disc + glyph
$c = New-Canvas; $bmp = $c[0]; $g = $c[1]
$brush = New-Object System.Drawing.SolidBrush($teal)
$margin = 12
$g.FillEllipse($brush, $margin, $margin, $size - 2 * $margin, $size - 2 * $margin)
$brush.Dispose()
Draw-Glyph $g 512 512 235 66
$g.Dispose()
$bmp.Save("$outDir\app_icon.png", [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

# 2) Adaptive foreground: glyph only, sized for the 66% safe zone
$c = New-Canvas; $bmp = $c[0]; $g = $c[1]
Draw-Glyph $g 512 512 210 60
$g.Dispose()
$bmp.Save("$outDir\app_icon_foreground.png", [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

Write-Output "Icons written to $outDir"
