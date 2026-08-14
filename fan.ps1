#Requires -Version 5.1
<#
Fan Butler — 超微主板风扇管家 (v0: 只读版)
==========================================
用途: 显示 Supermicro 主板的风扇转速与温度 (走 Windows 自带 IPMI 驱动,
      不需要安装任何软件, 不需要 BMC 账号密码)

用法:
  pwsh -NoProfile -File fan.ps1            # 显示状态
  pwsh -NoProfile -File fan.ps1 status      # 同上

背景知识:
  - BMC 是主板上的独立小电脑, 风扇归它管
  - IPMI 是和 BMC 对话的标准协议; 我们通过 Windows 系统自带的
    "Microsoft Generic IPMI Compliant Device" 驱动 (WMI: root\WMI\Microsoft_IPMI)
    直接向 BMC 发送原始命令 (raw command)
  - v0 只读不写: 只调 GetDeviceID / SDR 读取 / GetSensorReading,
    不会改变风扇任何状态, 随时可按 Ctrl+C 中断

SDR 解析备忘 (GetSDR 返回布局, 修正版):
  Data[0..1] = 下一条记录 ID
  Data[2..]  = SDR 记录本体:
    记录[0..1] ID / [2] 版本0x51 / [3] 类型 / [4] 本体长度
    记录[7]  传感器编号      → Data[9]
    记录[12] 传感器类型      → Data[14]   (0x01=温度 0x04=风扇)
    记录[13] 读数类型        → Data[15]
    —— 仅 Full 记录 (类型 0x01):
    记录[24] 单元/模拟标志   → Data[26]   (高2位: 模拟量格式)
    记录[26] 基本单位        → Data[28]   (1=°C 18=RPM)
    记录[27] 线性化          → Data[29]
    记录[28..29] M 系数      → Data[30..31] (10位有符号)
    记录[30..31] B 系数      → Data[32..33] (10位有符号)
    记录[34] Rexp/Bexp       → Data[36]   (高低各4位有符号)
    记录[48] 名字长度        → Data[50]
    记录[49..] 名字          → Data[51..]
  换算: y = (M*x + B) * 10^Rexp
#>
param([string]$Command = 'status')
$ErrorActionPreference = 'Stop'

# ============================================================
# 一、IPMI 传输层
#    自动探测: 方法名(RequestResponse/RequestResponseEx) x
#              NetFn 编码(原样/左移2位), 探测成功后缓存
# ============================================================
$script:Device      = $null
$script:Method      = $null    # 'RequestResponse' | 'RequestResponseEx'
$script:NetFnShift  = $null    # 0 = 原样传入, 2 = 左移两位
$script:Responder   = 0x20     # BMC 在 IPMB 总线上的地址, 固定 0x20

function Get-IpmiDevice {
    if ($script:Device) { return $script:Device }
    $d = Get-CimInstance -Namespace root\WMI -ClassName Microsoft_IPMI -ErrorAction Stop |
         Select-Object -First 1
    if (-not $d) { throw '找不到 root\WMI\Microsoft_IPMI 设备, 请确认系统 IPMI 驱动正常 (设备管理器中应有 Microsoft Generic IPMI Compliant Device)' }
    $script:Device = $d
    return $d
}

function Invoke-IpmiMethod {
    param([string]$M, [int]$Nf, [byte]$Cmd, [byte[]]$Data)
    if ($M -eq 'RequestResponse') {
        $a = @{ NetworkFunction = [byte]$Nf; Command = $Cmd; Lun = [byte]0
                ResponderAddress = [byte]$script:Responder
                RequestData = [byte[]]$Data; RequestDataSize = [uint32]$Data.Length }
    } else {
        $a = @{ NetworkFunction = [byte]$Nf; Command = $Cmd; Lun = [byte]0
                ResponderAddress = [byte]$script:Responder
                Data = [byte[]]$Data; DataSize = [uint32]$Data.Length
                RequestDataSize = [uint32]$Data.Length }
    }
    return Invoke-CimMethod -InputObject (Get-IpmiDevice) -MethodName $M -Arguments $a
}

# 探测通道: 先用无数据的 GetDeviceID 试四种组合,
#          再用带 1 字节数据的"读风扇模式"(0x30 0x45 0x00, 只读无害)兜底
function Initialize-IpmiTransport {
    $dev = Get-IpmiDevice
    $attempts = @()
    foreach ($m in 'RequestResponse', 'RequestResponseEx') {
        foreach ($shift in 0, 2) {
            $nf = if ($shift -eq 2) { (0x06 -shl 2) -band 0xFF } else { 0x06 }
            try {
                $r = Invoke-IpmiMethod $m $nf 0x01 @()
                $cc = [int]$r.CompletionCode
                $d  = [byte[]]$r.ResponseData
                if ($cc -eq 0 -and $d -and $d.Length -ge 4 -and $d[0] -eq 0x20) {
                    $script:Method = $m; $script:NetFnShift = $shift
                    Write-Host ("[通道] {0} / NetFn{1}" -f $m, $(if ($shift -eq 0) { '(原样)' } else { '(左移2位)' }))
                    return
                }
                $attempts += ("{0} shift={1}: CC=0x{2:X2} len={3}" -f $m, $shift, $cc, $d.Length)
            } catch { $attempts += ("{0} shift={1}: {2}" -f $m, $shift, $_.Exception.Message) }
        }
    }
    # 兜底: 带 1 字节数据的只读命令 (排除"空数组参数不兼容"的情况)
    foreach ($m in 'RequestResponse', 'RequestResponseEx') {
        foreach ($shift in 0, 2) {
            $nf = if ($shift -eq 2) { (0x30 -shl 2) -band 0xFF } else { 0x30 }
            try {
                $r = Invoke-IpmiMethod $m $nf 0x45 @([byte]0x00)
                if ([int]$r.CompletionCode -eq 0) {
                    $script:Method = $m; $script:NetFnShift = $shift
                    Write-Host ("[通道] {0} / NetFn{1} (带数据命令验证)" -f $m, $(if ($shift -eq 0) { '(原样)' } else { '(左移2位)' }))
                    return
                }
            } catch {}
        }
    }
    throw ("IPMI 通道探测失败, 全部尝试结果:`n  " + ($attempts -join "`n  "))
}

# 发送一条原始 IPMI 命令, 返回 { CompletionCode, Data }
function Invoke-IpmiRaw {
    param([byte]$NetFn, [byte]$Cmd, [byte[]]$Data = @())
    if ($null -eq $script:Method) { Initialize-IpmiTransport }
    $nf = if ($script:NetFnShift -eq 2) { ($NetFn -shl 2) -band 0xFF } else { $NetFn }
    $r = Invoke-IpmiMethod $script:Method $nf $Cmd $Data
    $rd = [byte[]]$r.ResponseData
    if (-not $rd) { $rd = [byte[]]@() }
    return [pscustomobject]@{ CompletionCode = [int]$r.CompletionCode; Data = $rd }
}

# ============================================================
# 二、传感器枚举 (SDR: Sensor Data Record 仓库)
# ============================================================

function Get-SdrReservation {
    $r = Invoke-IpmiRaw 0x0A 0x22            # Reserve SDR Repository
    if ($r.CompletionCode -ne 0 -or $r.Data.Length -lt 2) {
        throw ("预留 SDR 仓库失败 CC=0x{0:X2}" -f $r.CompletionCode)
    }
    return [int]($r.Data[0] -bor ($r.Data[1] -shl 8))
}

# 读取一条 SDR 记录: 先读 7 字节 (nextId 2 + 记录头 5) 拿本体长度,
#                  再整条读回; 预约丢失 (0xC5) 自动重预约重试
function Read-SdrRecord {
    param([ref]$Reservation, [int]$RecordId)
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $res = $Reservation.Value
        $resLo = [byte]($res -band 0xFF); $resHi = [byte](($res -shr 8) -band 0xFF)
        $idLo = [byte]($RecordId -band 0xFF); $idHi = [byte](($RecordId -shr 8) -band 0xFF)
        $h = Invoke-IpmiRaw 0x0A 0x23 @($resLo, $resHi, $idLo, $idHi, [byte]0, [byte]7)
        if ($h.CompletionCode -eq 0xC5) { $Reservation.Value = Get-SdrReservation; continue }
        if ($h.CompletionCode -ne 0 -or $h.Data.Length -lt 7) { return $null }
        $bodyLen = [int]$h.Data[6]
        $total = 5 + $bodyLen                    # 记录本体长度 (不含 nextId 前缀)
        if ($total -gt 0xE0) { $total = 0xE0 }   # 单次读取上限 224 字节
        $g = Invoke-IpmiRaw 0x0A 0x23 @($resLo, $resHi, $idLo, $idHi, [byte]0, [byte]$total)
        if ($g.CompletionCode -eq 0xC5) { $Reservation.Value = Get-SdrReservation; continue }
        if ($g.CompletionCode -ne 0) {
            # 整条读失败时退回 7 字节头, 让遍历能靠 nextId 继续
            return ,([byte[]]$h.Data)
        }
        return ,([byte[]]$g.Data)
    }
    return $null
}

# 10 位有符号整数解码 (M/B 系数的压缩格式)
function ConvertTo-Signed10 { param([int]$Lo, [int]$HiBits)
    $v = $Lo -bor ($HiBits -shl 8)
    if ($v -band 0x200) { $v -= 0x400 }
    return $v
}
function ConvertTo-SignedNibble { param([int]$Nib)
    if ($Nib -gt 7) { return $Nib - 16 } else { return $Nib }
}

# 从记录尾部回扫可打印 ASCII 串作为名字 (Supermicro 名字都是 ASCII, 长度字节=0xC0|len)
function Get-NameFromTail { param([byte[]]$d, [int]$start, [int]$endExclusive)
    $runEnd = $endExclusive
    while ($runEnd -gt $start -and $d[$runEnd-1] -ge 0x20 -and $d[$runEnd-1] -le 0x7E) { $runEnd-- }
    $runLen = $endExclusive - $runEnd
    if ($runLen -ge 2 -and $runEnd -gt $start) {
        if (($d[$runEnd-1] -band 0x3F) -eq $runLen) {
            return [Text.Encoding]::ASCII.GetString($d, $runEnd, $runLen).Trim()
        }
    }
    return $null
}

function Test-Printable { param([string]$s)
    return ($s -and ($s -replace '[\x20-\x7E]', '').Length -eq 0)
}

# 解析传感器记录 → 结构化对象
#   0x01 = Full (模拟量, 带换算系数)  0x02 = Compact (离散量)
function Parse-SensorRecord {
    param([byte[]]$d)
    if ($d.Length -lt 7) { return $null }
    $nextId  = [int]($d[0] -bor ($d[1] -shl 8))
    $recType = [int]$d[5]
    $bodyLen = [int]$d[6]
    $recEnd  = [Math]::Min($d.Length, 7 + $bodyLen)   # 记录本体在 Data 中的结束位置

    if ($recType -eq 0x01) {                                   # Full Sensor Record
        if ($d.Length -lt 51) {
            return [pscustomobject]@{ Kind = 'other'; NextId = $nextId }
        }
        $name = $null
        $idLen = $d[50] -band 0x1F
        if ($idLen -gt 0 -and (51 + $idLen) -le $recEnd) {
            $name = [Text.Encoding]::ASCII.GetString($d, 51, $idLen).Trim([char]0, ' ')
        }
        if (-not (Test-Printable $name)) { $name = Get-NameFromTail $d 7 $recEnd }
        if (-not $name) { $name = "Sensor#$($d[9])" }
        $analog = ($d[26] -shr 6) -band 3      # 0-2=模拟量格式, 3=非模拟
        return [pscustomobject]@{
            Kind = 'full'; Number = $d[9]; Name = $name
            TypeCode = $d[14]; ReadingType = $d[15]
            Analog = $analog; Unit = $d[28]
            Linearization = $d[29]
            M = (ConvertTo-Signed10 $d[30] ($d[31] -band 3))
            B = (ConvertTo-Signed10 $d[32] ($d[33] -band 3))
            Rexp = (ConvertTo-SignedNibble ($d[36] -shr 4)); Bexp = (ConvertTo-SignedNibble ($d[36] -band 0xF))
            NextId = $nextId }
    }
    if ($recType -eq 0x02) {                                   # Compact Sensor Record
        $name = Get-NameFromTail $d 7 $recEnd
        if (-not $name) { $name = "Sensor#$($d[9])" }
        return [pscustomobject]@{
            Kind = 'compact'; Number = $d[9]; Name = $name
            TypeCode = $d[14]; ReadingType = $d[15]
            Analog = 3; Unit = 0
            M = 1; B = 0; Rexp = 0; Bexp = 0; Linearization = 0
            NextId = $nextId }
    }
    return [pscustomobject]@{ Kind = 'other'; NextId = $nextId }   # 非传感器记录, 跳过
}

# 读取一个传感器的当前值, 返回 { Raw, Valid }
function Read-Sensor {
    param([byte]$Number)
    $r = Invoke-IpmiRaw 0x04 0x2D @($Number)               # Get Sensor Reading
    if ($r.CompletionCode -ne 0 -or $r.Data.Length -lt 1) { return $null }
    $valid = $true
    if ($r.Data.Length -ge 2) {
        if (($r.Data[1] -band 0x40) -or ($r.Data[1] -band 0x80)) { $valid = $false }  # 扫描关/忙
    }
    return [pscustomobject]@{ Raw = [int]$r.Data[0]; Valid = $valid }
}

# 原始字节 → 工程值: y = (M*x + B*10^Bexp) * 10^Rexp
function Convert-Reading {
    param($Sensor, [int]$Raw)
    if ($Sensor.Analog -eq 3) { return $null }
    if ($Sensor.Linearization -ne 0 -and $Sensor.Linearization -ne 0x70) { return $null }  # 非线性, 不换算
    $y = ($Sensor.M * [double]$Raw + $Sensor.B * [math]::Pow(10, $Sensor.Bexp)) * [math]::Pow(10, $Sensor.Rexp)
    return [math]::Round($y, 1)
}

function Get-UnitName { param([byte]$Unit)
    switch ($Unit) {
        1  { 'C' }   2  { 'F' }   18 { 'RPM' }  6  { 'V' }  5  { 'W' }
        7  { 'A' }   20 { 'Hz' }  default { "U$Unit" }
    }
}

# ============================================================
# 三、status: 枚举全部传感器并分组显示
# ============================================================
function Invoke-Status {
    $devid = Invoke-IpmiRaw 0x06 0x01                      # 无害的握手命令
    if ($devid.CompletionCode -ne 0) { throw ("GetDeviceID 失败 CC=0x{0:X2}" -f $devid.CompletionCode) }
    $bmcFw = try { '{0}.{1}' -f $devid.Data[3].ToString('D'), $devid.Data[2].ToString('D') } catch { '?' }

    # 查询风扇模式 (OEM 命令 0x30 0x45, 只查不改)
    $modeName = '未知'
    try {
        $m = Invoke-IpmiRaw 0x30 0x45 @([byte]0x00)
        if ($m.CompletionCode -eq 0 -and $m.Data.Length -ge 1) {
            $modeName = switch ($m.Data[0]) {
                0 { 'Standard (BMC 自动)' } 1 { 'Full (全速)' } 2 { 'Optimal (最优)' }
                3 { 'Heavy IO' } default { "代码 $($_)" }
            }
        }
    } catch { $modeName = '查询失败(不影响)' }

    Write-Host ''
    Write-Host '======== Fan Butler v0 (只读) ========' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Write-Host ("BMC 固件: {0}    风扇模式: {1}" -f $bmcFw, $modeName)
    Write-Host '-------------------------------------'

    # 枚举 SDR 仓库
    $resRef = [ref](Get-SdrReservation)
    $id = 0; $found = @(); $guard = 0
    while ($guard -lt 400) {
        $guard++
        $rec = Read-SdrRecord $resRef $id
        if (-not $rec) { break }
        $p = Parse-SensorRecord $rec
        if (-not $p) { break }
        if ($p.Kind -ne 'other') { $found += $p }
        if ($p.NextId -eq 0xFFFF -or $p.NextId -eq 0) { break }
        $id = $p.NextId
    }

    # 逐个读值
    $rows = foreach ($s in $found) {
        $rd = Read-Sensor ([byte]$s.Number)
        $val = $null; $unit = Get-UnitName $s.Unit
        if ($rd -and $rd.Valid) { $val = Convert-Reading $s $rd.Raw }
        [pscustomobject]@{ Name = $s.Name; TypeCode = $s.TypeCode; Kind = $s.Kind
                           Value = $val; Unit = $unit; Raw = $rd.Raw; Valid = ($rd -and $rd.Valid) }
    }

    # 分组显示
    $fans  = @($rows | Where-Object TypeCode -eq 0x04)
    $temps = @($rows | Where-Object TypeCode -eq 0x01)
    $other = @($rows | Where-Object { $_.TypeCode -ne 0x04 -and $_.TypeCode -ne 0x01 })

    Write-Host ("`n[风扇] 共 {0} 个传感器" -f $fans.Count)
    foreach ($f in $fans) {
        $line = '  {0,-18}' -f $f.Name
        if ($f.Valid -and $null -ne $f.Value) { $line += ('{0,8} {1}' -f $f.Value, $f.Unit) }
        elseif ($f.Valid) { $line += ('  在位 (离散值 0x{0:X2})' -f $f.Raw) }
        else { $line += '  — (无读数)' }
        Write-Host $line
    }

    Write-Host ("`n[温度] 共 {0} 个传感器" -f $temps.Count)
    foreach ($t in ($temps | Where-Object { $_.Name -notmatch 'DIMM' })) {
        $line = '  {0,-18}' -f $t.Name
        if ($t.Valid -and $null -ne $t.Value) { $line += ('{0,8} {1}' -f $t.Value, $t.Unit) }
        elseif ($t.Valid) { $line += ('  离散值 0x{0:X2}' -f $t.Raw) }
        else { $line += '  —' }
        Write-Host $line
    }
    $dimm = @($temps | Where-Object { $_.Name -match 'DIMM' -and $null -ne $_.Value })
    if ($dimm.Count -gt 0) {
        $max = $dimm | Sort-Object Value -Descending | Select-Object -First 1
        Write-Host ('  {0,-18}{1,8} C   (DIMM 共 {2} 条有读数, 最高: {3})' -f 'DIMM 汇总', $max.Value, $dimm.Count, $max.Name)
    }

    Write-Host ("`n[其他] 电压/电流等 {0} 个传感器 (完整清单见 fan-status.txt)" -f $other.Count)

    # 完整清单落盘, 便于排查
    $rows | ForEach-Object { '{0,-20} type=0x{1:X2} {2,-10} raw={3}' -f $_.Name, $_.TypeCode, $(if ($null -ne $_.Value) { "$($_.Value) $($_.Unit)" } else { '-' }), $_.Raw } |
        Set-Content -Encoding utf8 (Join-Path $PSScriptRoot 'fan-status.txt')
    Write-Host "`n完整传感器清单已保存: fan-status.txt"
}

# ============================================================
# 入口
# ============================================================
try {
    switch ($Command.ToLower()) {
        'status' { Invoke-Status }
        default {
            Write-Host 'Fan Butler v0 (只读版)'
            Write-Host '用法: pwsh -NoProfile -File fan.ps1 [status]'
        }
    }
} catch {
    Write-Host ('[错误] ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
