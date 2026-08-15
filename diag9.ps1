# diag9.ps1 - ASCII only. Probe get-duty command; measure duty retry behavior + persistence.
$ErrorActionPreference = 'Continue'
$dev = Get-CimInstance -Namespace root\WMI -ClassName Microsoft_IPMI | Select-Object -First 1
function Raw([byte]$nf,[byte]$cmd,[byte[]]$data) {
  $a = @{ NetworkFunction=$nf; Command=$cmd; Lun=[byte]0; ResponderAddress=[byte]0x20; RequestData=$data; RequestDataSize=[uint32]$data.Length }
  $r = Invoke-CimMethod -InputObject $dev -MethodName RequestResponse -Arguments $a
  $rd=[byte[]]$r.ResponseData
  if($rd.Count -ge 2){$rd=[byte[]]($rd[1..($rd.Count-1)])}elseif($rd.Count -eq 1){$rd=[byte[]]@()}
  return [pscustomobject]@{CC=[int]$r.CompletionCode; Data=$rd}
}
function Hex($d){ if($d.Count -eq 0){return '(empty)'}; return ($d | ForEach-Object { $_.ToString('X2') }) -join ' ' }
function FanAvg {
  $vals=@()
  foreach($n in @(0x41,0x43,0x46,0x47)){
    $r = Raw 0x04 0x2D @([byte]$n)
    if($r.CC -eq 0 -and $r.Data.Count -ge 1 -and [int]$r.Data[0] -gt 0){ $vals += [int]$r.Data[0] }
  }
  if($vals.Count -eq 0){ return -1 }
  return [math]::Round(($vals | Measure-Object -Average).Average,1)
}
"=== 1. probe get-duty variants (harmless reads) ==="
foreach($v in @([byte[]]@(0x66,0x00,0x00), [byte[]]@(0x66,0x00,0x01), [byte[]]@(0x66,0x00), [byte[]]@(0x66,0x02,0x00), [byte[]]@(0x66,0x03,0x00))){
  $r = Raw 0x30 0x70 $v
  "probe [$($(Hex $v))] CC=0x{0:X2} data={1}" -f $r.CC, $(Hex $r.Data)
}
"=== 2. set FULL, settle ==="
[void](Raw 0x30 0x45 @([byte]0x01,[byte]0x01))
Start-Sleep -Seconds 15
"fanAvg=$(FanAvg)"
"=== 3. duty z0=40% retry loop (max 6) ==="
$applied = $false
foreach($i in 1..6){
  [void](Raw 0x30 0x70 0x66 0x01 @([byte]0x00,[byte]0x28))
  Start-Sleep -Seconds 6
  $avg = FanAvg
  "attempt $i : fanAvg=$avg"
  if($avg -gt 0 -and $avg -le 9){ $applied = $true; break }
}
"applied=$applied"
if($applied){
  "=== 4. z1=40% ==="
  [void](Raw 0x30 0x70 0x66 0x01 @([byte]0x01,[byte]0x28))
  Start-Sleep -Seconds 6
  "after z1: fanAvg=$(FanAvg)"
  "=== 5. persistence watch 60s ==="
  foreach($i in 1..6){
    Start-Sleep -Seconds 10
    "t+$($i*10)s fanAvg=$(FanAvg)"
  }
}
"=== 6. back to OPTIMAL ==="
[void](Raw 0x30 0x45 @([byte]0x01,[byte]0x02))
Start-Sleep -Seconds 8
"final fanAvg=$(FanAvg)"
"=== done ==="
