. (Join-Path $PSScriptRoot 'testlib.ps1')
$ok=0;$bad=0
function Check { param([string]$W,[bool]$C,[string]$E='') if($C){$script:ok++;"  OK    $W $E"}else{$script:bad++;"  FOUT  $W $E"} }
function Fresh { param($D) if(Test-Path $D){Remove-Item -Recurse -Force $D}; New-Item -ItemType Directory -Path $D -Force|Out-Null }
function MkVid { param($P,[int]$Sec=5,[string]$V='libx264')
  & $FFMPEG -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=$Sec" `
    -f lavfi -i "sine=duration=$Sec" -map 0:v -map 1:a -c:v $V -preset ultrafast -crf 36 -c:a aac $P 2>$null | Out-Null }

# De lock-functies staan in $HelperText en zijn hier via testlib al geladen.
'############ TWEE COMPUTERS OP DEZELFDE MAP ############'
''

'--- 1. het claimen zelf ---'
Fresh '/tmp/lk'
Set-Content '/tmp/lk/film.mkv' 'x'
$a = Take-Lock -SourcePath '/tmp/lk/film.mkv' -StaleMinutes 15 -Stamp 'test 1.3'
Check 'pc A krijgt het lock'      ($a.Ok -eq $true)
Check 'lock-bestand staat er'     (Test-Path '/tmp/lk/film.mkv.x265lock')
Check 'naast de bron'             ((Get-Item '/tmp/lk/film.mkv.x265lock').DirectoryName -eq '/tmp/lk')

$b = Take-Lock -SourcePath '/tmp/lk/film.mkv' -StaleMinutes 15 -Stamp 'test 1.3'
Check 'pc B krijgt het NIET'      ($b.Ok -eq $false)
Check 'en weet dat het bezet is'  ($b.Busy -eq $true)
Check 'met naam van de eigenaar'  ($b.Owner -eq [System.Environment]::MachineName)                 "($($b.Owner))"

$inhoud = Get-Content -Raw '/tmp/lk/film.mkv.x265lock'
Check 'inhoud is leesbaar'        ($inhoud -match 'pc=' -and $inhoud -match 'bestand=film\.mkv' -and $inhoud -match 'laatst=\d{4}-\d\d-\d\dT')
Check 'versie staat erin'         ($inhoud -match 'versie=test 1\.3')

Release-Lock $a.Lock
Check 'na vrijgeven weg'          (-not (Test-Path '/tmp/lk/film.mkv.x265lock'))
$c = Take-Lock -SourcePath '/tmp/lk/film.mkv' -StaleMinutes 15
Check 'pc B kan nu wel'           ($c.Ok -eq $true)
Release-Lock $c.Lock
''

'--- 2. verweesd lock van een pc die weg is ---'
Set-Content '/tmp/lk/film.mkv.x265lock' "pc=OUDEPC`npid=999`nbestand=film.mkv`nlaatst=2020-01-01T00:00:00Z`n"
$oud = (Get-Date).AddHours(-3)
(Get-Item '/tmp/lk/film.mkv.x265lock').LastWriteTime = $oud
Check 'leeftijd wordt gezien'     ((Get-LockAge '/tmp/lk/film.mkv.x265lock') -gt 60) ("$([int](Get-LockAge '/tmp/lk/film.mkv.x265lock')) min")
$d = Take-Lock -SourcePath '/tmp/lk/film.mkv' -StaleMinutes 15 -Stamp 'test'
Check 'wordt overgenomen'         ($d.Ok -eq $true)
Check 'inhoud is nu van ons'      ((Get-Content -Raw '/tmp/lk/film.mkv.x265lock') -match ("pc=" + [regex]::Escape([System.Environment]::MachineName)))
Check 'geen .oud_-restje'         ((@(Get-ChildItem '/tmp/lk' -Filter '*.oud_*')).Count -eq 0)
Release-Lock $d.Lock
''

'--- 3. een lock dat NET nog leeft blijft met rust gelaten ---'
$e = Take-Lock -SourcePath '/tmp/lk/film.mkv' -StaleMinutes 15 -Stamp 'test'
(Get-Item '/tmp/lk/film.mkv.x265lock').LastWriteTime = (Get-Date).AddMinutes(-10)
$f = Take-Lock -SourcePath '/tmp/lk/film.mkv' -StaleMinutes 15 -Stamp 'test'
Check '10 min oud = nog levend'   ($f.Ok -eq $false -and $f.Busy -eq $true)
Check 'lock is niet vervangen'    ((Get-Content -Raw '/tmp/lk/film.mkv.x265lock') -match 'pid=')
Release-Lock $e.Lock
''

'--- 4. hartslag houdt het lock jong ---'
# Een lock kunstmatig oud maken kost twee handelingen, want Get-LockAge
# neemt bewust de JONGSTE van het tijdstempel in het bestand en dat van
# het bestand zelf. Windows werkt dat laatste voor een geopend bestand
# namelijk niet altijd bij, en over SMB al helemaal niet.
function Verouder {
    param($Lock, [double]$Minuten)
    $t = [DateTime]::UtcNow.AddMinutes(-$Minuten)
    $tekst = "pc=TESTPC`npid=1`nbestand=film.mkv`nlaatst=" + $t.ToString('yyyy-MM-ddTHH:mm:ssZ') + "`n"
    $by = [System.Text.Encoding]::UTF8.GetBytes($tekst)
    $Lock.Stream.Position = 0
    $Lock.Stream.Write($by, 0, $by.Length)
    $Lock.Stream.SetLength($by.Length)
    $Lock.Stream.Flush($true)
    (Get-Item -LiteralPath $Lock.Path).LastWriteTime = (Get-Date).AddMinutes(-$Minuten)
    $Lock.Laatst = $t
}

$g = Take-Lock -SourcePath '/tmp/lk/film.mkv' -StaleMinutes 15 -Stamp 'test'
Verouder $g.Lock 30
Check 'zonder hartslag verweesd'  ((Get-LockAge '/tmp/lk/film.mkv.x265lock') -gt 15) ("$([int](Get-LockAge '/tmp/lk/film.mkv.x265lock')) min")

# alleen het tijdstempel van het BESTAND oud is niet genoeg
Beat-Lock $g.Lock 0
(Get-Item '/tmp/lk/film.mkv.x265lock').LastWriteTime = (Get-Date).AddHours(-3)
Check 'inhoud telt ook mee'       ((Get-LockAge '/tmp/lk/film.mkv.x265lock') -lt 1)  ("$([math]::Round((Get-LockAge '/tmp/lk/film.mkv.x265lock'),2)) min")
Verouder $g.Lock 30
Beat-Lock $g.Lock 60
Check 'na de hartslag weer jong'  ((Get-LockAge '/tmp/lk/film.mkv.x265lock') -lt 1) ("$([math]::Round((Get-LockAge '/tmp/lk/film.mkv.x265lock'),2)) min")
$was = (Get-Content -Raw '/tmp/lk/film.mkv.x265lock')
Beat-Lock $g.Lock 60
Check 'hartslag houdt zich in'    ((Get-Content -Raw '/tmp/lk/film.mkv.x265lock') -eq $was)
Release-Lock $g.Lock
''

'--- 5. Test-LockFree kijkt maar claimt niet ---'
Check 'vrij als er niets ligt'    (Test-LockFree -SourcePath '/tmp/lk/film.mkv' -StaleMinutes 15)
Check 'en claimt niets'           (-not (Test-Path '/tmp/lk/film.mkv.x265lock'))
$h = Take-Lock -SourcePath '/tmp/lk/film.mkv' -StaleMinutes 15
Check 'niet vrij als het ligt'    (-not (Test-LockFree -SourcePath '/tmp/lk/film.mkv' -StaleMinutes 15))
Verouder $h.Lock 120
Check 'wel vrij als het oud is'   (Test-LockFree -SourcePath '/tmp/lk/film.mkv' -StaleMinutes 15)
Release-Lock $h.Lock
''

'--- 6. twee echte werk-threads op dezelfde map ---'
# Dit is de eigenlijke vraag: twee conversies tegelijk over dezelfde
# wachtrij, zonder dat er een bestand dubbel wordt gedaan.
Fresh '/tmp/lk2'
foreach ($n in 1..4) { MkVid "/tmp/lk2/deel $n.mkv" 4 }

function Run2 {
    param([int]$Nr)
    $s = Std-Settings -DeleteOrig $true -Subs $false -AudioMode 'aac' -TailCheck $false -Locks $true -WorkDir "/tmp/x265work$Nr"
    return $s
}

$sync.Settings = Run2 1
$sync.Queue.Clear()
$sync.JobsDone=0; $sync.Success=0; $sync.Failed=0; $sync.Warned=0
$sync.OrigBytes=[long]0; $sync.NewBytes=[long]0
$sync.DoneVideoSec=0.0; $sync.CurVideoSec=0.0; $sync.CurDurationSec=0.0
$sync.Cancel=$false; $sync.StopAfterCurrent=$false
$sync.PauseRequested=$false; $sync.IsPaused=$false
$sync.FailStreak=0; $sync.EmergencyStop=$false
$d=''; while ($sync.EmergencyFiles.TryDequeue([ref]$d)) { }

# tweede 'pc': eigen $sync in een eigen runspace, met dezelfde bestanden
$sync2 = [hashtable]::Synchronized(@{})
foreach ($k in $sync.Keys) { $sync2[$k] = $sync[$k] }
$sync2.Queue        = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$sync2.LogQueue     = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$sync2.NewJobs      = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$sync2.VerifyResults= New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$sync2.EmergencyFiles = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$sync2.Settings     = Run2 2
$sync2.JobsDone=0; $sync2.Success=0; $sync2.Failed=0; $sync2.Warned=0
$sync2.CurrentJob=$null; $sync2.CurrentProcess=$null
$sync2.Cancel=$false; $sync2.StopAfterCurrent=$false; $sync2.EmergencyStop=$false
$sync2.FailStreak=0

$paden = @(Get-ChildItem '/tmp/lk2' -Filter '*.mkv' | Sort-Object Name | Select-Object -ExpandProperty FullName)
foreach ($pad in $paden) {
    $j1 = New-Job -FullPath $pad -Dur 4.0
    $j1.Queued = $true; [void]$sync.Queue.Add($j1)
    $j2 = New-Job -FullPath $pad -Dur 4.0
    $j2.Queued = $true; [void]$sync2.Queue.Add($j2)
}

function Start-W2 {
    param([scriptblock]$Body, $S)
    $rs=[runspacefactory]::CreateRunspace(); $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync',$S)
    $i=[powershell]::Create(); $i.Runspace=$rs
    [void]$i.AddScript($HelperText + "`n" + $Body.ToString())
    $S.ConvBusy=$true
    [pscustomobject]@{ Inst=$i; Handle=$i.BeginInvoke(); RS=$rs }
}

$w1 = Start-W2 $ConvertWorker $sync
$w2 = Start-W2 $ConvertWorker $sync2
while (-not ($w1.Handle.IsCompleted -and $w2.Handle.IsCompleted)) { Start-Sleep -Milliseconds 200 }
Stop-W $w1 | Out-Null
Stop-W $w2 | Out-Null
$log1 = @(); $l=''; while ($sync.LogQueue.TryDequeue([ref]$l)) { $log1 += $l }
$log2 = @(); $l=''; while ($sync2.LogQueue.TryDequeue([ref]$l)) { $log2 += $l }

$uit = @(Get-ChildItem '/tmp/lk2' -Filter '*.x265.mkv' | Select-Object -ExpandProperty Name | Sort-Object)
$dubbel = @(Get-ChildItem '/tmp/lk2' -Filter '*.x265 (2).mkv')
$restLock = @(Get-ChildItem '/tmp/lk2' -Filter '*.x265lock')

"  pc1: $($sync.Success) geslaagd, pc2: $($sync2.Success) geslaagd"
"  uitvoer: $($uit -join ', ')"
Check 'alle vier zijn omgezet'    ($uit.Count -eq 4)                        "($($uit.Count))"
Check 'geen enkele dubbel gedaan' ($dubbel.Count -eq 0)                     "($($dubbel.Count) dubbele)"
Check 'samen precies vier'        (($sync.Success + $sync2.Success) -eq 4)  "($($sync.Success)+$($sync2.Success))"
Check 'allebei hebben gewerkt'    ($sync.Success -ge 1 -and $sync2.Success -ge 1)
Check 'geen lock achtergebleven'  ($restLock.Count -eq 0)                   "($($restLock.Count))"
Check 'geen originelen meer'      ((@(Get-ChildItem '/tmp/lk2' -Filter '*.mkv' | Where-Object { $_.Name -notlike '*.x265.mkv' })).Count -eq 0)
$samen = ($log1 + $log2) -join ' '
Check 'overslaan is gemeld'       ($samen -match 'Overgeslagen')
Check 'geen noodstop'             (-not $sync.EmergencyStop -and -not $sync2.EmergencyStop)
''

'--- 6b. de hartslag loopt via Update-Timers ---'
# De hartslag hoort niet in elke lus apart te staan maar op een plek waar
# ALLE poll-lussen langskomen. Anders is er altijd wel een lus die hem
# vergeet - en dan gaat een lock alsnog verloren bij een lange
# netwerkkopie of een pauze van een uur.
$wtekst = $ConvertWorker.ToString()
$ut = $wtekst.Substring($wtekst.IndexOf('function Update-Timers'))
$ut = $ut.Substring(0, $ut.IndexOf('function Sync-PauseState'))
Check 'hartslag zit in Update-Timers' ($ut -match 'Beat-Lock')
$aanroepen = @($wtekst -split "`r?`n" | Where-Object { $_.Trim() -like 'Beat-Lock *' })
Check 'en nergens anders'             ($aanroepen.Count -eq 1)              "($($aanroepen.Count) aanroep(en))"
foreach ($lus in @('Move-WithProgress','Wait-WhilePaused','Sleep-Interruptible','Complete-Prefetch','Invoke-Remux','Invoke-PadAudio','Invoke-Encode')) {
    $blok = $wtekst.Substring($wtekst.IndexOf("function $lus"))
    $blok = $blok.Substring(0, [Math]::Min(4000, $blok.Length))
    $eind = $blok.IndexOf("`n    function ")
    if ($eind -gt 0) { $blok = $blok.Substring(0, $eind) }
    Check "$lus klopt de hartslag"     ($blok -match 'Update-Timers')
}
''

'--- 7. de bron is inmiddels door de andere pc gedaan ---'
Fresh '/tmp/lk3'
MkVid '/tmp/lk3/blijft.mkv' 4
MkVid '/tmp/lk3/verdwijnt.mkv' 4
Reset-Run (Std-Settings -DeleteOrig $true -Subs $false -AudioMode 'aac' -TailCheck $false -Locks $true)
$jv = New-Job -FullPath '/tmp/lk3/verdwijnt.mkv' -Dur 4.0
$jb = New-Job -FullPath '/tmp/lk3/blijft.mkv'    -Dur 4.0
# de andere pc was ons voor: bron is al weg, de regel staat er nog
Remove-Item '/tmp/lk3/verdwijnt.mkv' -Force
Enqueue-Jobs @($jv, $jb)
$w = Start-W $ConvertWorker 'conv'
while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }
Stop-W $w | Out-Null
$lg = @(Drain-Log)
Check 'verdwenen bron overgeslagen' ($jv.Status -eq 'Niet gevonden')                  "($($jv.Status))"
Check 'met uitleg in de regel'      ($jv.ResultText -match 'andere pc')
Check 'gemeld in de log'            (($lg -join ' ') -match 'bron bestaat niet meer')
Check 'de rest gewoon gedaan'       ($sync.Success -eq 1 -and (Test-Path '/tmp/lk3/blijft.x265.mkv'))
Check 'telt niet als fout'          ($sync.Failed -eq 0 -and -not $sync.EmergencyStop)
''

'--- 8. de tweede ronde langs wat bezet was ---'
Fresh '/tmp/lk4'
MkVid '/tmp/lk4/eerst.mkv' 4
MkVid '/tmp/lk4/bezet.mkv' 4
# 'andere pc' houdt bezet.mkv vast
$ander = Take-Lock -SourcePath '/tmp/lk4/bezet.mkv' -StaleMinutes 15 -Stamp 'andere pc'
Check 'andere pc heeft het lock'    ($ander.Ok -eq $true)

Reset-Run (Std-Settings -DeleteOrig $true -Subs $false -AudioMode 'aac' -TailCheck $false -Locks $true)
$j1 = New-Job -FullPath '/tmp/lk4/bezet.mkv' -Dur 4.0
$j2 = New-Job -FullPath '/tmp/lk4/eerst.mkv' -Dur 4.0
Enqueue-Jobs @($j1, $j2)
$w = Start-W $ConvertWorker 'conv'

# zodra hij bezet.mkv heeft overgeslagen laten we het lock los; de
# tweede ronde hoort het dan alsnog op te pakken
$losgelaten = $false
$stop = (Get-Date).AddSeconds(90)
while (-not $w.Handle.IsCompleted -and (Get-Date) -lt $stop) {
    if (-not $losgelaten -and $j1.Status -eq 'Andere pc bezig') {
        Release-Lock $ander.Lock
        $losgelaten = $true
    }
    Start-Sleep -Milliseconds 150
}
Stop-W $w | Out-Null
$lg = @(Drain-Log)
Check 'eerst overgeslagen'          ($losgelaten)
Check 'tweede ronde aangekondigd'   (($lg -join ' ') -match 'nog een keer kijken')
Check 'alsnog omgezet'              (Test-Path '/tmp/lk4/bezet.x265.mkv')
Check 'allebei klaar'               ($sync.Success -eq 2)                             "($($sync.Success))"
Check 'geen lock achtergebleven'    ((@(Get-ChildItem '/tmp/lk4' -Filter '*.x265lock')).Count -eq 0)
''

'--- 9. de scan ruimt achtergebleven locks op ---'
Fresh '/tmp/lk5'
MkVid '/tmp/lk5/staat er nog.mkv' 4
# lock waarvan de bron nog bestaat: afblijven, die pc kan bezig zijn
Set-Content '/tmp/lk5/staat er nog.mkv.x265lock' "pc=ANDERE`nlaatst=2020-01-01T00:00:00Z`n"
(Get-Item '/tmp/lk5/staat er nog.mkv.x265lock').LastWriteTime = (Get-Date).AddHours(-5)
# lock zonder bron, oud: mag weg
Set-Content '/tmp/lk5/allang weg.mkv.x265lock' "pc=ANDERE`nlaatst=2020-01-01T00:00:00Z`n"
(Get-Item '/tmp/lk5/allang weg.mkv.x265lock').LastWriteTime = (Get-Date).AddHours(-5)
# restje van een overname
Set-Content '/tmp/lk5/rommel.mkv.x265lock.oud_deadbeef' "pc=ANDERE`nlaatst=2020-01-01T00:00:00Z`n"
(Get-Item '/tmp/lk5/rommel.mkv.x265lock.oud_deadbeef').LastWriteTime = (Get-Date).AddHours(-5)
# lock zonder bron maar vers: nog even laten liggen
Set-Content '/tmp/lk5/net begonnen.mkv.x265lock' ("pc=ANDERE`nlaatst=" + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') + "`n")

$sync.ScanSettings = @{ Folders=@('/tmp/lk5'); Extensions=@('mkv'); Recursive=$true; VcpMarker='VCP'; LockStaleMinutes=15.0 }
$sync.ScanCancel=$false; $sync.ScanTotal=0; $sync.ScanChecked=0; $sync.ScanFound=0
$sync.ScanSkippedHevc=0; $sync.ScanSkippedVcp=0; $sync.ScanSkippedNoVid=0; $sync.ScanMode='scan'
$w = Start-W $ScanWorker 'scan'
while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 150 }
Stop-W $w | Out-Null
$slog = @(Drain-Log)
$over = @(Get-ChildItem '/tmp/lk5' -Filter '*.x265lock*' | Select-Object -ExpandProperty Name | Sort-Object)
"  nog aanwezig: $($over -join ', ')"
Check 'lock met bron blijft'        ($over -contains 'staat er nog.mkv.x265lock')
Check 'vers lock blijft'            ($over -contains 'net begonnen.mkv.x265lock')
Check 'wees is weg'                 (-not ($over -contains 'allang weg.mkv.x265lock'))
Check 'oud_-restje is weg'          (-not ($over -contains 'rommel.mkv.x265lock.oud_deadbeef'))
Check 'opruimen gemeld'             (($slog -join ' ') -match 'achtergebleven lock')
Check 'lock telt niet als video'    (@(Drain-Jobs).Count -eq 1)
''
'--- 10. het lock wordt onderweg afgepakt ---'
# Het scenario: deze pc was een tijd stil (slaapstand, netwerk weg), de
# andere pc beschouwde het lock als verweesd en is zelf begonnen. Het
# resultaat van deze pc mag dan NIET over dat van de ander heen.
Fresh '/tmp/lk6'
MkVid '/tmp/lk6/gestolen.mkv' 6
Reset-Run (Std-Settings -DeleteOrig $true -Subs $false -AudioMode 'aac' -TailCheck $false -Locks $true)
$js = New-Job -FullPath '/tmp/lk6/gestolen.mkv' -Dur 6.0
Enqueue-Jobs @($js)
$w = Start-W $ConvertWorker 'conv'

# tijdens het encoderen het lock overschrijven alsof een andere pc hem
# heeft overgenomen
$gepakt = $false
$stop = (Get-Date).AddSeconds(90)
while (-not $w.Handle.IsCompleted -and (Get-Date) -lt $stop) {
    if (-not $gepakt -and (Test-Path '/tmp/lk6/gestolen.mkv.x265lock')) {
        Set-Content -LiteralPath '/tmp/lk6/gestolen.mkv.x265lock' `
            ("pc=ANDEREPC`npid=4242`nbestand=gestolen.mkv`nlaatst=" + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') + "`n")
        $gepakt = $true
    }
    Start-Sleep -Milliseconds 120
}
Stop-W $w | Out-Null
$lg = @(Drain-Log)
Check 'lock is afgepakt'            ($gepakt)
Check 'regel meldt het'             ($js.Status -eq 'Lock kwijt')                    "($($js.Status))"
Check 'met de naam van de ander'    ($js.ResultText -match 'ANDEREPC')               "($($js.ResultText))"
Check 'resultaat weggegooid'        (-not (Test-Path '/tmp/lk6/gestolen.x265.mkv'))
Check 'origineel blijft staan'      (Test-Path '/tmp/lk6/gestolen.mkv')
Check 'niet als geslaagd geteld'    ($sync.Success -eq 0)                            "($($sync.Success))"
Check 'telt NIET voor de noodstop'  ($sync.FailStreak -eq 0 -and -not $sync.EmergencyStop) "(streak=$($sync.FailStreak))"
Check 'als aandacht geteld'         ($sync.Warned -eq 1)                             "($($sync.Warned))"
Check 'gemeld in de log'            (($lg -join ' ') -match 'overgenomen door een andere pc')
Check 'werkmap leeg'                ((@(Get-ChildItem /tmp/x265work -File -EA SilentlyContinue | Where-Object { $_.Name -like 'x265_*' })).Count -eq 0)
''

'--- 11. lock kwijt maar niemand anders: gewoon doorgaan ---'
# Verdwijnt het lock-bestand zonder dat iemand het heeft overgenomen - een
# hik van de share, een opruimactie - dan hoort er niets weggegooid te
# worden. Het lock wordt gewoon opnieuw geplaatst.
Fresh '/tmp/lk7'
MkVid '/tmp/lk7/hik.mkv' 6
Reset-Run (Std-Settings -DeleteOrig $true -Subs $false -AudioMode 'aac' -TailCheck $false -Locks $true)
$jh = New-Job -FullPath '/tmp/lk7/hik.mkv' -Dur 6.0
Enqueue-Jobs @($jh)
$w = Start-W $ConvertWorker 'conv'
$weg = $false
$stop = (Get-Date).AddSeconds(90)
while (-not $w.Handle.IsCompleted -and (Get-Date) -lt $stop) {
    if (-not $weg -and (Test-Path '/tmp/lk7/hik.mkv.x265lock')) {
        Remove-Item '/tmp/lk7/hik.mkv.x265lock' -Force -EA SilentlyContinue
        $weg = $true
    }
    Start-Sleep -Milliseconds 120
}
Stop-W $w | Out-Null
Drain-Log | Out-Null
Check 'lock was verdwenen'          ($weg)
Check 'toch gewoon afgemaakt'       ($sync.Success -eq 1)                            "(succ=$($sync.Success))"
Check 'uitvoer staat er'            (Test-Path '/tmp/lk7/hik.x265.mkv')
Check 'geen lock achtergebleven'    ((@(Get-ChildItem '/tmp/lk7' -Filter '*.x265lock')).Count -eq 0)
''
'--- 12. bron met een uitvoer ernaast wordt niet nog eens gedaan ---'
# Dit is wat er op 14 september misging: pc1 zette een bestand om maar kon
# het origineel niet verwijderen ("x265 aangemaakt, origineel NIET
# verwijderd"). pc2 zag daarna een gewoon h264-bestand staan en begon
# opnieuw - met een '(2)' als resultaat.
Fresh '/tmp/lk8'
MkVid '/tmp/lk8/blijven staan.mkv' 5
& $FFMPEG -hide_banner -loglevel error -y -i '/tmp/lk8/blijven staan.mkv' `
    -c:v libx265 -preset ultrafast -crf 40 -c:a copy '/tmp/lk8/blijven staan.x265.mkv' 2>$null | Out-Null
Check 'uitvoer staat er al'         (Test-Path '/tmp/lk8/blijven staan.x265.mkv')

Reset-Run (Std-Settings -DeleteOrig $true -Subs $false -AudioMode 'aac' -TailCheck $false -Locks $true)
$ja = New-Job -FullPath '/tmp/lk8/blijven staan.mkv' -Dur 5.0
Enqueue-Jobs @($ja)
$w = Start-W $ConvertWorker 'conv'
while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 150 }
Stop-W $w | Out-Null
$lg = @(Drain-Log)
Check 'overgeslagen'                ($ja.Status -eq 'Al omgezet')                    "($($ja.Status))"
Check 'met uitleg'                  ($ja.ResultText -match 'HEVC-uitvoer')
Check 'geen (2)-bestand'            (-not (Test-Path '/tmp/lk8/blijven staan.x265 (2).mkv'))
Check 'origineel blijft staan'      (Test-Path '/tmp/lk8/blijven staan.mkv')
Check 'niet als geslaagd geteld'    ($sync.Success -eq 0)
Check 'gemeld in de log'            (($lg -join ' ') -match 'staat al een omgezet bestand')
Check 'geen lock achtergebleven'    ((@(Get-ChildItem '/tmp/lk8' -Filter '*.x265lock')).Count -eq 0)

# een half/kapot uitvoerbestand mag de bron NIET voor altijd blokkeren
Fresh '/tmp/lk9'
MkVid '/tmp/lk9/kapotte uitvoer.mkv' 5
Set-Content '/tmp/lk9/kapotte uitvoer.x265.mkv' 'dit is geen video'
Reset-Run (Std-Settings -DeleteOrig $false -Subs $false -AudioMode 'aac' -TailCheck $false -Locks $true)
$jb2 = New-Job -FullPath '/tmp/lk9/kapotte uitvoer.mkv' -Dur 5.0
Enqueue-Jobs @($jb2)
$w = Start-W $ConvertWorker 'conv'
while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 150 }
Stop-W $w | Out-Null
Drain-Log | Out-Null
Check 'kapotte uitvoer blokkeert niet' ($sync.Success -eq 1)                         "(succ=$($sync.Success))"
''

'--- 13. de lokale kopie blokkeert de andere pc niet ---'
# Zonder FileShare::Delete kan de andere pc het origineel niet weggooien
# zolang wij het aan het kopieren zijn. Dat was de oorzaak van
# "origineel NIET verwijderd".
$wt = $ConvertWorker.ToString()
$blok = $wt.Substring($wt.IndexOf('function Start-Prefetch'))
$blok = $blok.Substring(0, $blok.IndexOf('function Stop-Prefetch'))
Check 'bron wordt delend geopend'   ($blok -match 'FileShare\]::Delete')
Check 'en ook nog leesbaar/schrijf' ($blok -match 'FileShare\]::ReadWrite -bor')
# Binnen het 'bezet'-blok, dus voor de eerstvolgende 'else', moet de
# vooruit gehaalde kopie worden afgebroken.
$bezetBlok = $wt.Substring($wt.IndexOf('elseif ($poging.Busy)'))
$bezetBlok = $bezetBlok.Substring(0, $bezetBlok.IndexOf('$job.Status     = ''Andere pc bezig'''))
Check 'bezet -> kopie meteen weg'   ($bezetBlok -match 'Stop-Prefetch \$pre')          "($($bezetBlok.Length) tekens)"
''
"====> $ok goed, $bad fout"
