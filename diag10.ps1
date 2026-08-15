# diag10.ps1 - ASCII only. Test 0-20 duty scale hypothesis using get-duty readback.
$ErrorActionPreference = 'Continue'
$dev = Get-CimInstance -Namespace root\WMI -ClassName Microsoft_IPMI | Select-Object -First 1
function Raw([byte]$nf,[byte]$cmd,[byte[]]$data) {
  $a = @{ NetworkFunction=$nf; Command=$cmd; Lun=[byte]0; ResponderAddress=[byte]0x20; RequestData=$data; RequestDataSize=[uint32]$data.Length }
  $r = Invoke-CimMethod -InputObject $dev -MethodName RequestResponse -Arguments $a
  $rd=[byte[]]$r.ResponseData
  if($rd.Count -ge 2){$rd=[byte[]]($rd[1..($rd.Count-1)])}elseif($rd.Count -eq 1){$rd=[byte[]]@()}
  return [pscustomobject]@{CC=[int]$r.CompletionCode; Data=$rd}
}
function GetDuty([byte]$zone){ $r = Raw 0x30 0x70 0x66 0x00 @($zone); if($r.CC -eq 0 -and $r.Data.Count -ge 1){ return [int]$r.Data[0] }; return -1 }
function FanAvg {
  $vals=@()
  foreach($n in @(0x41,0x43,0x46,0x47)){
    $r = Raw 0x04 0x2D @([byte]$n)
    if($r.CC -eq 0 -and $r.Data.Count -ge 1 -and [int]$r.Data[0] -gt 0){ $vals += [int]$r.Data[0] }
  }
  if($vals.Count -eq 0){ return -1 }
  return [math]::Round(($vals | Measure-Object -Average).Average,1)
}
"=== 1. current state (Optimal expected) ==="
"fanAvg=$(FanAvg)  duty_z0=$(GetDuty 0x00)  duty_z1=$(GetDuty 0x01)"
"=== 2. set FULL, settle 15s ==="
[void](Raw 0x30 0x45 @([byte]0x01,[byte]0x01))
Start-Sleep -Seconds 15
"fanAvg=$(FanAvg)  duty_z0=$(GetDuty 0x00)  duty_z1=$(GetDuty 0x01)  (expect 20/20)"
"=== 3. set duty z0=8 (40% of 20-scale), read back ==="
[void](Raw 0x30 0x70 0x66 0x01 @([byte]0x00,[byte]0x08))
Start-Sleep -Seconds 6
"fanAvg=$(FanAvg)  duty_z0=$(GetDuty 0x00)  (expect 8, fans ~6)"
"=== 4. set duty z1=10 (50%) ==="
[void](Raw 0x30 0x70 0x66 0x01 @([byte]0x01,[byte]0x0A))
Start-Sleep -Seconds 6
"fanAvg=$(FanAvg)  duty_z1=$(GetDuty 0x01)  (expect 10)"
"=== 5. try percent-scale 0x28 readback for comparison ==="
[void](Raw 0x30 0x70 0x66 0x01 @([byte]0x00,[byte]0x28))
Start-Sleep -Seconds 6
"fanAvg=$(FanAvg)  duty_z0=$(GetDuty 0x00)"
"=== 6. persistence watch 60s ==="
foreach($i in 1..6){
  Start-Sleep -Seconds 10
  "t+$($i*10)s fanAvg=$(FanAvg) duty_z0=$(GetDuty 0x00)"
}
"=== 7. back to OPTIMAL ==="
[void](Raw 0x30 0x45 @([byte]0x01,[byte]0x02))
Start-Sleep -Seconds 8
"final fanAvg=$(FanAvg) duty_z0=$(GetDuty 0x00)"
"=== done ==="
