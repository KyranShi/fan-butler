# diag7.ps1 - ASCII only. Experiment: correct set-mode encoding (0x01 <mode>) + duty tracking.
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
function FanRaws {
  $out = @()
  foreach($n in @(0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48)){
    $r = Raw 0x04 0x2D @([byte]$n)
    if($r.CC -eq 0 -and $r.Data.Count -ge 1){ $out += ('F{0}={1}' -f ($n-0x40), [int]$r.Data[0]) } else { $out += ('F{0}=-' -f ($n-0x40)) }
  }
  return $out -join ' '
}
"t=0    mode=$(ModeGet)  $(FanRaws)"
"-- set mode OPTIMAL via 0x30 0x45 0x01 0x02 --"
$r = Raw 0x30 0x45 @([byte]0x01,[byte]0x02)
"  CC=0x{0:X2}" -f $r.CC
Start-Sleep -Seconds 2
"t+2s   mode=$(ModeGet)  $(FanRaws)"
Start-Sleep -Seconds 8
"t+10s  mode=$(ModeGet)  $(FanRaws)"
"-- set duty zone0 30% (0x30 0x70 0x66 0x01 0x00 0x1E), then poll 20s --"
$r = Raw 0x30 0x70 0x66 0x01 @([byte]0x00,[byte]0x1E)
"  CC=0x{0:X2}" -f $r.CC
$r = Raw 0x30 0x70 0x66 0x01 @([byte]0x01,[byte]0x1E)
"  zone1 CC=0x{0:X2}" -f $r.CC
foreach($i in 1..10){
  Start-Sleep -Seconds 2
  "t+$("{0:d2}" -f ($i*2))s  $(FanRaws)"
}
"final  mode=$(ModeGet)  $(FanRaws)"
"=== done ==="
