# make-icon.ps1 - ASCII only. Draw fan glyph (GDI+, Material style) and pack multi-size ICO.
# Note: PowerShell '/' is REAL division — mask stride must use [math]::Floor!
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$dir = Join-Path $PSScriptRoot 'assets'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

function New-FanPng([int]$size, [string]$path) {
  $bmp = New-Object Drawing.Bitmap($size, $size)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.ScaleTransform($size / 256.0, $size / 256.0)
  $green = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 5, 150, 105))  # #059669
  for ($k = 0; $k -lt 3; $k++) {
    $g.TranslateTransform(128, 128)
    $g.RotateTransform($k * 120)
    $petal = New-Object Drawing.Drawing2D.GraphicsPath
    $petal.AddBezier(0, -22, -52, -32, -64, -96, 0, -112)
    $petal.AddBezier(0, -112, 64, -96, 52, -32, 0, -22)
    $g.FillPath($green, $petal)
    $petal.Dispose()
    $g.ResetTransform()
    $g.ScaleTransform($size / 256.0, $size / 256.0)
  }
  $g.ResetTransform()
  $g.TranslateTransform($size / 2.0, $size / 2.0)
  $hub = $size * 0.075
  $g.FillEllipse($green, [float](-$hub), [float](-$hub), [float](2*$hub), [float](2*$hub))
  $g.Dispose()
  $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

# Build one BMP-format ICO entry via BinaryWriter (BITMAPINFOHEADER + bottom-up BGRA + AND mask)
function Get-BmpEntryBytes([Drawing.Bitmap]$bmp) {
  $w = $bmp.Width; $h = $bmp.Height
  $rect = New-Object Drawing.Rectangle(0, 0, $w, $h)
  $bd = $bmp.LockBits($rect, [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $stride = $bd.Stride
  $pix = New-Object byte[] ($stride * $h)
  [Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $pix, 0, $pix.Length)
  $bmp.UnlockBits($bd)
  $rowBytes = $w * 4
  $maskStride = [int][math]::Floor(($w + 31) / 32) * 4

  $ms = New-Object IO.MemoryStream
  $bw = New-Object IO.BinaryWriter($ms)
  $bw.Write([uint32]40)        # biSize
  $bw.Write([int32]$w)         # biWidth
  $bw.Write([int32](2 * $h))   # biHeight (XOR + AND)
  $bw.Write([uint16]1)         # biPlanes
  $bw.Write([uint16]32)        # biBitCount
  $bw.Write([uint32]0)         # biCompression = BI_RGB
  $bw.Write([uint32]0)         # biSizeImage (can be 0 for BI_RGB)
  $bw.Write([int32]0)          # biXPelsPerMeter
  $bw.Write([int32]0)          # biYPelsPerMeter
  $bw.Write([uint32]0)         # biClrUsed
  $bw.Write([uint32]0)         # biClrImportant
  for ($y = ($h - 1); $y -ge 0; $y--) {                    # bottom-up rows
    $row = New-Object byte[] $rowBytes
    [Array]::Copy($pix, ($y * $stride), $row, 0, $rowBytes)
    $bw.Write($row)
  }
  $maskRow = New-Object byte[] $maskStride                  # all-zero AND mask (alpha rules)
  for ($y = 0; $y -lt $h; $y++) { $bw.Write($maskRow) }
  $bw.Flush()
  $bytes = $ms.ToArray()
  $bw.Close()
  return ,$bytes
}

$sizes = @(16,24,32,48,256)
foreach ($s in $sizes) { New-FanPng $s (Join-Path $dir "fan-$s.png") }
"png drawn: $($sizes -join ',')"

$png256 = [IO.File]::ReadAllBytes((Join-Path $dir 'fan-256.png'))
$entries = @()
foreach ($s in @(16,24,32,48)) {
  $bm = [Drawing.Bitmap]::FromFile((Join-Path $dir "fan-$s.png"))
  $eb = ,(Get-BmpEntryBytes $bm)
  $entries += @{ W = $s; IsPng = $false; Bytes = $eb[0] }
  $bm.Dispose()
}
$entries += @{ W = 256; IsPng = $true; Bytes = $png256 }

$ms2 = New-Object IO.MemoryStream
$bw2 = New-Object IO.BinaryWriter($ms2)
$bw2.Write([uint16]0); $bw2.Write([uint16]1); $bw2.Write([uint16]$entries.Count)
$offset = 6 + 16 * $entries.Count
foreach ($e in $entries) {
  $dim = if ($e.W -eq 256) { 0 } else { $e.W }
  $bw2.Write([byte]$dim); $bw2.Write([byte]$dim); $bw2.Write([byte]0); $bw2.Write([byte]0)
  $bw2.Write([uint16]1); $bw2.Write([uint16]32)
  $bw2.Write([uint32]$e.Bytes.Length); $bw2.Write([uint32]$offset)
  $offset += $e.Bytes.Length
}
foreach ($e in $entries) { $bw2.Write($e.Bytes) }
$bw2.Flush()
$icoPath = Join-Path $dir 'fan.ico'
[IO.File]::WriteAllBytes($icoPath, $ms2.ToArray())
$bw2.Close()
"ico written: $((Get-Item $icoPath).Length) bytes, entries=$($entries.Count)"

# --- byte-level self check: every BMP entry must start with 28 00 00 00 ---
$all = [IO.File]::ReadAllBytes($icoPath)
$cnt = [BitConverter]::ToUInt16($all, 4)
for ($i = 0; $i -lt $cnt; $i++) {
  $o = 6 + 16*$i
  $sz = [BitConverter]::ToUInt32($all, $o+8); $off = [BitConverter]::ToUInt32($all, $o+12)
  $head = ($all[$off..($off+3)] | ForEach-Object { $_.ToString('X2') }) -join ' '
  $isPng = ($all[$off..($off+7)] -join ',') -eq '137,80,78,71,13,10,26,10'
  "entry{0}: {1}x{2} size={3} off={4} first4=[{5}] png={6}" -f $i, $all[$o], $all[$o+1], $sz, $off, $head, $isPng
}

$ic = New-Object Drawing.Icon($icoPath)
"validate GDI+: Icon parsed, size=$($ic.Size.Width)x$($ic.Size.Height), handle=$($ic.Handle -ne [IntPtr]::Zero)"
$ic.Dispose()
