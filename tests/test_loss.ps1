. (Join-Path $PSScriptRoot 'testlib.ps1')
$ok=0;$bad=0
function Check { param([string]$W,[bool]$C,[string]$E='') if($C){$script:ok++;"  OK    $W $E"}else{$script:bad++;"  FOUT  $W $E"} }
function Fresh { param($D) if(Test-Path $D){Remove-Item -Recurse -Force $D}; New-Item -ItemType Directory -Path $D -Force|Out-Null }
function MkSrc { param($P,[int]$Vid,[double]$Aud)
  & $FFMPEG -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=$Vid" `
    -f lavfi -i "sine=frequency=440:duration=$Aud" -map 0:v -map 1:a `
    -c:v libx264 -preset ultrafast -crf 36 -c:a aac $P 2>$null | Out-Null }
function AudioEnd { param($P)
  $t = @((& $FFPROBE -v error -select_streams a:0 -show_packets -show_entries packet=pts_time -of csv=p=0 $P) |
        ForEach-Object { [double]($_ -replace ',$','') } | Sort-Object)
  if ($t.Count -lt 1) { return -1 }; return $t[-1] }
function Run { param($Dir,$Name,[int]$Dur,[double]$Margin=2.0,[double]$Limit=30.0)
  Reset-Run (Std-Settings -DeleteOrig $true -Subs $false -AudioMode 'aac' -Margin $Margin -Limit $Limit)
  Enqueue-Jobs @(New-Job -FullPath "$Dir/$Name" -Dur ([double]$Dur))
  $w = Start-W $ConvertWorker 'conv'
  while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }
  Stop-W $w | Out-Null
  $script:job = $sync.LastJob
  return @(Drain-Log) }

'############ VERLIES IN VERHOUDING: OPVULLEN OF AFKEUREN ############'
''
'--- 1. klein verlies (3 s), marge 2 / grens 30: houden en opvullen ---'
Fresh /tmp/ls/a
MkSrc '/tmp/ls/a/klein x264.mkv' 60 60
# marge 2 en grens 30, maar verlies kunstmatig afdwingen met marge -3
$log = Run /tmp/ls/a 'klein x264.mkv' 60 -3.0 30.0
$f = @(Get-ChildItem /tmp/ls/a -File | ForEach-Object Name)
Check 'GEEN VCP'                    (-not (($log -join ' ') -cmatch 'GELUID VERLOREN'))
Check 'verlies wel gemeld'          (($log -join ' ') -match 'geluid verloren aan het eind')
Check 'onder de grens gemeld'       (($log -join ' ') -match 'Onder de grens van 30 s')
Check 'bestand behouden'            (@($f | Where-Object { $_ -like '*.x265.mkv' }).Count -eq 1)
Check 'als geslaagd geteld'         ($sync.Success -eq 1)                       "(succ=$($sync.Success))"
Check 'origineel verwijderd'        (-not ($f -contains 'klein x264.mkv'))
Check 'geen VCP-hernoeming'         (@($f | Where-Object { $_ -like '*.VCP.*' }).Count -eq 0)
''
'--- 2. groot verlies: grens 0 dwingt VCP af ---'
Fresh /tmp/ls/b
MkSrc '/tmp/ls/b/groot x264.mkv' 60 60
# marge en grens beide negatief: dan valt elk verschil boven de grens
$log = Run /tmp/ls/b 'groot x264.mkv' 60 -3.0 -1.0
$f = @(Get-ChildItem /tmp/ls/b -File | ForEach-Object Name | Sort-Object)
Check 'wel VCP'                     (($log -join ' ') -cmatch 'GELUID VERLOREN')
Check 'grens gemeld'                (($log -join ' ') -match 'meer dan de grens')
Check 'resultaat weggegooid'        (@($f | Where-Object { $_ -like '*.x265.mkv' }).Count -eq 0)
Check 'bron hernoemd'               ($f -contains 'groot x264.VCP.mkv')          ("map: " + ($f -join ', '))
Check 'niet geslaagd'               ($sync.Success -eq 0)
''
'--- 3. bron zelf kort, geen verlies: opvullen, geen verliesmelding ---'
Fresh /tmp/ls/c
MkSrc '/tmp/ls/c/kortebron x264.mkv' 60 45
$log = Run /tmp/ls/c 'kortebron x264.mkv' 60
Check 'geslaagd zonder waarschuwing'($sync.Success -eq 1 -and $sync.Warned -eq 0) "(succ=$($sync.Success) warn=$($sync.Warned))"
Check 'geen verliesmelding'         (-not (($log -join ' ') -match 'geluid verloren aan het eind'))
Check 'wel opgevuld'                (($log -join ' ') -match 'Staart opgevuld')
$e = AudioEnd '/tmp/ls/c/kortebron.x265.mkv'
Check 'geluid tot het einde'        ($e -gt 55)                                  ("laatste audio {0:N1} s" -f $e)
''
'--- 4. gezonde bron: helemaal niets ---'
Fresh /tmp/ls/d
MkSrc '/tmp/ls/d/goed x264.mkv' 45 45
$log = Run /tmp/ls/d 'goed x264.mkv' 45
Check 'geslaagd'                    ($sync.Success -eq 1 -and $sync.Warned -eq 0)
Check 'geen verlies, geen opvullen' (-not (($log -join ' ') -match 'verloren|Staart opgevuld'))
Check 'meldt dat het klopt'         (($log -join ' ') -match 'Geluid loopt tot het einde')
''
"====> $ok goed, $bad fout"
