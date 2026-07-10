Add-Type -AssemblyName System.Drawing

$root = "c:\Users\Flipped\Downloads\Multiplayer Elo Game"
$spriteDir = "$root\game\assets\sprites"
$bgDir = "$root\game\assets\bg"
$tileDir = "$root\game\assets\tiles"
New-Item -ItemType Directory -Force -Path $spriteDir, $bgDir, $tileDir | Out-Null

function New-Canvas([int]$w, [int]$h) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g.Clear([System.Drawing.Color]::Transparent)
    return @{ bmp = $bmp; g = $g }
}

function Col([int]$r, [int]$g, [int]$b, [int]$a = 255) {
    return [System.Drawing.Color]::FromArgb($a, $r, $g, $b)
}

# ---------------------------------------------------------------------------
# Character sprite sheet: 4 frames of 20x28, laid out horizontally (80x28).
# idle | run1 | run2 | air
# ---------------------------------------------------------------------------
$frameW = 20
$frameH = 28
$sheet = New-Object System.Drawing.Bitmap ($frameW * 4), $frameH, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$sg = [System.Drawing.Graphics]::FromImage($sheet)
$sg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
$sg.Clear([System.Drawing.Color]::Transparent)

$outline = Col 25 22 30
$body = Col 245 240 230
$eye = Col 30 28 35
$shade = Col 205 198 188

function Draw-Body([System.Drawing.Graphics]$g, [int]$ox) {
    # outline (slightly larger, drawn first) then body fill on top -- cheap
    # way to get a clean 1px pixel-art outline without antialiasing.
    $outlineBrush = New-Object System.Drawing.SolidBrush $outline
    $bodyBrush = New-Object System.Drawing.SolidBrush $body
    $shadeBrush = New-Object System.Drawing.SolidBrush $shade

    $g.FillEllipse($outlineBrush, $ox + 2, 1, 16, 10)
    $g.FillRectangle($outlineBrush, $ox + 2, 6, 16, 13)
    $g.FillEllipse($outlineBrush, $ox + 2, 15, 16, 9)

    $g.FillEllipse($bodyBrush, $ox + 3, 2, 14, 8)
    $g.FillRectangle($bodyBrush, $ox + 3, 6, 14, 11)
    $g.FillEllipse($bodyBrush, $ox + 3, 14, 14, 8)

    # subtle shade on the right side for a bit of volume
    $g.FillRectangle($shadeBrush, $ox + 13, 7, 3, 12)
}

function Draw-Eyes([System.Drawing.Graphics]$g, [int]$ox, [int]$eyeY) {
    $eyeBrush = New-Object System.Drawing.SolidBrush $eye
    $g.FillRectangle($eyeBrush, $ox + 6, $eyeY, 2, 3)
    $g.FillRectangle($eyeBrush, $ox + 11, $eyeY, 2, 3)
}

function Draw-Legs([System.Drawing.Graphics]$g, [int]$ox, [int]$lx, [int]$ly, [int]$rx, [int]$ry) {
    $outlineBrush = New-Object System.Drawing.SolidBrush $outline
    $bodyBrush = New-Object System.Drawing.SolidBrush $body
    $g.FillRectangle($outlineBrush, $ox + $lx - 1, $ly - 1, 5, 6)
    $g.FillRectangle($outlineBrush, $ox + $rx - 1, $ry - 1, 5, 6)
    $g.FillRectangle($bodyBrush, $ox + $lx, $ly, 3, 5)
    $g.FillRectangle($bodyBrush, $ox + $rx, $ry, 3, 5)
}

# Frame 0: idle -- legs together, eyes centered
Draw-Body $sg 0
Draw-Legs $sg 0 4 20 12 20
Draw-Eyes $sg 0 8

# Frame 1: run1 -- left leg forward/down, right leg back/up
Draw-Body $sg $frameW
Draw-Legs $sg $frameW 2 21 13 18
Draw-Eyes $sg $frameW 8

# Frame 2: run2 -- mirror of run1
Draw-Body $sg (2 * $frameW)
Draw-Legs $sg (2 * $frameW) 5 18 16 21
Draw-Eyes $sg (2 * $frameW) 8

# Frame 3: air -- legs tucked up together
Draw-Body $sg (3 * $frameW)
Draw-Legs $sg (3 * $frameW) 4 18 12 18
Draw-Eyes $sg (3 * $frameW) 8

$sheet.Save("$spriteDir\player_sheet.png", [System.Drawing.Imaging.ImageFormat]::Png)
$sg.Dispose()
$sheet.Dispose()

Write-Output "player_sheet.png written"

# ---------------------------------------------------------------------------
# Sky: vertical gradient, trivially horizontally tileable (no x variation).
# ---------------------------------------------------------------------------
$skyW = 64
$skyH = 648
$sky = New-Object System.Drawing.Bitmap $skyW, $skyH
$topColor = Col 40 45 90
$botColor = Col 190 170 200
for ($y = 0; $y -lt $skyH; $y++) {
    $t = $y / [double]($skyH - 1)
    $r = [int]($topColor.R + ($botColor.R - $topColor.R) * $t)
    $gr = [int]($topColor.G + ($botColor.G - $topColor.G) * $t)
    $b = [int]($topColor.B + ($botColor.B - $topColor.B) * $t)
    $rowColor = Col $r $gr $b
    for ($x = 0; $x -lt $skyW; $x++) {
        $sky.SetPixel($x, $y, $rowColor)
    }
}
$sky.Save("$bgDir\sky.png", [System.Drawing.Imaging.ImageFormat]::Png)
$sky.Dispose()
Write-Output "sky.png written"

# ---------------------------------------------------------------------------
# Mountains: horizontally tileable silhouette strip via a periodic zigzag.
# ---------------------------------------------------------------------------
$mW = 512
$mH = 260
$mtn = New-Object System.Drawing.Bitmap $mW, $mH, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$mg = [System.Drawing.Graphics]::FromImage($mtn)
$mg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
$mg.Clear([System.Drawing.Color]::Transparent)
$mtnColor = Col 95 85 120
$mtnBrush = New-Object System.Drawing.SolidBrush $mtnColor
$period = 128
$peakHeight = 150
$baseY = $mH
for ($x = 0; $x -lt $mW; $x++) {
    $phase = ($x % $period) / [double]$period
    # triangle wave 0..1..0 across each period
    $tri = 1.0 - [Math]::Abs(($phase * 2.0) - 1.0)
    $peakY = $baseY - 40 - [int]($tri * $peakHeight)
    $mg.FillRectangle($mtnBrush, $x, $peakY, 1, $mH - $peakY)
}
$mtn.Save("$bgDir\mountains.png", [System.Drawing.Imaging.ImageFormat]::Png)
$mg.Dispose()
$mtn.Dispose()
Write-Output "mountains.png written"

# ---------------------------------------------------------------------------
# Clouds: sparse ellipses on transparent bg, tileable strip.
# ---------------------------------------------------------------------------
$cW = 512
$cH = 200
$cloud = New-Object System.Drawing.Bitmap $cW, $cH, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$cg = [System.Drawing.Graphics]::FromImage($cloud)
$cg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
$cg.Clear([System.Drawing.Color]::Transparent)
$cloudColor = Col 255 255 255 160
$cloudBrush = New-Object System.Drawing.SolidBrush $cloudColor
function Draw-Cloud([System.Drawing.Graphics]$g, [int]$cx, [int]$cy) {
    $g.FillEllipse($cloudBrush, $cx, $cy, 40, 18)
    $g.FillEllipse($cloudBrush, $cx + 20, $cy - 8, 30, 18)
    $g.FillEllipse($cloudBrush, $cx + 40, $cy, 36, 16)
}
Draw-Cloud $cg 20 40
Draw-Cloud $cg 280 90
Draw-Cloud $cg 420 30
$cloud.Save("$bgDir\clouds.png", [System.Drawing.Imaging.ImageFormat]::Png)
$cg.Dispose()
$cloud.Dispose()
Write-Output "clouds.png written"

# ---------------------------------------------------------------------------
# Ground tile: 32x32, tileable both directions -- grass top + dirt body.
# ---------------------------------------------------------------------------
$tSize = 32
$tile = New-Object System.Drawing.Bitmap $tSize, $tSize, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$tg = [System.Drawing.Graphics]::FromImage($tile)
$tg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
$tg.Clear([System.Drawing.Color]::Transparent)
$grassColor = Col 108 168 92
$grassDark = Col 90 148 76
$dirtColor = Col 106 74 58
$dirtDark = Col 88 60 46
$tg.FillRectangle((New-Object System.Drawing.SolidBrush $grassColor), 0, 0, $tSize, 8)
$tg.FillRectangle((New-Object System.Drawing.SolidBrush $grassDark), 0, 6, $tSize, 2)
$tg.FillRectangle((New-Object System.Drawing.SolidBrush $dirtColor), 0, 8, $tSize, $tSize - 8)
$dirtDarkBrush = New-Object System.Drawing.SolidBrush $dirtDark
$speckle = @(@(3,9), @(11,15), @(19,11), @(25,20), @(7,24), @(15,27), @(22,26), @(28,13))
foreach ($pt in $speckle) {
    $tg.FillRectangle($dirtDarkBrush, $pt[0], $pt[1], 2, 2)
}
$tile.Save("$tileDir\ground.png", [System.Drawing.Imaging.ImageFormat]::Png)
$tg.Dispose()
$tile.Dispose()
Write-Output "ground.png written"

# ---------------------------------------------------------------------------
# Stone tile: 32x32, tileable both directions, no directional "top" stripe --
# for vertical wall columns where ground.png's grass-top would look wrong.
# ---------------------------------------------------------------------------
$stone = New-Object System.Drawing.Bitmap $tSize, $tSize, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$stg = [System.Drawing.Graphics]::FromImage($stone)
$stg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
$stg.Clear([System.Drawing.Color]::Transparent)
$stoneColor = Col 100 98 108
$stoneDark = Col 82 80 90
$stg.FillRectangle((New-Object System.Drawing.SolidBrush $stoneColor), 0, 0, $tSize, $tSize)
$stoneDarkBrush = New-Object System.Drawing.SolidBrush $stoneDark
$blocks = @(@(0,0,15,15), @(16,0,15,9), @(16,10,15,6), @(0,16,9,15), @(10,16,21,7), @(10,24,21,7))
foreach ($b in $blocks) {
    $stg.DrawRectangle((New-Object System.Drawing.Pen $stoneDark, 1), $b[0], $b[1], $b[2], $b[3])
}
$stone.Save("$tileDir\stone.png", [System.Drawing.Imaging.ImageFormat]::Png)
$stg.Dispose()
$stone.Dispose()
Write-Output "stone.png written"
