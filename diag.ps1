# diag.ps1 - ASCII only (encoding-proof). Dumps all SDR records + probes sensor readings.
$ErrorActionPreference = 'Continue'
$dev = Get-CimInstance -Namespace root\WMI -ClassName Microsoft_IPMI | Select-Object -First 1
function Raw([byte]$nf,[byte]$cmd,[byte[]]$data) {
  $a = @{ NetworkFunction=$nf; Command=$cmd; Lun=[byte]0; ResponderAddress=[byte]0x20; RequestData=$data; RequestDataSize=[uint32]$data.Length }
  $r = Invoke-CimMethod -InputObject $dev -MethodName RequestResponse -Arguments $a
  $rd=[byte[]]$r.ResponseData
  if($rd.Count -ge 2){$rd=[byte[]]($rd[1..($rd.Count-1)])}elseif($rd.Count -eq 1){$rd=[byte[]]@()}
  return [pscustomobject]@{CC=[int]$r.CompletionCode; Data=$rd}
}
$resv = (Raw 0x0A 0x22 @()).Data
"reservation: " + (($resv | ForEach-Object { $_.ToString('X2') }) -join ' ')
$rid = 0; $guard = 0; $recCount = 0
while($guard -lt 120){
  $guard++
  $done = $false
  foreach($try in 1..2){
    $h = Raw 0x0A 0x23 @([byte]$resv[0],[byte]$resv[1],[byte]($rid -band 0xFF),[byte](($rid -shr 8) -band 0xFF),0,7)
    if($h.CC -eq 0xC5){ $resv = (Raw 0x0A 0x22 @()).Data; continue }
    break
  }
  if($h.CC -ne 0){ ("rec 0x{0:X4}: header CC=0x{1:X2} -- stop walk" -f $rid,$h.CC); break }
  $bl = [int]$h.Data[6]
  $next = ($h.Data[0] -bor ($h.Data[1] -shl 8))
  $g = Raw 0x0A 0x23 @([byte]$resv[0],[byte]$resv[1],[byte]($rid -band 0xFF),[byte](($rid -shr 8) -band 0xFF),0,[Math]::Min(5+$bl,0xE0))
  if($g.CC -ne 0){ ("rec 0x{0:X4}: full read CC=0x{1:X2}" -f $rid,$g.CC); if($next -eq 0xFFFF -or $next -eq 0){break}; $rid=$next; continue }
  $d = $g.Data
  $hi = [Math]::Min($d.Count-1, 64)
  $hex = ''
  if($d.Count -gt 2){ $hex = ($d[2..$hi] | ForEach-Object { $_.ToString('X2') }) -join ' ' }
  # printable tail = name
  $tail = ''
  for($i=$d.Count-1; $i -ge 2 -and $d[$i] -ge 0x20 -and $d[$i] -le 0x7E; $i--){ $tail = [char]$d[$i] + $tail }
  ("rec 0x{0:X4} next=0x{1:X4} type=0x{2:X2} len={3} num=0x{4:X2} stype=0x{5:X2} name=[{6}] hex:{7}" -f $rid,$next,[int]$d[5],$bl,[int]$d[9],[int]$d[14],$tail,$hex)
  $recCount++
  if($next -eq 0xFFFF -or $next -eq 0){ break }
  $rid = $next
}
"total records walked: $recCount"
"---- sensor reading probe (numbers 0x00-0x3F) ----"
foreach($n in 0..63){
  $r = Raw 0x04 0x2D @([byte]$n)
  if($r.CC -eq 0 -and $r.Data.Count -ge 2){
    ("sensor 0x{0:X2}: reading={1} flags=0x{2:X2}" -f $n,[int]$r.Data[0],[int]$r.Data[1])
  }
}
"---- done ----"
