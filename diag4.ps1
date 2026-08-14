# diag4.ps1 - ASCII only. Full walk: stride +0x43, high-byte repair sweep, live readings.
$ErrorActionPreference = 'Continue'
$dev = Get-CimInstance -Namespace root\WMI -ClassName Microsoft_IPMI | Select-Object -First 1
function Raw([byte]$nf,[byte]$cmd,[byte[]]$data) {
  $a = @{ NetworkFunction=$nf; Command=$cmd; Lun=[byte]0; ResponderAddress=[byte]0x20; RequestData=$data; RequestDataSize=[uint32]$data.Length }
  $r = Invoke-CimMethod -InputObject $dev -MethodName RequestResponse -Arguments $a
  $rd=[byte[]]$r.ResponseData
  if($rd.Count -ge 2){$rd=[byte[]]($rd[1..($rd.Count-1)])}elseif($rd.Count -eq 1){$rd=[byte[]]@()}
  return [pscustomobject]@{CC=[int]$r.CompletionCode; Data=$rd}
}
$rl = (Raw 0x0A 0x22 @()).Data
function GetRec([int]$id){
  $h = Raw 0x0A 0x23 @($rl[0],$rl[1],[byte]($id -band 0xFF),[byte](($id -shr 8) -band 0xFF),0,7)
  if($h.CC -eq 0xC5){ $script:rl = (Raw 0x0A 0x22 @()).Data; $h = Raw 0x0A 0x23 @($rl[0],$rl[1],[byte]($id -band 0xFF),[byte](($id -shr 8) -band 0xFF),0,7) }
  if($h.CC -ne 0 -or $h.Data.Count -lt 7){ return $null }
  $bl = [int]$h.Data[6]
  $g = Raw 0x0A 0x23 @($rl[0],$rl[1],[byte]($id -band 0xFF),[byte](($id -shr 8) -band 0xFF),0,[Math]::Min(5+$bl,0xE0))
  if($g.CC -eq 0){ return $g.Data }
  return $h.Data
}
$id = 4
$guard = 0
$seen = @{}
"num stype etype raw name"
while($guard -lt 250){
  $guard++
  $d = GetRec $id
  $chainNext = -1
  if($null -ne $d -and $d.Count -ge 7){ $chainNext = [int]($d[0] -bor ($d[1] -shl 8)) }
  if($null -eq $d){
    $cands = @()
    if($chainNext -ge 0){ $cands += $chainNext }
    for($hb=1; $hb -le 15; $hb++){ $cands += ($id -bor ($hb -shl 8)) }
    $cands += ($id + 0x43)
    $ok = $false
    foreach($c in $cands){ $d = GetRec $c; if($null -ne $d){ $id = $c; $ok = $true; break } }
    if(-not $ok){ "STOP: cannot read 0x{0:X4} (repairs failed)" -f $id; break }
  }
  if($d.Count -lt 7){ break }
  $bodyId = [int]($d[2] -bor ($d[3] -shl 8))
  if($seen.ContainsKey($bodyId)){ "STOP: bodyId 0x{0:X4} repeat" -f $bodyId; break }
  $seen[$bodyId] = 1
  $type = [int]$d[5]; $bl = [int]$d[6]; $num = [int]$d[9]; $stype = [int]$d[14]; $etype = [int]$d[15]
  $tail = ''
  for($i=$d.Count-1; $i -ge 2 -and $d[$i] -ge 0x20 -and $d[$i] -le 0x7E; $i--){ $tail = [char]$d[$i] + $tail }
  $reading = -1; $rhex=''
  if($type -eq 0x01 -or $type -eq 0x02){
    $sr = Raw 0x04 0x2D @([byte]$num)
    if($sr.CC -eq 0 -and $sr.Data.Count -ge 1){ $reading = [int]$sr.Data[0]; if($sr.Data.Count -ge 2){ $rhex = $sr.Data[1].ToString('X2') } }
  }
  $hex=''
  if($type -eq 0x01 -or $type -eq 0x02 -or $type -eq 0x02){ $hex = ($d[2..($d.Count-1)] | ForEach-Object { $_.ToString('X2') }) -join ' ' }
  "0x{0:X2} 0x{1:X2} 0x{2:X2} {3,4} f={4} [{5}] id=0x{6:X4} t=0x{7:X2} | {8}" -f $num,$stype,$etype,$reading,$rhex,$tail,$bodyId,$type,$hex
  $next = [int]($d[0] -bor ($d[1] -shl 8))
  if($next -eq 0xFFFF -or $next -eq 0){ "END chain (next=0x{0:X4})" -f $next; break }
  # follow chain low byte, but true next = stride from bodyId
  $id = $bodyId + 0x43
}
"records: $($seen.Count)"
"=== done ==="
