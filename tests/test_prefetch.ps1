. (Join-Path $PSScriptRoot 'testlib.ps1')
$ok=0;$bad=0
function Check { param([string]$W,[bool]$C,[string]$E='') if($C){$script:ok++;"  OK    $W $E"}else{$script:bad++;"  FOUT  $W $E"} }
function Fresh { param($D) if(Test-Path $D){Remove-Item -Recurse -Force $D}; New-Item -ItemType Directory -Path $D -Force|Out-Null }
function MkVid { param($P,[int]$Sec=8)
  & $FFMPEG -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=$Sec" `
    -f lavfi -i "sine=duration=$Sec" -map 0:v -map 1:a -c:v libx264 -preset ultrafast -crf 36 -c:a aac $P 2>$null | Out-Null }
function PreDirs { @(Get-ChildItem /tmp/x265work -Directory -Filter 'x265_pre_*' -EA SilentlyContinue) }
function Run { param($Jobs,[bool]$Prefetch=$true)
  Reset-Run (Std-Settings -DeleteOrig $false -Subs $false -AudioMode 'aac' -Prefetch $Prefetch -PrefetchNetOnly $false)
  Enqueue-Jobs $Jobs
  $w = Start-W $ConvertWorker 'conv'
  while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }
  Stop-W $w | Out-Null
  return @(Drain-Log) }

'############ BRON EERST LOKAAL ZETTEN ############'
''
'--- 1. netwerkpad herkennen ---'
$sb = [scriptblock]::Create(($ConvertWorker.ToString() -replace '(?s)^.*?    function Test-NetworkPath', '    function Test-NetworkPath' -replace '(?s)\r?\n    function Start-Prefetch.*$','') + "`n" + '
"UNC        : {0}" -f (Test-NetworkPath "\\server\share\film.mkv")
"lokaal C:  : {0}" -f (Test-NetworkPath "C:\Tools\film.mkv")
"leeg       : {0}" -f (Test-NetworkPath "")
')
$r = & $sb
$r
Check 'UNC telt als netwerk'        (($r -join ' ') -match 'UNC\s+: True')
Check 'gewoon pad niet'             (($r -join ' ') -match 'lokaal C:\s+: False')
Check 'lege string niet'            (($r -join ' ') -match 'leeg\s+: False')
''
'--- 2. een bestand: kopie wordt gemaakt en weer opgeruimd ---'
Fresh /tmp/pf/a
MkVid '/tmp/pf/a/een x264.mkv' 8
$log = Run @((New-Job -FullPath '/tmp/pf/a/een x264.mkv' -Dur 8.0))
Check 'geslaagd'                    ($sync.Success -eq 1)                    "(succ=$($sync.Success) fail=$($sync.Failed))"
Check 'kopie is gemaakt'            (($log -join ' ') -match 'Lokale kopie gestart')
Check 'en gebruikt'                 (($log -join ' ') -match 'Bron staat lokaal klaar|x265_pre_')
Check 'geen kopiemap over'          ((PreDirs).Count -eq 0)                  "($((PreDirs).Count) over)"
Check 'werkmap verder leeg'         ((@(Get-ChildItem /tmp/x265work -File -EA SilentlyContinue | Where-Object { $_.Name -like 'x265_*' })).Count -eq 0)
''
'--- 3. drie bestanden: vooruit gehaald, niet alles tegelijk ---'
Fresh /tmp/pf/b
1..3 | ForEach-Object { MkVid "/tmp/pf/b/nr$_ x264.mkv" 6 }
$jobs = @(1..3 | ForEach-Object { New-Job -FullPath "/tmp/pf/b/nr$_ x264.mkv" -Dur 6.0 })
$log = Run $jobs
Check 'alle drie geslaagd'          ($sync.Success -eq 3)                    "(succ=$($sync.Success))"
$gestart = @($log | Where-Object { $_ -match 'Lokale kopie gestart' }).Count
Check 'drie kopieen gestart'        ($gestart -eq 3)                         "(=$gestart)"
Check 'niets over in de werkmap'    ((PreDirs).Count -eq 0)                  "($((PreDirs).Count) over)"
Check 'drie uitvoerbestanden'       ((@(1..3 | Where-Object { Test-Path "/tmp/pf/b/nr$_.mkv" })).Count -eq 3)
''
'--- 4. mislukt bestand: kopie ook dan opgeruimd ---'
Fresh /tmp/pf/c
'dit is geen video' | Set-Content /tmp/pf/c/kapot.mkv
MkVid '/tmp/pf/c/goed x264.mkv' 6
$log = Run @((New-Job -FullPath '/tmp/pf/c/kapot.mkv' -Dur 6.0), (New-Job -FullPath '/tmp/pf/c/goed x264.mkv' -Dur 6.0))
Check 'een mislukt, een geslaagd'   ($sync.Failed -ge 1 -and $sync.Success -eq 1) "(fail=$($sync.Failed) succ=$($sync.Success))"
Check 'geen kopiemap over'          ((PreDirs).Count -eq 0)                  "($((PreDirs).Count) over)"
''
'--- 5. uitgeschakeld: geen kopie, wel gewoon omzetten ---'
Fresh /tmp/pf/d
MkVid '/tmp/pf/d/zonder x264.mkv' 6
$log = Run @((New-Job -FullPath '/tmp/pf/d/zonder x264.mkv' -Dur 6.0)) $false
Check 'geslaagd'                    ($sync.Success -eq 1)
Check 'geen kopie gestart'          (-not (($log -join ' ') -match 'Lokale kopie gestart'))
Check 'geen kopiemap'               ((PreDirs).Count -eq 0)
''


'--- 6. overlapt het kopieren met de lopende encode? ---'
Fresh /tmp/pf/e
1..2 | ForEach-Object { MkVid "/tmp/pf/e/f$_ x264.mkv" 10 }
$jobs = @(1..2 | ForEach-Object { New-Job -FullPath "/tmp/pf/e/f$_ x264.mkv" -Dur 10.0 })
$log = Run $jobs
# volgorde in de log: de kopie van f2 moet AL gestart zijn voordat f1 klaar is
$iStart2 = -1; $iKlaar1 = -1
for ($i=0; $i -lt $log.Count; $i++) {
    if ($iStart2 -lt 0 -and $log[$i] -match 'Lokale kopie gestart: f2') { $iStart2 = $i }
    if ($iKlaar1 -lt 0 -and $log[$i] -match 'GESLAAGD')                 { $iKlaar1 = $i }
}
"  kopie van f2 gestart op logregel $iStart2, f1 geslaagd op regel $iKlaar1"
Check 'beide regels gevonden'       ($iStart2 -ge 0 -and $iKlaar1 -ge 0)
Check 'kopie f2 start VOOR f1 klaar'($iStart2 -ge 0 -and $iKlaar1 -ge 0 -and $iStart2 -lt $iKlaar1)
Check 'beide geslaagd'              ($sync.Success -eq 2)
Check 'niets achtergebleven'        ((PreDirs).Count -eq 0)
''
"====> $ok goed, $bad fout"
