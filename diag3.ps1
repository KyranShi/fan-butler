# diag3.ps1 - ASCII only. Chain walk with +0x100 repair; dump record hex + live reading.
$ErrorActionPreference = 'Continue'
$dev = Get-CimInstance -Namespace root\WMI -ClassName Microsoft_IPMI | Select-Object -First 1
function Raw([byte]$nf,[byte]$cmd,[byte[]]$data) {
  $a = @{ NetworkFunction=$nf; Command=$cmd; Lun=[byte]0; ResponderAddress=[byte]0x20; RequestData=$data; RequestDataSize=[uint32]$data.Length }
  $r = Invoke-CimMethod -InputObject $dev -MethodName RequestResponse -Arguments $a
  $rd=[byte[]]$r.ResponseData
  if($rd.Count -ge 2){$rd=[byte[]]($rd[1..($rd.Count-1)])}elseif($rd.Count -eq 1){$rd=[byte[]]@()}
  return [pscustomobject]@{CC=[int]$r.CompletionCode; Data=$rd}
}
function Resv { (Raw 0x0A 0x22 @()).Data }
$rl = @(Resv)
function GetRec([int]$id){
  $h = Raw 0x0A 0x23 @($rl[0],$rl[1],[byte]($id -band 0xFF),[byte](($id -shr 8) -band 0xFF),0,7)
  if($h.CC -eq 0xC5){ $script:rl = @(Resv); return GetRec $id }
  if($h.CC -ne 0 -or $h.Data.Count -lt 7){ return $null }
  $bl = [int]$h.Data[6]
  $g = Raw 0x0A 0x23 @($rl[0],$rl[1],[byte]($id -band 0xFF),[byte](($id -shr 8) -band 0xFF),0,[Math]::Min(5+$bl,0xE0))
  if($g.CC -eq 0){ return $g.Data }
  return $h.Data
}

$id = 4
$guard = 0
$seen = @{}
"bodyId recId type len num stype etype reading name hex"
while($guard -lt 150){
  $guard++
  $d = GetRec $id
  if($null -eq $d){
    # repair: try +0x100 (truncated high byte of next-ID)
    $d = GetRec ($id + 0x100)
    if($null -eq $d){
      $d = GetRec ($id + 0x43)
      if($null -eq $d){ "STOP: cannot read 0x{0:X4} (+0x100/+0x43 also failed)" -f $id; break }
      $id = $id + 0x43
    } else { $id = $id + 0x100 }
  }
  if($d.Count -lt 7){ break }
  $bodyId = [int]($d[2] -bor ($d[3] -shl 8))
  if($seen.ContainsKey($bodyId)){ "STOP: bodyId 0x{0:X4} already seen" -f $bodyId; break }
  $seen[$bodyId] = 1
  $type = [int]$d[5]; $bl = [int]$d[6]; $num = [int]$d[9]; $stype=[int]$d[14]; $etype=[int]$d[15]
  $tail = ''
  for($i=$d.Count-1; $i -ge 2 -and $d[$i] -ge 0x20 -and $d[$i] -le 0x7E; $i--){ $tail = [char]$d[$i] + $tail }
  $reading = -1
  if($type -eq 0x01 -or $type -eq 0x02){
    $sr = Raw 0x04 0x2D @([byte]$num)
    if($sr.CC -eq 0 -and $sr.Data.Count -ge 1){ $reading = [int]$sr.Data[0] }
  }
  $hex = ''
  if($d.Count -gt 2){ $hex = ($d[2..($d.Count-1)] | ForEach-Object { $_.ToString('X2') }) -join ' ' }
  "0x{0:X4} 0x{1:X4} 0x{2:X2} {3} 0x{4:X2} 0x{5:X2} 0x{6:X2} {7} [{8}] {9}" -f $bodyId,$id,$type,$bl,$num,$stype,$etype,$reading,$tail,$hex
  if($type -eq 0x00 -or $type -ge 0x11){
    # non-sensor record: no next-id known -> try +0x100 then +0x43
    $n = $id + 0x100
    $dd = GetRec $n
    if($null -eq $dd){ $n = $id + 0x43; $dd = GetRec $n; if($null -eq $dd){ "STOP after non-sensor rec" ; break } }
    $id = $n
    continue
  }
  $next = [int]($d[0] -bor ($d[1] -shl 8))
  if($next -eq 0xFFFF -or $next -eq 0){ "END of chain at 0x{0:X4}" -f $bodyId; break }
  $id = $next
}
"records: $($seen.Count)"
"=== done ==="
