#Requires -Version 5.1
<#
Fan Butler GUI v2 — 超微主板风扇管家 (桌面版, 深色仪表盘)
============================================================
双击桌面"风扇管家"快捷方式启动 (自动请求管理员权限)。

v2 变化: 深色主题仪表盘 — 风扇转速条形图 / 温度色块 / 模式高亮切换。
技术: PowerShell 5.1 + WinForms + GDI+ (全部系统自带), IPMI 走 Windows
自带驱动, 零依赖零安装。底层命令实测校准 (X12DAi-N6 / BMC 1.3):
  查询模式: raw 0x30 0x45 0x00 | 设置模式: raw 0x30 0x45 0x01 <模式>
  读占空比: raw 0x30 0x70 0x66 0x00 <区> | RPM = 原始读数 x 140
#>

# ---------- 自动提权 ----------
$ident = [Security.Principal.WindowsIdentity]::GetCurrent()
$princ = New-Object Security.Principal.WindowsPrincipal($ident)
if (-not $princ.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $PSCommandPath)
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

# ============================================================
# IPMI 层 (与命令行版一致)
# ============================================================
$script:Device = $null
function Get-IpmiDevice {
    if ($script:Device) { return $script:Device }
    $d = Get-CimInstance -Namespace root\WMI -ClassName Microsoft_IPMI -ErrorAction Stop | Select-Object -First 1
    if (-not $d) { throw '找不到 IPMI 设备 (需要管理员权限)' }
    $script:Device = $d; return $d
}
function Invoke-IpmiRaw {
    param([byte]$NetFn, [byte]$Cmd, [byte[]]$Data = @())
    $a = @{ NetworkFunction=$NetFn; Command=$Cmd; Lun=[byte]0; ResponderAddress=[byte]0x20
            RequestData=[byte[]]$Data; RequestDataSize=[uint32]$Data.Length }
    $r = Invoke-CimMethod -InputObject (Get-IpmiDevice) -MethodName RequestResponse -Arguments $a
    $rd = [byte[]]$r.ResponseData
    if (-not $rd) { $rd = [byte[]]@() }
    if ($rd.Count -ge 2) { $rd = [byte[]]($rd[1..($rd.Count-1)]) } elseif ($rd.Count -eq 1) { $rd = [byte[]]@() }
    return [pscustomobject]@{ CompletionCode=[int]$r.CompletionCode; Data=$rd }
}
function Get-FanModeCode { $m = Invoke-IpmiRaw 0x30 0x45 @([byte]0x00); if ($m.CompletionCode -eq 0 -and $m.Data.Count -ge 1) { return [int]$m.Data[0] }; return -1 }
function Get-Duty { param([byte]$z) $g = Invoke-IpmiRaw 0x30 0x70 0x66 0x00 @($z); if ($g.CompletionCode -eq 0 -and $g.Data.Count -ge 1) { return [int]$g.Data[0] }; return -1 }
function Set-FanModeCode { param([int]$c) [void](Invoke-IpmiRaw 0x30 0x45 @([byte]0x01,[byte]$c)); Start-Sleep -Milliseconds 2500; return (Get-FanModeCode) }
function Read-SensorRaw { param([byte]$n) $r = Invoke-IpmiRaw 0x04 0x2D @($n); if ($r.CompletionCode -ne 0 -or $r.Data.Count -lt 1) { return $null }; return [int]$r.Data[0] }

$FanDefs = @(
    @{ Name='FAN1'; Num=0x41 }, @{ Name='FAN2'; Num=0x42 }, @{ Name='FAN3'; Num=0x43 }, @{ Name='FAN4'; Num=0x44 },
    @{ Name='FAN5'; Num=0x45 }, @{ Name='FAN6'; Num=0x46 }, @{ Name='FAN7'; Num=0x47 }, @{ Name='FANA'; Num=0x48 }
)
$TempDefs = @(
    @{ Name='CPU1'; Num=0x01 }, @{ Name='CPU2'; Num=0x02 }, @{ Name='PCH'; Num=0x0A },
    @{ Name='系统'; Num=0x0B }, @{ Name='外设'; Num=0x0C }, @{ Name='VRM供电'; Num=0x10 }
)
$ModeNames = @{ 0='Standard 标准'; 1='Full 全速'; 2='Optimal 最优'; 3='Heavy IO' }

# ============================================================
# 主题
# ============================================================
$C      = @{
    Bg     = [Drawing.Color]::FromArgb(32,34,38)
    Card   = [Drawing.Color]::FromArgb(43,45,51)
    CardHi = [Drawing.Color]::FromArgb(52,55,63)
    Track  = [Drawing.Color]::FromArgb(60,63,71)
    Text   = [Drawing.Color]::FromArgb(230,232,235)
    Sub    = [Drawing.Color]::FromArgb(150,153,160)
    Green  = [Drawing.Color]::FromArgb(63,185,80)
    Blue   = [Drawing.Color]::FromArgb(76,141,255)
    Red    = [Drawing.Color]::FromArgb(255,107,107)
    Amber  = [Drawing.Color]::FromArgb(255,184,108)
}
$F9   = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$F8   = New-Object Drawing.Font('Microsoft YaHei UI', 8.25)
$F85  = New-Object Drawing.Font('Microsoft YaHei UI', 8.5)
$FBig = New-Object Drawing.Font('Microsoft YaHei UI', 13, [Drawing.FontStyle]::Bold)
$FTtl = New-Object Drawing.Font('Microsoft YaHei UI', 15, [Drawing.FontStyle]::Bold)

function New-Rounded([float]$x,[float]$y,[float]$w,[float]$h,[float]$r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $p.AddArc($x, $y, 2*$r, 2*$r, 180, 90)
    $p.AddArc(($x + $w - 2*$r), $y, 2*$r, 2*$r, 270, 90)
    $p.AddArc(($x + $w - 2*$r), ($y + $h - 2*$r), 2*$r, 2*$r, 0, 90)
    $p.AddArc($x, ($y + $h - 2*$r), 2*$r, 2*$r, 90, 90)
    $p.CloseFigure(); return $p
}
function Enable-DoubleBuffer($ctl) {
    $ctl.GetType().GetProperty('DoubleBuffered',[Reflection.BindingFlags]'Instance,NonPublic').SetValue($ctl, $true)
}

# ============================================================
# 窗口骨架
# ============================================================
$form = New-Object Windows.Forms.Form
$form.Text = '风扇管家 · X12DAi-N6'
$form.Size = New-Object Drawing.Size(476, 690)
$form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'; $form.Font = $F9
$form.BackColor = $C.Bg

# --- 头部 ---
$lblTitle = New-Object Windows.Forms.Label
$lblTitle.Text = '风扇管家'; $lblTitle.Font = $FTtl; $lblTitle.ForeColor = $C.Text
$lblTitle.Location = New-Object Drawing.Point(14, 10); $lblTitle.Size = New-Object Drawing.Size(160, 30)
$form.Controls.Add($lblTitle)

$lblFw = New-Object Windows.Forms.Label
$lblFw.Text = 'BMC 固件 1.3 · IPMI 2.0'; $lblFw.Font = $F8; $lblFw.ForeColor = $C.Sub
$lblFw.Location = New-Object Drawing.Point(16, 40); $lblFw.Size = New-Object Drawing.Size(220, 16)
$form.Controls.Add($lblFw)

$lblMode = New-Object Windows.Forms.Label
$lblMode.Font = $FBig; $lblMode.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$lblMode.Location = New-Object Drawing.Point(230, 14); $lblMode.Size = New-Object Drawing.Size(216, 28)
$form.Controls.Add($lblMode)

# --- 卡片构造器 ---
function New-Card([string]$title, [int]$x, [int]$y, [int]$w, [int]$h) {
    $p = New-Object Windows.Forms.Panel
    $p.Location = New-Object Drawing.Point($x, $y); $p.Size = New-Object Drawing.Size($w, $h)
    $p.Tag = $title
    $p.Add_Paint({ param($s,$e)
        $e.Graphics.SmoothingMode = 'AntiAlias'
        $path = New-Rounded 0 0 ($s.Width-1) ($s.Height-1) 10
        $br = New-Object Drawing.SolidBrush($script:C.Card)
        $e.Graphics.FillPath($br, $path); $br.Dispose()
        if ($s.Tag) {
            $f = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)
            $br2 = New-Object Drawing.SolidBrush($script:C.Sub)
            $e.Graphics.DrawString($s.Tag, $f, $br2, 16.0, 10.0); $br2.Dispose(); $f.Dispose()
        }
        $path.Dispose()
    })
    Enable-DoubleBuffer $p
    $form.Controls.Add($p)
    return $p
}
function New-Blk([string]$text, $font, $color, [int]$x, [int]$y, [int]$w, [int]$h, $parent) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Font = $font; $l.ForeColor = $color; $l.BackColor = 'Transparent'
    $l.Location = New-Object Drawing.Point($x, $y); $l.Size = New-Object Drawing.Size($w, $h)
    $parent.Controls.Add($l); return $l
}

# --- 卡片1: 风扇 ---
$cardFans = New-Card '风扇转速' 12 66 436 200
$script:FanVals = @{}; $script:FanBars = @{}
for ($i = 0; $i -lt 8; $i++) {
    $col = [math]::Floor($i / 4); $row = $i % 4
    $tx = 16 + $col * 212; $ty = 36 + $row * 42
    [void](New-Blk $FanDefs[$i].Name $F85 $C.Sub $tx $ty 44 18 $cardFans)
    $v = New-Blk '—' $FBig $C.Text ($tx + 44) ($ty - 4) 90 26 $cardFans
    $script:FanVals[$FanDefs[$i].Name] = $v
    $bar = New-Object Windows.Forms.Panel
    $bar.Location = New-Object Drawing.Point(($tx + 138), ($ty + 6)); $bar.Size = New-Object Drawing.Size(56, 7)
    $bar.Tag = 0.0
    $bar.Add_Paint({ param($s,$e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $t = New-Object Drawing.SolidBrush($script:C.Track)
        $tp = New-Rounded 0 0 ($s.Width-1) ($s.Height-1) 3
        $g.FillPath($t, $tp); $t.Dispose()
        $pct = [math]::Max(0.0, [math]::Min(1.0, [double]$s.Tag))
        if ($pct -gt 0.02) {
            $col = if ($pct -ge 0.75) { $script:C.Red } elseif ($pct -ge 0.5) { $script:C.Amber } else { $script:C.Green }
            $b = New-Object Drawing.SolidBrush($col)
            $fp = New-Rounded 0 0 ([float]($s.Width * $pct)) ($s.Height-1) 3
            $g.FillPath($b, $fp); $b.Dispose(); $fp.Dispose()
        }
        $tp.Dispose()
    })
    Enable-DoubleBuffer $bar
    $cardFans.Controls.Add($bar)
    $script:FanBars[$FanDefs[$i].Name] = $bar
}
$lblDuty = New-Blk 'CPU区占空比 —' $F85 $C.Sub 16 172 404 18 $cardFans

# --- 卡片2: 温度 ---
$cardTemp = New-Card '温度 (°C)' 12 276 436 164
$script:TempVals = @{}; $script:TempBars = @{}
for ($i = 0; $i -lt 6; $i++) {
    $col = [math]::Floor($i / 3); $row = $i % 3
    $tx = 16 + $col * 140; $ty = 36 + $row * 44
    [void](New-Blk $TempDefs[$i].Name $F85 $C.Sub $tx $ty 74 18 $cardTemp)
    $v = New-Blk '—' $FBig $C.Green ($tx + 74) ($ty - 4) 54 26 $cardTemp
    $script:TempVals[$TempDefs[$i].Name] = $v
    $bar = New-Object Windows.Forms.Panel
    $bar.Location = New-Object Drawing.Point($tx, ($ty + 26)); $bar.Size = New-Object Drawing.Size(120, 5)
    $bar.Tag = 0.0
    $bar.Add_Paint({ param($s,$e)
        $g = $e.Graphics
        $t = New-Object Drawing.SolidBrush($script:C.Track)
        $g.FillRectangle($t, 0, 0, $s.Width, $s.Height); $t.Dispose()
        $frac = [math]::Max(0.0, [math]::Min(1.0, [double]$s.Tag / 100.0))
        if ($frac -gt 0.01) {
            $col = if ($frac -ge 0.75) { $script:C.Red } elseif ($frac -ge 0.60) { $script:C.Amber } else { $script:C.Green }
            $b = New-Object Drawing.SolidBrush($col)
            $g.FillRectangle($b, 0, 0, [float]($s.Width * $frac), $s.Height); $b.Dispose()
        }
    })
    Enable-DoubleBuffer $bar
    $cardTemp.Controls.Add($bar)
    $script:TempBars[$TempDefs[$i].Name] = $bar
}

# --- 卡片3: 模式 ---
$cardMode = New-Card $null 12 450 436 120
$script:ModeBtns = @{}
function New-ModeBtn([string]$text, [int]$x, $accent, [int]$code) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Font = $F9; $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 1
    $b.Location = New-Object Drawing.Point($x, 22); $b.Size = New-Object Drawing.Size(128, 46)
    $b.Region = New-Object Drawing.Region((New-Rounded 0 0 127 45 8))
    $b.Tag = @{ Acc = $accent; Code = $code }
    $cardMode.Controls.Add($b)
    $script:ModeBtns[$code] = $b
    return $b
}
$btnOpt = New-ModeBtn '安静模式 Optimal' 16  $C.Green 2
$btnStd = New-ModeBtn '标准模式 Standard' 154 $C.Blue 0
$btnFul = New-ModeBtn '全速模式 Full' 292 $C.Red 1

function Update-ModeVisual([int]$active) {
    foreach ($c in $script:ModeBtns.Keys) {
        $b = $script:ModeBtns[$c]; $acc = $b.Tag.Acc
        if ($c -eq $active) { $b.BackColor = $acc; $b.ForeColor = [Drawing.Color]::White; $b.FlatAppearance.BorderColor = $acc }
        else { $b.BackColor = $script:C.CardHi; $b.ForeColor = $acc; $b.FlatAppearance.BorderColor = $acc }
    }
}
[void](New-Blk '安静 = BMC 智能调速 (日常推荐) · 标准 = 出厂默认 · 全速 = 最强散热' $F8 $C.Sub 16 84 404 18 $cardMode)
[void](New-Blk '本机固件不支持手动固定转速, 转速由 BMC 按温度自动管理' $F8 $C.Sub 16 100 404 18 $cardMode)

# --- 状态栏 ---
$cardStat = New-Card $null 12 580 436 48
$lblStatus = New-Blk '就绪。' $F85 $C.Sub 14 12 408 26 $cardStat
[void](New-Blk '每 5 秒自动刷新 · 命令行版 fan.ps1 · 万能恢复: 点[标准模式]' $F8 $C.Sub 12 634 436 16 $form)

# ============================================================
# 逻辑
# ============================================================
function Set-Status([string]$t) { $lblStatus.Text = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $t }

function Invoke-Refresh {
    try {
        $mode = Get-FanModeCode
        if ($ModeNames.ContainsKey($mode)) {
            $lblMode.Text = $ModeNames[$mode]
            $lblMode.ForeColor = switch ($mode) { 1 { $C.Red } 2 { $C.Green } 0 { $C.Blue } default { $C.Sub } }
            Update-ModeVisual $mode
        } else { $lblMode.Text = '模式未知'; $lblMode.ForeColor = $C.Sub }
        foreach ($f in $FanDefs) {
            $raw = Read-SensorRaw ([byte]$f.Num)
            $v = $script:FanVals[$f.Name]; $bar = $script:FanBars[$f.Name]
            if ($null -ne $raw -and $raw -gt 0) {
                $rpm = $raw * 140
                $v.Text = "$rpm"; $v.ForeColor = $C.Text
                $bar.Tag = [math]::Min(1.0, $rpm / 2500.0)
            } else { $v.Text = '空位'; $v.ForeColor = $C.Track; $bar.Tag = 0.0 }
            $bar.Invalidate()
        }
        $duty = Get-Duty 0x00
        if ($duty -ge 0) { $lblDuty.Text = "CPU区占空比 $duty% · BMC 自动曲线当前输出" }
        foreach ($t in $TempDefs) {
            $raw = Read-SensorRaw ([byte]$t.Num)
            $v = $script:TempVals[$t.Name]; $bar = $script:TempBars[$t.Name]
            if ($null -ne $raw -and $raw -gt 0) {
                $v.Text = "$raw"
                $v.ForeColor = if ($raw -ge 75) { $C.Red } elseif ($raw -ge 60) { $C.Amber } else { $C.Green }
                $bar.Tag = [double]$raw
            } else { $v.Text = '—'; $v.ForeColor = $C.Track; $bar.Tag = 0.0 }
            $bar.Invalidate()
        }
    } catch { Set-Status ("刷新失败: " + $_.Exception.Message) }
}

function Invoke-ApplyMode([int]$code, [string]$label) {
    $script:timer.Stop()
    try {
        $form.Cursor = 'WaitCursor'
        Set-Status "正在切换到 $label ..."
        $form.Refresh()
        [void](Set-FanModeCode $code)
        Start-Sleep -Milliseconds 1200
        Invoke-Refresh
        $now = Get-FanModeCode
        if ($now -eq $code) { Set-Status "已切换到 $label (BMC 回读确认)。" }
        else { Set-Status "切换后回读为 [$($ModeNames[$now])], 请再点一次。" }
    } catch {
        Set-Status ("切换失败: " + $_.Exception.Message)
    } finally {
        $form.Cursor = 'Default'
        $script:timer.Start()
    }
}
$btnOpt.Add_Click({ Invoke-ApplyMode 2 '安静模式 Optimal' })
$btnStd.Add_Click({ Invoke-ApplyMode 0 '标准模式 Standard' })
$btnFul.Add_Click({
    if ([Windows.Forms.MessageBox]::Show('全速模式噪音很大, 确定切换吗?', '确认', 'YesNo', 'Warning') -eq 'Yes') {
        Invoke-ApplyMode 1 '全速模式 Full'
    }
})

$script:timer = New-Object Windows.Forms.Timer
$script:timer.Interval = 5000
$script:timer.Add_Tick({ Invoke-Refresh })
$script:timer.Start()
$form.Add_Shown({ Invoke-Refresh })

if (-not [Environment]::UserInteractive) {
    Invoke-Refresh; Start-Sleep -Seconds 3; Invoke-Refresh
    Write-Output ("SELFTEST mode=[{0}] duty=[{1}] FAN1=[{2}] CPU1=[{3}]" -f `
        $lblMode.Text, $lblDuty.Text, $script:FanVals['FAN1'].Text, $script:TempVals['CPU1'].Text)
    exit 0
}
[void]$form.ShowDialog()
$form.Dispose()
