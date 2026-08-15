#Requires -Version 5.1
<#
Fan Butler GUI — 超微主板风扇管家 (桌面版)
============================================
窗口程序: 显示风扇转速/温度, 一键切换风扇模式 (安静/标准/全速)。
双击桌面的"风扇管家"快捷方式启动 (会自动请求管理员权限)。

技术: PowerShell 5.1 + WinForms (系统自带), IPMI 走 Windows 自带驱动,
     零依赖零安装。底层命令与命令行版 fan.ps1 一致, 全部经过实测校准:
  - 查询模式: raw 0x30 0x45 0x00
  - 设置模式: raw 0x30 0x45 0x01 <模式>   (0x00 是查询选择符, 勿用错)
  - 读占空比: raw 0x30 0x70 0x66 0x00 <区>
  - 风扇 RPM = 原始读数 x 140 (SDR 实测 M=140); 温度原始读数即 °C
#>

# ---------- 自动提权 (root\WMI 的 IPMI 接口需要管理员) ----------
$ident  = [Security.Principal.WindowsIdentity]::GetCurrent()
$princ  = New-Object Security.Principal.WindowsPrincipal($ident)
if (-not $princ.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $PSCommandPath)
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

# ============================================================
# IPMI 传输层 (与 fan.ps1 相同, 实测校准)
# ============================================================
$script:Device    = $null
$script:Responder = 0x20

function Get-IpmiDevice {
    if ($script:Device) { return $script:Device }
    $d = Get-CimInstance -Namespace root\WMI -ClassName Microsoft_IPMI -ErrorAction Stop |
         Select-Object -First 1
    if (-not $d) { throw '找不到 IPMI 设备 (需要管理员权限, 且驱动正常)' }
    $script:Device = $d
    return $d
}

function Invoke-IpmiRaw {
    param([byte]$NetFn, [byte]$Cmd, [byte[]]$Data = @())
    $a = @{ NetworkFunction = $NetFn; Command = $Cmd; Lun = [byte]0
            ResponderAddress = [byte]$script:Responder
            RequestData = [byte[]]$Data; RequestDataSize = [uint32]$Data.Length }
    $r = Invoke-CimMethod -InputObject (Get-IpmiDevice) -MethodName RequestResponse -Arguments $a
    $rd = [byte[]]$r.ResponseData
    if (-not $rd) { $rd = [byte[]]@() }
    if ($rd.Count -ge 2) { $rd = [byte[]]($rd[1..($rd.Count-1)]) }   # 剥掉完成码回显
    elseif ($rd.Count -eq 1) { $rd = [byte[]]@() }
    return [pscustomobject]@{ CompletionCode = [int]$r.CompletionCode; Data = $rd }
}

function Get-FanModeCode {
    $m = Invoke-IpmiRaw 0x30 0x45 @([byte]0x00)
    if ($m.CompletionCode -ne 0 -or $m.Data.Count -lt 1) { return -1 }
    return [int]$m.Data[0]
}

function Get-Duty {
    param([byte]$Zone)
    $g = Invoke-IpmiRaw 0x30 0x70 0x66 0x00 @($Zone)
    if ($g.CompletionCode -ne 0 -or $g.Data.Count -lt 1) { return -1 }
    return [int]$g.Data[0]
}

function Set-FanModeCode {
    param([int]$Code)
    [void](Invoke-IpmiRaw 0x30 0x45 @([byte]0x01, [byte]$Code))
    Start-Sleep -Milliseconds 2500
    return (Get-FanModeCode)
}

function Read-SensorRaw {
    param([byte]$Number)
    $r = Invoke-IpmiRaw 0x04 0x2D @($Number)
    if ($r.CompletionCode -ne 0 -or $r.Data.Count -lt 1) { return $null }
    return [int]$r.Data[0]
}

# 传感器编号 (SDR 实测): 风扇 0x41-0x48, 温度 0x01/0x02/0x0A/0x0B/0x0C
$FanDefs = @(
    @{ Name='FAN1'; Num=0x41 }, @{ Name='FAN2'; Num=0x42 },
    @{ Name='FAN3'; Num=0x43 }, @{ Name='FAN4'; Num=0x44 },
    @{ Name='FAN5'; Num=0x45 }, @{ Name='FAN6'; Num=0x46 },
    @{ Name='FAN7'; Num=0x47 }, @{ Name='FANA'; Num=0x48 }
)
$TempDefs = @(
    @{ Name='CPU1';  Num=0x01 }, @{ Name='CPU2';  Num=0x02 },
    @{ Name='PCH';   Num=0x0A }, @{ Name='系统';  Num=0x0B },
    @{ Name='外设';  Num=0x0C }, @{ Name='VRM供电'; Num=0x10 }
)

$ModeNames = @{ 0='Standard (标准)'; 1='Full (全速)'; 2='Optimal (最优)'; 3='Heavy IO' }

# ============================================================
# 界面
# ============================================================
$Font  = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$FontB = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)

$form = New-Object Windows.Forms.Form
$form.Text            = '风扇管家 Fan Butler — X12DAi-N6'
$form.Size            = New-Object Drawing.Size(456, 668)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.StartPosition   = 'CenterScreen'
$form.Font            = $Font
$form.BackColor       = [Drawing.Color]::WhiteSmoke
$form.Icon            = [System.Drawing.SystemIcons]::Application

# --- 标题行 ---
$lblTitle       = New-Object Windows.Forms.Label
$lblTitle.Text  = '风扇管家'
$lblTitle.Font  = New-Object Drawing.Font('Microsoft YaHei UI', 14, [Drawing.FontStyle]::Bold)
$lblTitle.Location = New-Object Drawing.Point(16, 12)
$lblTitle.Size     = New-Object Drawing.Size(140, 30)
$form.Controls.Add($lblTitle)

$lblMode        = New-Object Windows.Forms.Label
$lblMode.Font   = $FontB
$lblMode.ForeColor = [Drawing.Color]::SteelBlue
$lblMode.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$lblMode.Location  = New-Object Drawing.Point(200, 14)
$lblMode.Size      = New-Object Drawing.Size(230, 26)
$form.Controls.Add($lblMode)

function New-Group([string]$text, [int]$x, [int]$y, [int]$w, [int]$h) {
    $g = New-Object Windows.Forms.GroupBox
    $g.Text = $text; $g.Font = $FontB
    $g.Location = New-Object Drawing.Point($x, $y)
    $g.Size     = New-Object Drawing.Size($w, $h)
    $form.Controls.Add($g)
    return $g
}

# --- 风扇组 ---
$gbFans = New-Group '风扇转速 (RPM)' 14 52 412 178
$script:FanLabels = @{}
for ($i = 0; $i -lt 8; $i++) {
    $col = [math]::Floor($i / 4); $row = $i % 4
    $nx = 24 + $col * 200; $ny = 28 + $row * 34
    $n = New-Object Windows.Forms.Label
    $n.Text = $FanDefs[$i].Name; $n.Font = $Font
    $n.Location = New-Object Drawing.Point($nx, $ny); $n.Size = New-Object Drawing.Size(52, 24)
    $gbFans.Controls.Add($n)
    $v = New-Object Windows.Forms.Label
    $v.Text = '—'; $v.Font = $FontB; $v.ForeColor = [Drawing.Color]::SeaGreen
    $v.TextAlign = [Drawing.ContentAlignment]::MiddleRight
    $v.Location = New-Object Drawing.Point(($nx + 56), $ny); $v.Size = New-Object Drawing.Size(96, 24)
    $gbFans.Controls.Add($v)
    $script:FanLabels[$FanDefs[$i].Name] = $v
}
$lblDuty        = New-Object Windows.Forms.Label
$lblDuty.Text   = 'CPU区占空比: —'
$lblDuty.Font   = $Font
$lblDuty.Location = New-Object Drawing.Point(24, 164)
$lblDuty.Size     = New-Object Drawing.Size(360, 20)
$gbFans.Controls.Add($lblDuty)

# --- 温度组 ---
$gbTemps = New-Group '温度 (°C)' 14 240 412 152
$script:TempLabels = @{}
for ($i = 0; $i -lt 6; $i++) {
    $col = [math]::Floor($i / 3); $row = $i % 3
    $nx = 24 + $col * 200; $ny = 28 + $row * 34
    $n = New-Object Windows.Forms.Label
    $n.Text = $TempDefs[$i].Name; $n.Font = $Font
    $n.Location = New-Object Drawing.Point($nx, $ny); $n.Size = New-Object Drawing.Size(72, 24)
    $gbTemps.Controls.Add($n)
    $v = New-Object Windows.Forms.Label
    $v.Text = '—'; $v.Font = $FontB; $v.ForeColor = [Drawing.Color]::DarkOrange
    $v.TextAlign = [Drawing.ContentAlignment]::MiddleRight
    $v.Location = New-Object Drawing.Point(($nx + 76), $ny); $v.Size = New-Object Drawing.Size(76, 24)
    $gbTemps.Controls.Add($v)
    $script:TempLabels[$TempDefs[$i].Name] = $v
}

# --- 模式组 ---
$gbMode = New-Group '风扇模式 (一键切换, 随时可改)' 14 402 412 122

function New-ModeButton([string]$text, [int]$x, [drawing.color]$back) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Font = $FontB
    $b.FlatStyle = 'Flat'; $b.BackColor = $back; $b.ForeColor = [Drawing.Color]::White
    $b.Location = New-Object Drawing.Point($x, 30); $b.Size = New-Object Drawing.Size(118, 48)
    $gbMode.Controls.Add($b)
    return $b
}
$btnOptimal  = New-ModeButton "安静模式`nOptimal" 24 ([Drawing.Color]::MediumSeaGreen)
$btnStandard = New-ModeButton "标准模式`nStandard" 150 ([Drawing.Color]::SteelBlue)
$btnFull     = New-ModeButton "全速模式`nFull" 276 ([Drawing.Color]::Tomato)

$lblHint        = New-Object Windows.Forms.Label
$lblHint.Text   = '安静=智能调速(日常推荐) · 标准=出厂默认 · 全速=最强散热(吵)'
$lblHint.Font   = New-Object Drawing.Font('Microsoft YaHei UI', 8)
$lblHint.ForeColor = [Drawing.Color]::Gray
$lblHint.Location  = New-Object Drawing.Point(24, 88)
$lblHint.Size      = New-Object Drawing.Size(370, 20)
$gbMode.Controls.Add($lblHint)

# --- 状态栏 ---
$lblStatus        = New-Object Windows.Forms.Label
$lblStatus.Text   = '就绪。'
$lblStatus.Font   = $Font
$lblStatus.BorderStyle = 'FixedSingle'
$lblStatus.Location = New-Object Drawing.Point(14, 536)
$lblStatus.Size     = New-Object Drawing.Size(412, 44)
$form.Controls.Add($lblStatus)

$lblFoot        = New-Object Windows.Forms.Label
$lblFoot.Text   = '每 5 秒自动刷新 · 命令行版: fan.ps1 · 出问题就点[标准模式]恢复出厂状态'
$lblFoot.Font   = New-Object Drawing.Font('Microsoft YaHei UI', 8)
$lblFoot.ForeColor = [Drawing.Color]::Gray
$lblFoot.Location  = New-Object Drawing.Point(16, 592)
$lblFoot.Size      = New-Object Drawing.Size(410, 20)
$form.Controls.Add($lblFoot)

# ============================================================
# 逻辑
# ============================================================
function Set-Status([string]$text) {
    $lblStatus.Text = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $text
}

function Invoke-Refresh {
    try {
        # 模式
        $mode = Get-FanModeCode
        if ($mode -ge 0 -and $ModeNames.ContainsKey($mode)) {
            $lblMode.Text = "模式: $($ModeNames[$mode])"
            $lblMode.ForeColor = switch ($mode) {
                0 { [Drawing.Color]::SteelBlue } 1 { [Drawing.Color]::Firebrick }
                2 { [Drawing.Color]::SeaGreen }  default { [Drawing.Color]::Gray }
            }
        } else { $lblMode.Text = '模式: 未知' }
        # 风扇 (RPM = 原始值 x 140)
        foreach ($f in $FanDefs) {
            $raw = Read-SensorRaw ([byte]$f.Num)
            $lbl = $script:FanLabels[$f.Name]
            if ($null -ne $raw -and $raw -gt 0) { $lbl.Text = ('{0:n0} RPM' -f ($raw * 140)); $lbl.ForeColor = [Drawing.Color]::SeaGreen }
            else { $lbl.Text = '空位'; $lbl.ForeColor = [Drawing.Color]::LightGray }
        }
        # 占空比
        $duty = Get-Duty 0x00
        if ($duty -ge 0) { $lblDuty.Text = "CPU区占空比: $duty%  (BMC 自动曲线当前输出)" }
        # 温度
        foreach ($t in $TempDefs) {
            $raw = Read-SensorRaw ([byte]$t.Num)
            $lbl = $script:TempLabels[$t.Name]
            if ($null -ne $raw -and $raw -gt 0) {
                $lbl.Text = "$raw"
                $lbl.ForeColor = if ($raw -ge 75) { [Drawing.Color]::Firebrick }
                                 elseif ($raw -ge 60) { [Drawing.Color]::DarkOrange }
                                 else { [Drawing.Color]::SeaGreen }
            } else { $lbl.Text = '—'; $lbl.ForeColor = [Drawing.Color]::LightGray }
        }
    } catch {
        Set-Status ("刷新失败: " + $_.Exception.Message)
    }
}

function Invoke-ApplyMode([int]$code, [string]$label) {
    $script:timer.Stop()
    try {
        $form.Cursor = 'WaitCursor'
        Set-Status "正在切换到 $label ..."
        [void](Set-FanModeCode $code)
        $form.Refresh()
        Start-Sleep -Milliseconds 1500
        Invoke-Refresh
        $now = Get-FanModeCode
        if ($now -eq $code) { Set-Status "已切换到 $label (BMC 已确认)。" }
        else { Set-Status "切换 $label 后回读为 $($ModeNames[$now]), 请再点一次或用命令行版检查。" }
    } catch {
        Set-Status ("切换失败: " + $_.Exception.Message)
    } finally {
        $form.Cursor = 'Default'
        $script:timer.Start()
    }
}

$btnOptimal.Add_Click(  { Invoke-ApplyMode 2 '安静模式 (Optimal)' })
$btnStandard.Add_Click( { Invoke-ApplyMode 0 '标准模式 (Standard)' })
$btnFull.Add_Click(     {
    $ans = [Windows.Forms.MessageBox]::Show('全速模式风扇会满转速运行, 噪音很大。确定切换吗?',
        '确认', 'YesNo', 'Warning')
    if ($ans -eq 'Yes') { Invoke-ApplyMode 1 '全速模式 (Full)' }
})

$script:timer = New-Object Windows.Forms.Timer
$script:timer.Interval = 5000
$script:timer.Add_Tick({ Invoke-Refresh })
$script:timer.Start()

$form.Add_Shown({ Invoke-Refresh })

if (-not [Environment]::UserInteractive) {
    # 无桌面会话 (服务会话0等): 不弹窗, 做两轮真实刷新自检后退出 — 用于自动化测试
    Invoke-Refresh
    Start-Sleep -Seconds 3
    Invoke-Refresh
    Write-Output ("SELFTEST mode=[{0}] duty=[{1}] FAN1=[{2}] CPU1=[{3}]" -f `
        $lblMode.Text, $lblDuty.Text, $script:FanLabels['FAN1'].Text, $script:TempLabels['CPU1'].Text)
    exit 0
}

[void]$form.ShowDialog()
$form.Dispose()
