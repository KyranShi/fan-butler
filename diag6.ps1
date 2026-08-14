# diag6.ps1 - ASCII only. Blind stride scan: id = 0x0004 + k*0x43, k=0..59.
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
function GetRec16([int]$id){
  $lo=[byte]($id -band 0xFF); $hi=[byte](($id -shr 8) -band 0xFF)
  $h = Raw 0x0A 0x23 @($rl[0],$rl[1],$lo,$hi,0,7)
  if($h.CC -eq 0xC5){ $script:rl = (Raw 0x0A 0x22 @()).Data; $h = Raw 0x0A 0x23 @($rl[0],$rl[1],$lo,$hi,0,7) }
  if($h.CC -ne 0 -or $h.Data.Count -lt 7){ return $null }
  $bl = [int]$h.Data[6]
  $g = Raw 0x0A 0x23 @($rl[0],$rl[1],$lo,$hi,0,[Math]::Min(5+$bl,0xE0))
  if($g.CC -eq 0){ return $g.Data }
  return $h.Data
}
$found = 0; $miss = 0
"k id type len num stype etype raw name"
foreach($k in 0..59){
  $id = 4 + 0x43*$k
  $d = GetRec16 $id
  if($null -eq $d){ $miss++; "miss k={0} id=0x{1:X4}" -f $k,$id; continue }
  $miss = 0
  $type = [int]$d[5]; $bl = [int]$d[6]; $num = [int]$d[9]; $stype = [int]$d[14]; $etype = [int]$d[15]
  $tail = ''
  for($i=$d.Count-1; $i -ge 2 -and $d[$i] -ge 0x20 -and $d[$i] -le 0x7E; $i--){ $tail = [char]$d[$i] + $tail }
  $reading = -1
  if($type -eq 0x01 -or $type -eq 0x02){
    $sr = Raw 0x04 0x2D @([byte]$num)
    if($sr.CC -eq 0 -and $sr.Data.Count -ge 1){ $reading = [int]$sr.Data[0] }
  }
  $hex = ''
  if($d.Count -gt 2){ $hex = ($d[2..($d.Count-1)] | ForEach-Object { $_.ToString('X2') }) -join ' ' }
  "{0,2} 0x{1:X4} 0x{2:X2} {3} 0x{4:X2} 0x{5:X2} 0x{6:X2} {7,4} [{8}] | {9}" -f $k,$id,$type,$bl,$num,$stype,$etype,$reading,$tail,$hex
  $found++
  if($found -ge 53){ break }
}
"found: $found  misses: $miss"
"=== done ==="
