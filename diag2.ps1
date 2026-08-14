# diag2.ps1 - ASCII only. Sequential SDR scan bypassing broken next-ID chain.
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
$rl = @([byte]$resv[0],[byte]$resv[1])

"=== retry test: record 0x0010 ==="
for($i=1;$i -le 4;$i++){
  $h = Raw 0x0A 0x23 @($rl[0],$rl[1],0x10,0x00,0,7)
  "try $i CC=0x{0:X2} len={1}" -f $h.CC, $h.Data.Count
  Start-Sleep -Milliseconds 300
}
"=== probe candidate IDs ==="
foreach($id in @(0x0110, 0x0048, 0x0005, 0x00CE, 0x0150)){
  $h = Raw 0x0A 0x23 @($rl[0],$rl[1],[byte]($id -band 0xFF),[byte](($id -shr 8) -band 0xFF),0,7)
  "id 0x{0:X4}: CC=0x{1:X2}" -f $id, $h.CC
}
"=== sequential scan 0x0000-0x0060 ==="
$found = 0
foreach($id in 0..0x60){
  $h = Raw 0x0A 0x23 @($rl[0],$rl[1],[byte]($id -band 0xFF),[byte](($id -shr 8) -band 0xFF),0,7)
  if($h.CC -ne 0){ continue }
  if($h.Data.Count -lt 7){ continue }
  $found++
  $bl = [int]$h.Data[6]
  $g = Raw 0x0A 0x23 @($rl[0],$rl[1],[byte]($id -band 0xFF),[byte](($id -shr 8) -band 0xFF),0,[Math]::Min(5+$bl,0xE0))
  if($g.CC -ne 0){ "id 0x{0:X4}: type=0x{1:X2} hdr-ok but full CC=0x{2:X2}" -f $id,[int]$h.Data[5],$g.CC; continue }
  $d = $g.Data
  $tail = ''
  for($i=$d.Count-1; $i -ge 2 -and $d[$i] -ge 0x20 -and $d[$i] -le 0x7E; $i--){ $tail = [char]$d[$i] + $tail }
  $hex = ($d[2..($d.Count-1)] | ForEach-Object { $_.ToString('X2') }) -join ' '
  "id 0x{0:X4} type=0x{1:X2} len={2} num=0x{3:X2} stype=0x{4:X2} etype=0x{5:X2} name=[{6}] hex: {7}" -f $id,[int]$d[5],$bl,[int]$d[9],[int]$d[14],[int]$d[15],$tail,$hex
}
"total found via sequential scan: $found"
"=== done ==="
