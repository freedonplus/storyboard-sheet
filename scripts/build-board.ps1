param(
    [Parameter(Mandatory = $true)][string]$SpecPath,
    [Parameter(Mandatory = $true)][string]$PanelsDir,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [string]$PreviewPath = "",
    [int]$PreviewLongEdge = 2560
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $SpecPath)) { throw "spec not found: $SpecPath" }
if (-not (Test-Path -LiteralPath $PanelsDir)) { throw "panels dir not found: $PanelsDir" }

$spec = Get-Content -LiteralPath $SpecPath -Encoding utf8 -Raw | ConvertFrom-Json

$cols = if ($spec.cols) { [int]$spec.cols } else { 3 }
$rows = if ($spec.rows) { [int]$spec.rows } else { 3 }
$pw = if ($spec.panel_width) { [int]$spec.panel_width } else { 1280 }
$ph = if ($spec.panel_height) { [int]$spec.panel_height } else { 720 }
$capH = if ($spec.caption_height) { [int]$spec.caption_height } else { [int]([math]::Round($ph * 0.108)) }
$titleCell = if ($null -ne $spec.title_cell) { [bool]$spec.title_cell } else { $true }

$shots = @($spec.shots)
if ($shots.Count -eq 0) { throw "shots is empty" }
if ($shots.Count -gt ($cols * $rows)) { throw "shots ($($shots.Count)) exceed grid capacity ($($cols * $rows))" }

$missing = @()
foreach ($s in $shots) {
    $p = Join-Path $PanelsDir $s.file
    if (-not (Test-Path -LiteralPath $p)) { $missing += $s.file }
}
if ($missing.Count -gt 0) { throw ("panel files missing: " + ($missing -join ", ")) }

$cw = $pw * $cols
$ch = $ph * $rows

$canvas = New-Object System.Drawing.Bitmap($cw, $ch)
$g = [System.Drawing.Graphics]::FromImage($canvas)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
$g.Clear([System.Drawing.Color]::FromArgb(10, 12, 15))

$scale = $ph / 720.0
$fontId = New-Object System.Drawing.Font("Microsoft YaHei", [single](27 * $scale), [System.Drawing.FontStyle]::Bold)
$fontTime = New-Object System.Drawing.Font("Microsoft YaHei", [single](18 * $scale), [System.Drawing.FontStyle]::Regular)
$fontName = New-Object System.Drawing.Font("Microsoft YaHei", [single](22 * $scale), [System.Drawing.FontStyle]::Regular)
$fontTitle = New-Object System.Drawing.Font("Microsoft YaHei", [single](54 * $scale), [System.Drawing.FontStyle]::Bold)
$fontSub = New-Object System.Drawing.Font("Microsoft YaHei", [single](24 * $scale), [System.Drawing.FontStyle]::Regular)
$fontSmall = New-Object System.Drawing.Font("Microsoft YaHei", [single](18 * $scale), [System.Drawing.FontStyle]::Regular)

$white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 238, 242, 247))
$dim = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 150, 168, 186))
$accent = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 96, 168, 255))
$capBg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(170, 6, 8, 11))
$linePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 30, 36, 44), 2)
$cardBg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 14, 18, 23))

function Draw-CoverPanel {
    param($graphics, $img, $destRect)

    $iw = $img.Width
    $ih = $img.Height
    $dstAspect = $destRect.Width / [double]$destRect.Height
    $srcAspect = $iw / [double]$ih

    if ($srcAspect -gt $dstAspect) {
        $sw = [single]($ih * $dstAspect)
        $sh = [single]$ih
        $sx = [single](($iw - $sw) / 2)
        $sy = [single]0
    }
    else {
        $sw = [single]$iw
        $sh = [single]($iw / $dstAspect)
        $sx = [single]0
        $sy = [single](($ih - $sh) / 2)
    }

    $graphics.DrawImage($img, $destRect, $sx, $sy, $sw, $sh, [System.Drawing.GraphicsUnit]::Pixel)
}

for ($i = 0; $i -lt $shots.Count; $i++) {
    $col = $i % $cols
    $row = [math]::Floor($i / $cols)
    $x = $col * $pw
    $y = $row * $ph

    $imgPath = Join-Path $PanelsDir $shots[$i].file
    $img = [System.Drawing.Image]::FromFile($imgPath)
    $dest = New-Object System.Drawing.Rectangle($x, $y, $pw, $ph)
    Draw-CoverPanel -graphics $g -img $img -destRect $dest
    $img.Dispose()

    $capY = $y + $ph - $capH
    $g.FillRectangle($capBg, $x, $capY, $pw, $capH)
    $g.DrawLine($linePen, $x, $capY, $x + $pw, $capY)

    $pad = [int][math]::Round(26 * $scale)
    $idText = [string]$shots[$i].id
    $timeText = [string]$shots[$i].time
    $nameText = [string]$shots[$i].name

    $idFont = $fontId
    $timeFont = $fontTime
    $nameFont = $fontName

    $idSize = $g.MeasureString($idText, $idFont)
    $leftBlock = $pad + $idSize.Width + 6 + $g.MeasureString($timeText, $timeFont).Width
    $nameSize = $g.MeasureString($nameText, $nameFont)
    $available = $pw - $pad * 2 - $leftBlock - 24

    $shrink = 1.0
    while ($nameSize.Width -gt $available -and $shrink -gt 0.55) {
        $shrink -= 0.05
        $nameFont = New-Object System.Drawing.Font("Microsoft YaHei", [single]([math]::Max(12, 22 * $scale * $shrink)), [System.Drawing.FontStyle]::Regular)
        $nameSize = $g.MeasureString($nameText, $nameFont)
    }
    if ($leftBlock + $nameSize.Width + $pad -gt $pw) {
        $timeFont = New-Object System.Drawing.Font("Microsoft YaHei", [single]([math]::Max(10, 18 * $scale * 0.7)), [System.Drawing.FontStyle]::Regular)
    }

    $g.DrawString($idText, $idFont, $accent, [single]($x + $pad), [single]($capY + [math]::Round(8 * $scale)))
    $idSize2 = $g.MeasureString($idText, $idFont)
    $g.DrawString($timeText, $timeFont, $dim, [single]($x + $pad + $idSize2.Width + 6), [single]($capY + [math]::Round(14 * $scale)))
    $nameSize2 = $g.MeasureString($nameText, $nameFont)
    $g.DrawString($nameText, $nameFont, $white, [single]($x + $pw - $pad - $nameSize2.Width), [single]($capY + [math]::Round(6 * $scale)))

    $g.DrawRectangle($linePen, $x, $y, $pw - 1, $ph - 1)
}

$titleIndex = -1
if ($titleCell -and $shots.Count -eq ($cols * $rows - 1)) { $titleIndex = $shots.Count }

if ($titleIndex -ge 0) {
    $col = $titleIndex % $cols
    $row = [math]::Floor($titleIndex / $cols)
    $tx = $col * $pw
    $ty = $row * $ph

    $g.FillRectangle($cardBg, $tx, $ty, $pw, $ph)
    $g.DrawRectangle($linePen, $tx, $ty, $pw, $ph)

    $subtitle = if ($spec.subtitle) { [string]$spec.subtitle } else { "分镜故事板  STORYBOARD" }
    $beats = @($spec.beats)

    $g.DrawString([string]$spec.title, $fontTitle, $white, [single]($tx + [math]::Round(86 * $scale)), [single]($ty + [math]::Round(190 * $scale)))
    $g.DrawString($subtitle, $fontSub, $accent, [single]($tx + [math]::Round(90 * $scale)), [single]($ty + [math]::Round(300 * $scale)))

    $metaY = [math]::Round(360 * $scale)
    foreach ($m in @($spec.meta)) {
        $g.DrawString([string]$m, $fontSmall, $dim, [single]($tx + [math]::Round(90 * $scale)), [single]($ty + $metaY))
        $metaY += [math]::Round(42 * $scale)
    }

    $beatY = $metaY + [math]::Round(10 * $scale)
    foreach ($b in $beats) {
        $g.DrawString([string]$b, $fontSmall, $dim, [single]($tx + [math]::Round(90 * $scale)), [single]($ty + $beatY))
        $beatY += [math]::Round(40 * $scale)
    }
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$canvas.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)

if ($PreviewPath) {
    $longEdge = [math]::Max($cw, $ch)
    $ratio = [double]$PreviewLongEdge / $longEdge
    $vx = [int][math]::Round($cw * $ratio)
    $vy = [int][math]::Round($ch * $ratio)
    $pre = New-Object System.Drawing.Bitmap($vx, $vy)
    $pg = [System.Drawing.Graphics]::FromImage($pre)
    $pg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $pg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $pg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $pg.DrawImage($canvas, 0, 0, $vx, $vy)
    $pg.Dispose()

    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
    $encParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
    $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [int64]88)
    $previewDir = Split-Path -Parent $PreviewPath
    if ($previewDir -and -not (Test-Path -LiteralPath $previewDir)) { New-Item -ItemType Directory -Path $previewDir -Force | Out-Null }
    $pre.Save($PreviewPath, $codec, $encParams)
    $pre.Dispose()
}

$g.Dispose()
$canvas.Dispose()

Write-Output ("board: " + $OutputPath + "  " + $cw + "x" + $ch)
if ($PreviewPath) { Write-Output ("preview: " + $PreviewPath) }
