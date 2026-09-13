. (Join-Path $PSScriptRoot 'testlib.ps1')
$ok=0;$bad=0
function Check { param([string]$W,[bool]$C,[string]$E='') if($C){$script:ok++;"  OK    $W $E"}else{$script:bad++;"  FOUT  $W $E"} }
function Fresh { param($D) if(Test-Path $D){Remove-Item -Recurse -Force $D}; New-Item -ItemType Directory -Path $D -Force|Out-Null }

function MkSrc { param($P,[int]$Sec=60)
  Set-Content -Path (Join-Path $WorkRoot 't2.srt') -Value "1`n00:00:02,000 --> 00:00:05,000`neen`n`n2`n00:00:45,000 --> 00:00:50,000`ntwee`n"
  & $FFMPEG -hide_banner -loglevel error -y `
    -f lavfi -i "testsrc=size=320x240:rate=25:duration=$Sec" `
    -f lavfi -i "sine=frequency=440:duration=$Sec" -i (Join-Path $WorkRoot 't2.srt') `
    -map 0:v -map 1:a -map 2:s -c:v libx264 -preset ultrafast -crf 34 -c:a aac -c:s srt $P 2>$null | Out-Null }

function Run { param($Dir,$Name,[bool]$Remux,[bool]$Auto,[int]$Dur=60)
  Reset-Run (Std-Settings -DeleteOrig $true -Subs $false -AudioMode 'aac' -Remux $Remux -RemuxAuto $Auto)
  Enqueue-Jobs @(New-Job -FullPath "$Dir/$Name" -Dur ([double]$Dur))
  $w = Start-W $ConvertWorker 'conv'
  while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }
  Stop-W $w | Out-Null
  return @(Drain-Log) }

'############ METEN IN PLAATS VAN ALTIJD REMUXEN ############'
''
'--- 1. standaard: meten, container blijkt goed, dus geen remux ---'
Fresh $WorkRoot/ilt/a
MkSrc "$WorkRoot/ilt/a/film x264.mkv" 60
$log = Run $WorkRoot/ilt/a 'film x264.mkv' $false $true 60
Check 'uitvoer bestaat'            (Test-Path "$WorkRoot/ilt/a/film.x265.mkv")
Check 'geslaagd'                   ($sync.Success -eq 1)                     "(warned=$($sync.Warned))"
Check 'er is gemeten'              (($log -join ' ') -match 'Container in orde|Container niet in orde|Interleaving niet gemeten')
Check 'gemeten: in orde'           (($log -join ' ') -match 'Container in orde')
Check 'GEEN remux uitgevoerd'      (-not (($log -join ' ') -match 'Container opnieuw opbouwen'))
Check 'vlag zit in de encode'      (($log -join ' ') -match 'max_interleave_delta 0')
''
'--- 2. FinalRemux aan: remux altijd, zonder meten ---'
Fresh $WorkRoot/ilt/b
MkSrc "$WorkRoot/ilt/b/film2 x264.mkv" 60
$log = Run $WorkRoot/ilt/b 'film2 x264.mkv' $true $true 60
Check 'uitvoer bestaat'            (Test-Path "$WorkRoot/ilt/b/film2.x265.mkv")
Check 'remux uitgevoerd'           (($log -join ' ') -match 'Container opnieuw opbouwen')
Check 'remux gelukt'               (($log -join ' ') -match 'Remux gelukt')
Check 'niet eerst gemeten'         (-not (($log -join ' ') -match 'Container in orde'))
''
'--- 3. beide uit: niets extra ---'
Fresh $WorkRoot/ilt/c
MkSrc "$WorkRoot/ilt/c/film3 x264.mkv" 60
$log = Run $WorkRoot/ilt/c 'film3 x264.mkv' $false $false 60
Check 'uitvoer bestaat'            (Test-Path "$WorkRoot/ilt/c/film3.x265.mkv")
Check 'niet gemeten'               (-not (($log -join ' ') -match 'Container in orde'))
Check 'niet geremuxt'              (-not (($log -join ' ') -match 'Container opnieuw opbouwen'))
''
'--- 4. de meting zelf: slaat een kapot bestand niet over ---'
# bestand waarvan het geluid op 20 s van 120 s ophoudt: op de latere
# meetpunten ligt er geen geluid bij het beeld
& $FFMPEG -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=120" -f lavfi -i "sine=duration=20" -map 0:v -map 1:a -c:v libx264 -preset ultrafast -crf 34 -c:a aac $WorkRoot/ilt/kort.mkv 2>$null | Out-Null
$m = & /opt/pwsh/pwsh -NoProfile -Command @"
`$sync = @{ Ffprobe = '$FFPROBE'; Cancel = `$false }
$($ConvertWorker.ToString() -replace '(?s)^.*?    function Test-Interleave', '    function Test-Interleave' -replace '(?s)\r?\n    # -+\r?\n    #  Container opnieuw opbouwen.*$','')
`$a = Test-Interleave -FilePath "$WorkRoot/ilt/kort.mkv" -DurationSec 120
`$b = Test-Interleave -FilePath "$WorkRoot/ilt/a/film.x265.mkv" -DurationSec 60
'kapot: checked={0} ok={1} bad={2}/{3}' -f `$a.Checked,`$a.Ok,`$a.Bad,`$a.Punten
'goed : checked={0} ok={1} bad={2}/{3}' -f `$b.Checked,`$b.Ok,`$b.Bad,`$b.Punten
"@
$m
Check 'kapot bestand afgekeurd'    (($m -join ' ') -match 'kapot: checked=True ok=False')
Check 'goed bestand goedgekeurd'   (($m -join ' ') -match 'goed : checked=True ok=True')
''
"====> $ok goed, $bad fout"
