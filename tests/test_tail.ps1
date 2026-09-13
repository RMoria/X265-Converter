. (Join-Path $PSScriptRoot 'testlib.ps1')
$ok=0;$bad=0
function Check { param([string]$W,[bool]$C,[string]$E='') if($C){$script:ok++;"  OK    $W $E"}else{$script:bad++;"  FOUT  $W $E"} }
function Fresh { param($D) if(Test-Path $D){Remove-Item -Recurse -Force $D}; New-Item -ItemType Directory -Path $D -Force|Out-Null }

function MkVid { param($P,[int]$Vid,[int]$Aud=-1)
  if ($Aud -lt 0) { $Aud = $Vid }
  if ($Aud -eq 0) {
    & $FFMPEG -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=$Vid" `
      -c:v libx264 -preset ultrafast -crf 36 $P 2>$null | Out-Null
  } else {
    & $FFMPEG -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=$Vid" `
      -f lavfi -i "sine=frequency=440:duration=$Aud" -map 0:v -map 1:a `
      -c:v libx264 -preset ultrafast -crf 36 -c:a aac $P 2>$null | Out-Null
  } }

function Run { param($Dir,$Name,[int]$Dur,[bool]$Tail=$true)
  Reset-Run (Std-Settings -DeleteOrig $true -Subs $false -AudioMode 'aac' -TailCheck $Tail)
  Enqueue-Jobs @(New-Job -FullPath "$Dir/$Name" -Dur ([double]$Dur))
  $w = Start-W $ConvertWorker 'conv'
  while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }
  Stop-W $w | Out-Null
  return @(Drain-Log) }

'############ GELUIDSCONTROLE: RANDGEVALLEN ############'
''
'--- 1. controle uit: er wordt niets gemeten en niets opgevuld ---'
Fresh $WorkRoot/tl/a
MkVid "$WorkRoot/tl/a/kort x264.mkv" 60 20
$log = Run $WorkRoot/tl/a 'kort x264.mkv' 60 $false
Check 'geslaagd'                      ($sync.Success -eq 1)
Check 'origineel verwijderd'          (-not (Test-Path "$WorkRoot/tl/a/kort x264.mkv"))
Check 'bron niet gemeten'             (-not (($log -join ' ') -match 'Let op de bron'))
Check 'niet opgevuld'                 (-not (($log -join ' ') -match 'Staart opgevuld'))
Check 'geen VCP'                      (-not (($log -join ' ') -match 'GELUID VERLOREN'))
''
'--- 2. bron zonder geluidsspoor: netjes overslaan, geen VCP ---'
Fresh $WorkRoot/tl/b
MkVid "$WorkRoot/tl/b/stom x264.mkv" 40 0
$log = Run $WorkRoot/tl/b 'stom x264.mkv' 40
Check 'geslaagd'                      ($sync.Success -eq 1)                  "(warn=$($sync.Warned))"
Check 'geen waarschuwing'             ($sync.Warned -eq 0)
Check 'controle overgeslagen gemeld'  (($log -join ' ') -match 'Geluidscontrole overgeslagen|geen audiospoor')
Check 'geen VCP'                      (-not (($log -join ' ') -match 'GELUID VERLOREN'))
Check 'geen origineel meer'           (-not (Test-Path "$WorkRoot/tl/b/stom x264.mkv"))
''
'--- 3. te kort bestand om te meten: geen oordeel, geen ingreep ---'
Fresh $WorkRoot/tl/c
MkVid "$WorkRoot/tl/c/mini x264.mkv" 6 6
$log = Run $WorkRoot/tl/c 'mini x264.mkv' 6
Check 'geslaagd'                      ($sync.Success -eq 1)                  "(warn=$($sync.Warned))"
Check 'geen VCP'                      (-not (($log -join ' ') -match 'GELUID VERLOREN'))
Check 'geen noodstopteller'           ($sync.FailStreak -eq 0)
''
'--- 4. randgeval: tekort precies rond de drempel telt niet als fout ---'
Fresh $WorkRoot/tl/d
MkVid "$WorkRoot/tl/d/rand x264.mkv" 60 58     # 2 s tekort, gelijk aan de drempel
$log = Run $WorkRoot/tl/d 'rand x264.mkv' 60
Check 'geslaagd, geen waarschuwing'   ($sync.Success -eq 1 -and $sync.Warned -eq 0) "(succ=$($sync.Success) warn=$($sync.Warned))"
Check 'geen VCP'                      (-not (($log -join ' ') -match 'GELUID VERLOREN'))
''
"====> $ok goed, $bad fout"
