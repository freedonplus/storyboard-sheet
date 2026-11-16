param(
    [Parameter(Mandatory = $true)][string]$BoardPath,
    [Parameter(Mandatory = $true)][string]$SpecPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [string]$PreviewPath = "",
    [int]$PreviewLongEdge = 2560
)

# storyboard-sheet 单次整板叠字
# 用途：一张图就画完整个故事板（cols×rows 等分）时，把镜头号、时长、镜头名叠到每格底部。
# 与 build-board.ps1 的区别：build-board 拼 N 张单帧；本脚本不改画面，只在已有整板上叠字。

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $BoardPath)) { throw "board not found: $BoardPath" }
if (-not (Test-Path -LiteralPath $SpecPath)) { throw "spec not found: $SpecPath" }

$spec = Get-Content -LiteralPath $SpecPath -Encoding utf8 -Raw | ConvertFrom-Json
$shots = @($spec.shots)
if ($shots.Count -eq 0) { throw "shots is empty" }

$cols = if ($spec.cols) { [int]$spec.cols } else { 3 }
$rows = if ($spec.rows) { [int]$spec.rows } else { 3 }
if ($shots.Count -gt ($cols * $rows)) { throw "shots ($($shots.Count)) exceed grid capacity ($($cols * $rows))" }

$src = [System.Drawing.Image]::FromFile($BoardPath)
$bw = $src.Width
$bh = $src.Height
$cw = [double]$bw / $cols
$ch = [double]$bh / $rows

$bmp = New-Object System.Drawing.Bitmap($bw, $bh)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
$g.DrawImage($src, 0, 0, $bw, $bh)
$src.Dispose()

$scale = $ch / 720.0
$capH = [double]$ch * 0.108
$capTopOffset = [double]$ch - $capH

$fontId = New-Object System.Drawing.Font("Microsoft YaHei", [single]([math]::Max(10, 27 * $scale)), [System.Drawing.FontStyle]::Bold)
$fontTime = New-Object System.Drawing.Font("Microsoft YaHei", [single]([math]::Max(7, 18 * $scale)), [System.Drawing.FontStyle]::Regular)
$fontName = New-Object System.Drawing.Font("Microsoft YaHei", [single]([math]::Max(8, 22 * $scale)), [System.Drawing.FontStyle]::Regular)

$white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 238, 242, 247))
$dim = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 150, 168, 186))
$accent = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 96, 168, 255))
$capBg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(170, 6, 8, 11))
$linePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 30, 36, 44), [single][math]::Max(1, 2 * $scale))

for ($i = 0; $i -lt $shots.Count; $i++) {
    $col = $i % $cols
    $row = [math]::Floor($i / $cols)
    $x = [double]($col * $cw)
    $y = [double]($row * $ch) + $capTopOffset

    $g.FillRectangle($capBg, [single]$x, [single]$y, [single]$cw, [single]$capH)
    $g.DrawLine($linePen, [single]$x, [single]$y, [single]($x + $cw), [single]$y)

    $pad = [double][math]::Max(6, 26 * $scale)
    $idText = [string]$shots[$i].id
    $timeText = [string]$shots[$i].time
    $nameText = [string]$shots[$i].name

    $idSize = $g.MeasureString($idText, $fontId)
    $timeSize = $g.MeasureString($timeText, $fontTime)
    $leftBlock = $pad + $idSize.Width + 6 + $timeSize.Width

    $nameFont = $fontName
    $nameSize = $g.MeasureString($nameText, $nameFont)
    $available = $cw - $pad * 2 - $leftBlock - 12
    $shrink = 1.0
    while ($nameSize.Width -gt $available -and $shrink -gt 0.55) {
        $shrink -= 0.05
        $nameFont = New-Object System.Drawing.Font("Microsoft YaHei", [single]([math]::Max(7, 22 * $scale * $shrink)), [System.Drawing.FontStyle]::Regular)
        $nameSize = $g.MeasureString($nameText, $nameFont)
    }

    $capPadY = [double][math]::Max(2, 8 * $scale)
    $g.DrawString($idText, $fontId, $accent, [single]($x + $pad), [single]($y + $capPadY))
    $g.DrawString($timeText, $fontTime, $dim, [single]($x + $pad + $idSize.Width + 6), [single]($y + $capPadY + [math]::Max(1, 6 * $scale)))
    if ($available -gt 20) {
        $g.DrawString($nameText, $nameFont, $white, [single]($x + $cw - $pad - $nameSize.Width), [single]($y + $capPadY))
    }
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)

if ($PreviewPath) {
    $longEdge = [math]::Max($bw, $bh)
    $ratio = [double]$PreviewLongEdge / $longEdge
    $vx = [int][math]::Round($bw * $ratio)
    $vy = [int][math]::Round($bh * $ratio)
    $pre = New-Object System.Drawing.Bitmap($vx, $vy)
    $pg = [System.Drawing.Graphics]::FromImage($pre)
    $pg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $pg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $pg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $pg.DrawImage($bmp, 0, 0, $vx, $vy)
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
$bmp.Dispose()

Write-Output ("annotated: " + $OutputPath + "  " + $bw + "x" + $bh + "  cells=" + $shots.Count + " (" + $cols + "x" + $rows + ")")
if ($PreviewPath) { Write-Output ("preview: " + $PreviewPath) }
