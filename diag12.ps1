# diag12.ps1 - ASCII only. Last manual-duty avenues: Heavy IO mode, transition window, zone probe, fw version.
$ErrorActionPreference = 'Continue'
$dev = Get-CimInstance -Namespace root\WMI -ClassName Microsoft_IPMI | Select-Object -First 1
function Raw([byte]$nf,[byte]$cmd,[byte[]]$data) {
  $a = @{ NetworkFunction=$nf; Command=$cmd; Lun=[byte]0; ResponderAddress=[byte]0x20; RequestData=$data; RequestDataSize=[uint32]$data.Length }
  $r = Invoke-CimMethod -InputObject $dev -MethodName RequestResponse -Arguments $a
  $rd=[byte[]]$r.ResponseData
  if($rd.Count -ge 2){$rd=[byte[]]($rd[1..($rd.Count-1)])}elseif($rd.Count -eq 1){$rd=[byte[]]@()}
  return [pscustomobject]@{CC=[int]$r.CompletionCode; Data=$rd}
}
function ModeGet { $m = Raw 0x30 0x45 @([byte]0x00); if($m.CC -eq 0 -and $m.Data.Count -ge 1){ return [int]$m.Data[0] }; return -1 }
function GetDuty([byte]$z){ $r = Raw 0x30 0x70 0x66 0x00 @($z); if($r.CC -eq 0 -and $r.Data.Count -ge 1){ return [int]$r.Data[0] }; return -1 }
function FanAvg {
  $vals=@()
  foreach($n in @(0x41,0x43,0x46,0x47)){
    $r = Raw 0x04 0x2D @([byte]$n)
    if($r.CC -eq 0 -and $r.Data.Count -ge 1 -and [int]$r.Data[0] -gt 0){ $vals += [int]$r.Data[0] }
  }
  if($vals.Count -eq 0){ return -1 }
  return [math]::Round(($vals | Measure-Object -Average).Average,1)
}
"=== 1. firmware version ==="
$d = Raw 0x06 0x01 @()
"GetDeviceID: $((($d.Data | Select-Object -First 6 | ForEach-Object { $_.ToString('X2') }) -join ' '))  -> fw=$($d.Data[2]).$($d.Data[3]) ipmi=$($d.Data[4]).$($d.Data[5]) manuf.id=$([int]($d.Data[6] -bor ($d.Data[7] -shl 8)))"
"=== 2. zone readback probe (z0-z3) ==="
foreach($z in 0..3){ "duty z$z = $(GetDuty ([byte]$z))" }
"=== 3. HEAVY IO mode + duty ==="
[void](Raw 0x30 0x45 @([byte]0x01,[byte]0x03))
Start-Sleep -Seconds 12
"heavy: mode=$(ModeGet) fanAvg=$(FanAvg) duty_z0=$(GetDuty 0x00) duty_z1=$(GetDuty 0x01)"
[void](Raw 0x30 0x70 0x66 0x01 @([byte]0x00,[byte]0x28))
Start-Sleep -Seconds 5
"after duty40: duty_z0=$(GetDuty 0x00) fanAvg=$(FanAvg)"
Start-Sleep -Seconds 15
"t+20s:        duty_z0=$(GetDuty 0x00) fanAvg=$(FanAvg) mode=$(ModeGet)"
"=== 4. transition window: set FULL then IMMEDIATELY duty ==="
[void](Raw 0x30 0x45 @([byte]0x01,[byte]0x01))
[void](Raw 0x30 0x70 0x66 0x01 @([byte]0x00,[byte]0x28))
foreach($i in 1..6){
  Start-Sleep -Seconds 5
  "t+$($i*5)s duty_z0=$(GetDuty 0x00) fanAvg=$(FanAvg) mode=$(ModeGet)"
}
"=== 5. restore OPTIMAL ==="
[void](Raw 0x30 0x45 @([byte]0x01,[byte]0x02))
Start-Sleep -Seconds 8
"final: mode=$(ModeGet) fanAvg=$(FanAvg) duty_z0=$(GetDuty 0x00)"
"=== done ==="
