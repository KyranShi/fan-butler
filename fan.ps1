#Requires -Version 5.1
<#
Fan Butler — 超微主板风扇管家 (v0.9: 只读版, 已实测校准)
==========================================================
用途: 显示 Supermicro X12DAi-N6 的风扇转速与温度 (走 Windows 自带 IPMI 驱动,
      不需要安装任何软件, 不需要 BMC 账号密码)

用法:
  pwsh -NoProfile -File fan.ps1            # 显示状态
  pwsh -NoProfile -File fan.ps1 status      # 同上

实测校准笔记 (X12DAi-N6 / BMC 3.1 / IPMI 2.0, 2026-08):
  - 传输: root\WMI\Microsoft_IPMI 的 RequestResponse 方法, NetFn 原样传入;
          ResponseData 首字节是完成码回显, 真实负载从第 2 字节开始
  - SDR 枚举: 记录 ID 从 0x0004 起等差 +0x43, 共 53 条 (链表指针的高字节
          不可靠, 直接按步长盲扫最稳)
  - GetSDR 响应: [下一条ID(2字节)][记录本体]
  - 记录本体布局 (字节序号从 0 起, 与 IPMI 规范略有出入, 全部实测验证):
      [3] 记录类型 (0x01=Full传感器)
      [7] 传感器编号
      [12] 传感器类型 (0x01温度 0x02电压 0x04风扇 0x29电池...)
      [13] 读数类型 (0x01模拟量 0x6F离散量)
      [21] 基本单位 (0x01=°C 0x04=V 0x12=RPM)
      [24..25] M 系数 (16位无符号小端)
      [26..27] B 系数 (16位无符号小端)
      [29] 高4位=Rexp 低4位=Bexp (有符号)
      [47] 名字长度码 (0xC0|长度)
      [48..] 名字 (ASCII)
  - 换算公式: 工程值 = (M × 原始读数 + B × 10^Bexp) × 10^Rexp
      验证: 12V轨 原始142 M=83 B=48 → (142×83+48)/1000 = 11.83V ✓
            CPU温度 原始40 M=1 → 40°C ✓
            风扇 原始11 M=140 → 1540 RPM ✓
  - 读数 flags 字节恒为 0xC0 (不可信, 忽略)
  - 风扇模式查询: raw 0x30 0x45 0x00 → 0=Standard 1=Full 2=Optimal

v0.9 只读不写, 不会改变风扇任何状态。
#>
param(
    [string]$Command = 'status',
    [string]$Arg1,
    [string]$Arg2
)
$ErrorActionPreference = 'Stop'

# ============================================================
# 一、IPMI 传输层 (已校准: RequestResponse / NetFn原样 / 剥完成码回显)
# ============================================================
$script:Device    = $null
$script:Responder = 0x20

function Get-IpmiDevice {
    if ($script:Device) { return $script:Device }
    $d = Get-CimInstance -Namespace root\WMI -ClassName Microsoft_IPMI -ErrorAction Stop |
         Select-Object -First 1
    if (-not $d) { throw '找不到 root\WMI\Microsoft_IPMI 设备, 请确认系统 IPMI 驱动正常 (设备管理器中应有 Microsoft Generic IPMI Compliant Device)' }
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

# ============================================================
# 二、SDR 传感器枚举 (等差步长扫描, 实测 53 条)
# ============================================================
$script:SdrResv = $null

function Update-SdrReservation {
    $r = Invoke-IpmiRaw 0x0A 0x22
    if ($r.CompletionCode -ne 0 -or $r.Data.Count -lt 2) {
        throw ("预留 SDR 仓库失败 CC=0x{0:X2}" -f $r.CompletionCode)
    }
    $script:SdrResv = [byte[]]@($r.Data[0], $r.Data[1])
}

function Read-SdrById {
    param([int]$Id)
    if ($null -eq $script:SdrResv) { Update-SdrReservation }
    $lo = [byte]($Id -band 0xFF); $hi = [byte](($Id -shr 8) -band 0xFF)
    $h = Invoke-IpmiRaw 0x0A 0x23 @($script:SdrResv[0], $script:SdrResv[1], $lo, $hi, [byte]0, [byte]7)
    if ($h.CompletionCode -eq 0xC5) { Update-SdrReservation; $h = Invoke-IpmiRaw 0x0A 0x23 @($script:SdrResv[0], $script:SdrResv[1], $lo, $hi, [byte]0, [byte]7) }
    if ($h.CompletionCode -ne 0 -or $h.Data.Count -lt 7) { return $null }
    $bodyLen = [int]$h.Data[6]
    $total = [Math]::Min(5 + $bodyLen, 0xE0)
    $g = Invoke-IpmiRaw 0x0A 0x23 @($script:SdrResv[0], $script:SdrResv[1], $lo, $hi, [byte]0, [byte]$total)
    if ($g.CompletionCode -eq 0xC5) { Update-SdrReservation; $g = Invoke-IpmiRaw 0x0A 0x23 @($script:SdrResv[0], $script:SdrResv[1], $lo, $hi, [byte]0, [byte]$total) }
    if ($g.CompletionCode -ne 0) { return ,([byte[]]$h.Data) }
    return ,([byte[]]$g.Data)
}

function ConvertTo-SignedNibble { param([int]$Nib) if ($Nib -gt 7) { $Nib - 16 } else { $Nib } }

# 解析一条传感器记录 (布局见文件头校准笔记)
function Parse-SensorRecord {
    param([byte[]]$d)     # d = GetSDR 响应负载: [nextId(2)][记录]
    if ($d.Count -lt 48) { return $null }
    $recType = [int]$d[5]
    if ($recType -ne 0x01) { return $null }        # 只处理 Full 传感器记录
    $bodyLen = [int]$d[6]
    $recEnd  = [Math]::Min($d.Count, 7 + $bodyLen)
    # 名字: 长度码在记录[47]→d[49], 名字在记录[48]→d[50]
    $name = $null
    if ($recEnd -gt 50) {
        $idLen = [int]($d[49] -band 0x1F)
        if ($idLen -gt 0 -and (50 + $idLen) -le $recEnd) {
            $name = [Text.Encoding]::ASCII.GetString($d, 50, $idLen).Trim([char]0, ' ')
        }
    }
    if (-not $name) { return $null }
    $m = [int]($d[26] -bor ($d[27] -shl 8))
    $b = [int]($d[28] -bor ($d[29] -shl 8))
    return [pscustomobject]@{
        Number  = [int]$d[9]
        Name    = $name
        TypeCode = [int]$d[14]          # 0x01温度 0x02电压 0x04风扇 ...
        ReadingType = [int]$d[15]       # 0x01模拟量 0x6F离散量
        Unit    = [int]$d[23]
        M = $m; B = $b
        Rexp = (ConvertTo-SignedNibble ($d[31] -shr 4)); Bexp = (ConvertTo-SignedNibble ($d[31] -band 0xF))
    }
}

# 读取一个传感器的当前原始值; 无读数返回 $null (flags 字节不可信, 忽略)
function Read-SensorRaw {
    param([int]$Number)
    $r = Invoke-IpmiRaw 0x04 0x2D @([byte]$Number)
    if ($r.CompletionCode -ne 0 -or $r.Data.Count -lt 1) { return $null }
    return [int]$r.Data[0]
}

function Convert-Reading {
    param($Sensor, [int]$Raw)
    if ($Sensor.ReadingType -ne 0x01) { return $null }   # 离散量不做工程值换算
    $y = ($Sensor.M * [double]$Raw + $Sensor.B * [math]::Pow(10, $Sensor.Bexp)) * [math]::Pow(10, $Sensor.Rexp)
    return [math]::Round($y, 2)
}

function Get-UnitName { param([int]$Unit)
    switch ($Unit) {
        1     { '°C' }  2 { '°F' }  4 { 'V' }  5 { 'W' }  6 { 'A' }
        0x12  { 'RPM' } 0x10 { 'm' }  default { "u$Unit" }
    }
}

# 全量枚举: 等差步长扫描 0x0004 + k*0x43 (进程内缓存, 避免每次重复枚举)
$script:SensorCache = $null
function Get-AllSensors {
    if ($script:SensorCache) { return $script:SensorCache }
    Update-SdrReservation
    $sensors = @()
    foreach ($k in 0..64) {
        $d = Read-SdrById (4 + 0x43 * $k)
        if ($null -eq $d) { continue }
        $p = Parse-SensorRecord $d
        if ($p) { $sensors += $p }
    }
    $script:SensorCache = $sensors
    return $sensors
}

# 快照: 风扇 RPM + 关键温度 (用于命令执行后的即时验证)
function Get-FanSnapshot {
    $rows = foreach ($s in (Get-AllSensors)) {
        if ($s.TypeCode -ne 0x04 -and $s.TypeCode -ne 0x01) { continue }
        $raw = Read-SensorRaw $s.Number
        $val = if ($null -ne $raw) { Convert-Reading $s $raw } else { $null }
        [pscustomobject]@{ Name = $s.Name; TypeCode = $s.TypeCode; Value = $val; Raw = $raw }
    }
    return $rows
}

function Show-FanSnapshot {
    param([string]$Title)
    Write-Host ""
    Write-Host "--- $Title ---"
    foreach ($r in (Get-FanSnapshot)) {
        if ($r.TypeCode -eq 0x04) {
            if ($null -ne $r.Value)   { Write-Host ('  {0,-8} {1,6} RPM' -f $r.Name, [int]$r.Value) }
            elseif ($null -ne $r.Raw) { Write-Host ('  {0,-8} {1,6} (原始值)' -f $r.Name, $r.Raw) }
            else                      { Write-Host ('  {0,-8}    空位' -f $r.Name) }
        } elseif ($r.Name -match '^(CPU1|CPU2|PCH|System|Peripheral) ') {
            if ($null -ne $r.Value)   { Write-Host ('  {0,-16}{1,4} °C' -f $r.Name, [int]$r.Value) }
        }
    }
}

# ============================================================
# 三、写操作 (v1) — 每条命令执行前打印将发送的原始 IPMI 指令
# 实测要点 (X12DAi-N6 / BMC 3.1):
#   查询模式: raw 0x30 0x45 0x00        → 返回 0/1/2/3
#   设置模式: raw 0x30 0x45 0x01 <模式> ← 设置时第一数据字节是 0x01 (0x00 是查询,
#             发 0x00 <模式> 会被"接受"但不执行 — 实测踩坑)
#   手动转速: raw 0x30 0x70 0x66 0x01 <区> <百分比>
#             仅在 Full 模式下生效; 且切到 Full 后需等 ~15 秒让 BMC 完成模式
#             切换, 期间发送的转速命令会被静默丢弃 (实测踩坑)
# ============================================================
$ModeNames = @{ 0 = 'Standard (BMC 自动)'; 1 = 'Full (全速)'; 2 = 'Optimal (最优)'; 3 = 'Heavy IO' }

function Get-FanModeCode {
    $m = Invoke-IpmiRaw 0x30 0x45 @([byte]0x00)
    if ($m.CompletionCode -ne 0 -or $m.Data.Count -lt 1) { return $null }
    return [int]$m.Data[0]
}

function Set-FanMode {
    param([int]$Code)
    Write-Host ('> raw 0x30 0x45 0x01 0x{0:X2}   (设置风扇模式 → {1})' -f $Code, $ModeNames[$Code])
    $r = Invoke-IpmiRaw 0x30 0x45 @([byte]0x01, [byte]$Code)
    if ($r.CompletionCode -ne 0) { throw ("设置模式失败 CC=0x{0:X2}" -f $r.CompletionCode) }
    Start-Sleep -Seconds 3
    $now = Get-FanModeCode
    if ($null -eq $now)      { Write-Host '已发送 (回读模式失败, 请用 status 查看)' }
    elseif ($now -ne $Code)  { Write-Host ("警告: 回读模式为 {0}, 与目标不一致" -f $ModeNames[$now]) }
    else                     { Write-Host ("OK, 模式已确认: {0}" -f $ModeNames[$now]) }
}

function Invoke-Mode {
    param([string]$Name)
    $map = @{ 'standard' = 0; 'full' = 1; 'optimal' = 2; 'heavy' = 3; 'heavyio' = 3 }
    $key = if ($Name) { $Name.ToLower() } else { '' }
    if (-not $map.ContainsKey($key)) {
        Write-Host '用法: fan.ps1 mode standard|optimal|full|heavy'
        Write-Host '  standard = 交还 BMC 自动控制 (最安全, 出厂默认)'
        Write-Host '  optimal  = BMC 智能调速 (安静与散热的折中)'
        Write-Host '  full     = 全速 (最吵, 散热最强)'
        return
    }
    Set-FanMode $map[$key]
    Start-Sleep -Seconds 6
    Show-FanSnapshot '当前风扇/温度'
}

# 在位风扇平均原始转速 (用于验证转速命令是否生效)
function Get-FanAvgRaw {
    $vals = @(Get-FanSnapshot | Where-Object { $_.TypeCode -eq 0x04 -and $null -ne $_.Raw -and $_.Raw -gt 0 } | ForEach-Object { $_.Raw })
    if ($vals.Count -eq 0) { return $null }
    return [math]::Round(($vals | Measure-Object -Average).Average, 1)
}

function Invoke-Set {
    param([string]$ZoneName, [string]$PctStr)
    $zoneMap = @{ 'cpu' = 0x00; 'periph' = 0x01; 'peripheral' = 0x01; 'pch' = 0x01 }
    $key = if ($ZoneName) { $ZoneName.ToLower() } else { '' }
    $pct = 0
    if (-not $zoneMap.ContainsKey($key) -or -not [int]::TryParse($PctStr, [ref]$pct)) {
        Write-Host '用法: fan.ps1 set cpu|periph <20-100>'
        Write-Host '  cpu    = CPU/系统区风扇'
        Write-Host '  periph = 外设区风扇'
        Write-Host '  转速为占空比百分比, 出于安全已锁定 20-100'
        return
    }
    if ($pct -lt 20) { Write-Host "下限保护: $pct% → 20% (更低会导致风扇停转)"; $pct = 20 }
    if ($pct -gt 100) { Write-Host "上限保护: $pct% → 100%"; $pct = 100 }
    $zone = $zoneMap[$key]

    # 手动占空比只在 Full 模式下生效; 且切换后必须等 BMC 完成模式切换 (~15 秒),
    # 否则转速命令会被静默丢弃 (实测)
    $cur = Get-FanModeCode
    if ($cur -ne 1) {
        if ($null -ne $cur) { Write-Host ("当前模式 {0}, 手动转速需要 Full 模式, 先切换..." -f $ModeNames[$cur]) }
        Set-FanMode 1
        Write-Host '等待 BMC 完成模式切换 (15 秒)...'
        Start-Sleep -Seconds 15
    }
    # 发送 + 验证 + 重试 (实测这台 BMC 会偶发静默丢弃转速命令)
    $before = Get-FanAvgRaw
    Write-Host ('> raw 0x30 0x70 0x66 0x01 0x{0:X2} 0x{1:X2}   ({2} 区转速 → {3}%)' -f $zone, $pct, $key, $pct)
    $r = Invoke-IpmiRaw 0x30 0x70 0x66 0x01 @([byte]$zone, [byte]$pct)
    if ($r.CompletionCode -ne 0) { throw ("设置转速失败 CC=0x{0:X2}" -f $r.CompletionCode) }
    $after = $null; $ok = $false
    for ($try = 1; $try -le 3; $try++) {
        Start-Sleep -Seconds 6
        $after = Get-FanAvgRaw
        if ($null -eq $after -or $null -eq $before) { $ok = $true; break }              # 无法测量则不判失败
        if ($after -le ($before * 0.85))               { $ok = $true; break }           # 转速确实降了
        if ([math]::Abs($after - $before) -le ($before * 0.2)) { $ok = $true; break }   # 已在目标附近
        if ($try -lt 3) {
            Write-Host ("转速未见变化 (原始值 {0} → {1}), 重发指令 (第 {2} 次)..." -f $before, $after, ($try + 1))
            [void](Invoke-IpmiRaw 0x30 0x70 0x66 0x01 @([byte]$zone, [byte]$pct))
        }
    }
    if ($ok) { Write-Host ("OK, 转速原始值 {0} → {1} (占空比 {2}%)" -f $before, $after, $pct) }
    else     { Write-Host ("警告: 重试后转速仍为原始值 {0}, 请用 status 复查" -f $after) }
    Show-FanSnapshot '当前风扇/温度 (手动模式; 恢复自动: fan.ps1 restore)'
}

function Invoke-Restore {
    Write-Host '一键恢复: 交还 BMC 自动控制 (standard 模式)'
    Set-FanMode 0
    Start-Sleep -Seconds 3
    Show-FanSnapshot '当前风扇/温度'
}

# ============================================================
# 四、status
# ============================================================
function Invoke-Status {
    $modeName = '未知'
    try {
        $m = Invoke-IpmiRaw 0x30 0x45 @([byte]0x00)
        if ($m.CompletionCode -eq 0 -and $m.Data.Count -ge 1) {
            $modeName = switch ($m.Data[0]) {
                0 { 'Standard (BMC 自动调速)' } 1 { 'Full (全速!)' } 2 { 'Optimal (最优)' }
                3 { 'Heavy IO' } default { "代码 $($_)" }
            }
        }
    } catch { $modeName = '查询失败' }

    Write-Host ''
    Write-Host '======== Fan Butler v1 ========' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Write-Host ("风扇模式: {0}" -f $modeName)
    Write-Host '---------------------------------------'

    $sensors = Get-AllSensors
    $rows = foreach ($s in $sensors) {
        $raw = Read-SensorRaw $s.Number
        $val = if ($null -ne $raw) { Convert-Reading $s $raw } else { $null }
        [pscustomobject]@{ Name = $s.Name; TypeCode = $s.TypeCode; Unit = (Get-UnitName $s.Unit)
                           Value = $val; Raw = $raw }
    }

    $fans  = @($rows | Where-Object TypeCode -eq 0x04)
    $temps = @($rows | Where-Object TypeCode -eq 0x01)
    $volts = @($rows | Where-Object TypeCode -eq 0x02)
    $other = @($rows | Where-Object { $_.TypeCode -ne 0x04 -and $_.TypeCode -ne 0x01 -and $_.TypeCode -ne 0x02 })

    Write-Host ("`n[风扇] {0} 个传感器" -f $fans.Count)
    foreach ($f in ($fans | Sort-Object Name)) {
        if ($null -ne $f.Value)      { Write-Host ('  {0,-10} {1,8} {2}' -f $f.Name, [int]$f.Value, $f.Unit) }
        elseif ($null -ne $f.Raw)    { Write-Host ('  {0,-10} {1,8} (原始值, 未换算)' -f $f.Name, $f.Raw) }
        else                         { Write-Host ('  {0,-10}   无风扇/无读数' -f $f.Name) }
    }

    Write-Host ("`n[温度] {0} 个传感器" -f $temps.Count)
    foreach ($t in ($temps | Sort-Object Name)) {
        if ($null -ne $t.Value)      { Write-Host ('  {0,-18} {1,6} {2}' -f $t.Name, [int]$t.Value, $t.Unit) }
        elseif ($null -ne $t.Raw)    { Write-Host ('  {0,-18} {1,6} (原始值)' -f $t.Name, $t.Raw) }
        else                         { Write-Host ('  {0,-18}   无读数' -f $t.Name) }
    }

    Write-Host ("`n[电压] {0} 个传感器 (节选前 10)" -f $volts.Count)
    foreach ($v in ($volts | Sort-Object Name | Select-Object -First 10)) {
        if ($null -ne $v.Value)      { Write-Host ('  {0,-10} {1,8} {2}' -f $v.Name, $v.Value, $v.Unit) }
    }

    if ($other.Count -gt 0) {
        Write-Host ("`n[其他] {0} 个 (VBAT/机箱侵入等)" -f $other.Count)
        foreach ($o in $other) { Write-Host ('  {0,-12} 原始值 {1}' -f $o.Name, $o.Raw) }
    }

    # 完整清单落盘
    $rows | ForEach-Object {
        '{0,-18} type=0x{1:X2} {2,-12} raw={3}' -f $_.Name, $_.TypeCode, $(if ($null -ne $_.Value) { "$($_.Value) $($_.Unit)" } else { '-' }), $_.Raw
    } | Set-Content -Encoding utf8 (Join-Path $PSScriptRoot 'fan-status.txt')
    Write-Host "`n完整清单已保存: fan-status.txt"
}

# ============================================================
# 入口
# ============================================================
try {
    switch ($Command.ToLower()) {
        'status'  { Invoke-Status }
        'mode'    { Invoke-Mode $Arg1 }
        'set'     { Invoke-Set $Arg1 $Arg2 }
        'restore' { Invoke-Restore }
        default {
            Write-Host 'Fan Butler v1 (超微主板风扇管家)'
            Write-Host '用法:'
            Write-Host '  fan.ps1 status                     查看风扇/温度/电压'
            Write-Host '  fan.ps1 mode standard|optimal|full 切换风扇模式'
            Write-Host '  fan.ps1 set cpu|periph <20-100>    手动指定转速 (需 Full 模式, 自动切换)'
            Write-Host '  fan.ps1 restore                    一键恢复 BMC 自动控制'
        }
    }
} catch {
    Write-Host ('[错误] ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
