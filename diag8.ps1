# diag8.ps1 - ASCII only. Validate: Standard encoding, manual duty under Full, then rest at Optimal.
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
  foreach($n in @(0x41,0x43,0x46,0x47)){
    $r = Raw 0x04 0x2D @([byte]$n)
    if($r.CC -eq 0 -and $r.Data.Count -ge 1){ $out += ('F{0}={1}' -f ($n-0x40), [int]$r.Data[0]) } else { $out += ('F{0}=-' -f ($n-0x40)) }
  }
  return $out -join ' '
}
function CpuTemps {
  $out = @()
  foreach($n in @(0x01,0x02,0x0A)){
    $r = Raw 0x04 0x2D @([byte]$n)
    if($r.CC -eq 0 -and $r.Data.Count -ge 1){ $out += ('T{0:X2}={1}' -f $n, [int]$r.Data[0]) }
  }
  return $out -join ' '
}
"--- test 1: set STANDARD via 0x01 0x00 ---"
$r = Raw 0x30 0x45 @([byte]0x01,[byte]0x00)
"CC=0x{0:X2}" -f $r.CC
Start-Sleep -Seconds 3
"mode=$(ModeGet)  $(FanRaws)  $(CpuTemps)"
"--- test 2: set FULL, then duty 40% ---"
$r = Raw 0x30 0x45 @([byte]0x01,[byte]0x01)
"set-full CC=0x{0:X2}" -f $r.CC
Start-Sleep -Seconds 4
"mode=$(ModeGet)  $(FanRaws)  (expect high RPM)"
$r = Raw 0x30 0x70 0x66 0x01 @([byte]0x00,[byte]0x28)
"duty z0 40% CC=0x{0:X2}" -f $r.CC
$r = Raw 0x30 0x70 0x66 0x01 @([byte]0x01,[byte]0x28)
"duty z1 40% CC=0x{0:X2}" -f $r.CC
Start-Sleep -Seconds 6
"t+6s  mode=$(ModeGet)  $(FanRaws)"
Start-Sleep -Seconds 10
"t+16s mode=$(ModeGet)  $(FanRaws)  $(CpuTemps)"
"--- test 3: rest at OPTIMAL ---"
$r = Raw 0x30 0x45 @([byte]0x01,[byte]0x02)
"CC=0x{0:X2}" -f $r.CC
Start-Sleep -Seconds 8
"mode=$(ModeGet)  $(FanRaws)  $(CpuTemps)"
"=== done ==="
