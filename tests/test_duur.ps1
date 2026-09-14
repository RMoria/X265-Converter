. /tmp/build/testlib.ps1
$ok=0;$bad=0
function Check { param([string]$W,[bool]$C,[string]$E='') if($C){$script:ok++;"  OK    $W $E"}else{$script:bad++;"  FOUT  $W $E"} }
function Fresh { param($D) if(Test-Path $D){Remove-Item -Recurse -Force $D}; New-Item -ItemType Directory -Path $D -Force|Out-Null }
function MkVid { param($P,[int]$Sec=8)
  & /usr/bin/ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=$Sec" `
    -f lavfi -i "sine=duration=$Sec" -map 0:v -map 1:a -c:v libx264 -preset ultrafast -crf 36 -c:a aac $P 2>$null | Out-Null }

'############ SPEELDUUR ONBEKEND ############'
''
'--- 1. Get-DurationSec haalt de duur er op drie manieren uit ---'
Fresh '/tmp/du'
MkVid '/tmp/du/gewoon.mkv' 8
& /usr/bin/ffmpeg -hide_banner -loglevel error -y -i '/tmp/du/gewoon.mkv' -c copy '/tmp/du/stroom.ts' 2>$null | Out-Null

$sb = [scriptblock]::Create(($ConvertWorker.ToString() -replace '(?s)^.*?    function Get-DurationSec', '    function Get-DurationSec' -replace '(?s)\r?\n    # -+\r?\n    #  Aantal audiokanalen.*$','') + "`n" + '
"mkv : {0:N2}" -f (Get-DurationSec "/tmp/du/gewoon.mkv")
"ts  : {0:N2}" -f (Get-DurationSec "/tmp/du/stroom.ts")
"weg : {0:N2}" -f (Get-DurationSec "/tmp/du/bestaat-niet.mkv")
"leeg: {0:N2}" -f (Get-DurationSec "")
')
$r = & $sb
$r
$t = ($r -join ' ')
Check 'mkv geeft ~8 s'           ($t -match 'mkv : 8\.\d\d')
Check 'ts geeft ~8 s'            ($t -match 'ts  : 8\.\d\d')
Check 'ontbrekend bestand -> 0'  ($t -match 'weg : 0\.00')
Check 'leeg pad -> 0'            ($t -match 'leeg: 0\.00')
''

'--- 2. de worker vult een ontbrekende duur alsnog aan ---'
Fresh '/tmp/du2'
MkVid '/tmp/du2/zonderduur.mkv' 8
Reset-Run (Std-Settings -DeleteOrig $false -Subs $false -AudioMode 'aac' -TailCheck $false)
$j = New-Job -FullPath '/tmp/du2/zonderduur.mkv' -Dur 0.0      # zoals de scan hem zou aanleveren
Check 'begint op nul'            ($j.DurationSec -eq 0)
Enqueue-Jobs @($j)
$w = Start-W $ConvertWorker 'conv'
$gezien = 0.0
while (-not $w.Handle.IsCompleted) {
    if ([double]$sync.CurDurationSec -gt $gezien) { $gezien = [double]$sync.CurDurationSec }
    Start-Sleep -Milliseconds 150
}
Stop-W $w | Out-Null
$lg = @(Drain-Log)
Check 'duur alsnog gevonden'     ($j.DurationSec -gt 7 -and $j.DurationSec -lt 9)  "($([math]::Round($j.DurationSec,2)))"
Check 'ook in de kolom gezet'    ($j.DurationText -match '^\d+:\d\d:\d\d$')        "($($j.DurationText))"
Check 'de worker gebruikt hem'   ($gezien -gt 7)                                   "($([math]::Round($gezien,2)))"
Check 'gemeld in de log'         (($lg -join ' ') -match 'Speelduur was onbekend')
Check 'conversie gewoon geslaagd' ($sync.Success -eq 1)
''

'--- 3. echt onbepaalbaar: melden en doorgaan ---'
Fresh '/tmp/du3'
MkVid '/tmp/du3/kapot.mkv' 6
Reset-Run (Std-Settings -DeleteOrig $false -Subs $false -AudioMode 'aac' -TailCheck $false)
# ffprobe naar iets wat geen duur teruggeeft, zodat alle drie de wegen leeg blijven
$echte = $sync.Ffprobe
Set-Content '/tmp/du3/nepprobe.sh' "#!/bin/sh`nexit 0`n"
chmod +x /tmp/du3/nepprobe.sh
$sync.Ffprobe = '/tmp/du3/nepprobe.sh'
$j3 = New-Job -FullPath '/tmp/du3/kapot.mkv' -Dur 0.0
Enqueue-Jobs @($j3)
$w = Start-W $ConvertWorker 'conv'
while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 150 }
Stop-W $w | Out-Null
$lg = @(Drain-Log)
$sync.Ffprobe = $echte
Check 'duur blijft nul'          ($j3.DurationSec -eq 0)
Check 'en dat wordt gemeld'      (($lg -join ' ') -match 'niet te bepalen')
Check 'toch gewoon omgezet'      ($sync.Success -eq 1 -and (Test-Path '/tmp/du3/kapot.x265.mkv'))
''

'--- 4. de balk gaat heen en weer in plaats van dood op nul ---'
$tick = (Get-Content -Raw /tmp/build/part8.ps1)
$blok = $tick.Substring($tick.IndexOf('$duurOnbekend ='))
$blok = $blok.Substring(0, 1200)
Check 'onbekende duur herkend'   ($blok -match 'CurDurationSec -le 0')
Check 'balk loopt heen en weer'  ($blok -match 'IsIndeterminate = \$duurOnbekend')
Check 'geen percentage getoond'  ($blok -match 'speelduur onbekend')
Check 'wel verwerkte tijd'       ($blok -match "verwerkt")
$n = @([regex]::Matches($tick, 'pbCurrent\.IsIndeterminate = \$false')).Count
Check 'overal netjes teruggezet' ($n -eq 3)                                        "($n plekken)"
''

'--- 5. totale voortgang en tijdsindicatie zonder speelduur ---'
# Met alle speelduren op nul is "nog te doen" nul. Zonder vangnet staat de
# bovenste balk dan vol terwijl er nog honderden bestanden wachten - precies
# wat er op het scherm van 14 september te zien was.
$tk = (Get-Content -Raw /tmp/build/part8.ps1)
Check 'bruikbaarheid wordt getoetst' ($tk -match '\$duurBruikbaar =')
Check 'balk telt dan op bestanden'   ($tk -match 'op aantal bestanden; speelduur onbekend')
Check 'tijdsindicatie ook'           ($tk -match 'tijdsindicatie op aantal bestanden')
Check 'snelheid wordt een streepje'  ($tk -match [regex]::Escape('if (-not $duurBruikbaar) { $ui.stSpeed.Text = ''-'' }'))
Check 'EtaFiles wordt gereset'       ((@([regex]::Matches((Get-Content -Raw /tmp/build/part7.ps1), 'EtaFiles')).Count) -eq 2)

# de rekensom zelf nabouwen met de cijfers van dat scherm
function OverallPct {
    param([double]$qSec,[int]$inQueue,[int]$busyOne,[int]$jobsDone,[double]$doneWork,[double]$totalWork)
    $duurBruikbaar = (($qSec -gt 0) -or ($inQueue -eq 0)) -and ($totalWork -gt 0)
    if ($duurBruikbaar) {
        $p = 100.0 * $doneWork / $totalWork
        if ($p -gt 100) { $p = 100 }
        return $p
    }
    $alle = $jobsDone + $inQueue + $busyOne
    if ($alle -gt 0) { return 100.0 * $jobsDone / $alle }
    return 0.0
}
# situatie 14 september: 1077 in de wachtrij, 1 bezig, 0 klaar, alle duren 0
$p1 = OverallPct -qSec 0 -inQueue 1077 -busyOne 1 -jobsDone 0 -doneWork 52200 -totalWork 52200
Check 'begin van de rit: ~0 %'       ($p1 -lt 0.1)                         ("$([math]::Round($p1,2)) %")
$p2 = OverallPct -qSec 0 -inQueue 539 -busyOne 1 -jobsDone 538 -doneWork 1 -totalWork 1
Check 'halverwege: ~50 %'            ($p2 -gt 49 -and $p2 -lt 51)          ("$([math]::Round($p2,1)) %")
# en met bruikbare duren blijft het gewoon zoals het was
$p3 = OverallPct -qSec 3600 -inQueue 10 -busyOne 1 -jobsDone 5 -doneWork 1200 -totalWork 4800
Check 'met duur: onveranderd 25 %'   ($p3 -gt 24.9 -and $p3 -lt 25.1)      ("$([math]::Round($p3,1)) %")
$p4 = OverallPct -qSec 0 -inQueue 0 -busyOne 0 -jobsDone 12 -doneWork 4800 -totalWork 4800
Check 'lege wachtrij: 100 %'         ($p4 -gt 99.9)                        ("$([math]::Round($p4,1)) %")
''
"====> $ok goed, $bad fout"
