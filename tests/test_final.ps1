. (Join-Path $PSScriptRoot 'testlib.ps1')
$ok = 0; $bad = 0
function Check { param([string]$What,[bool]$Cond,[string]$Extra='')
  if ($Cond) { $script:ok++; "  OK    $What $Extra" } else { $script:bad++; "  FOUT  $What $Extra" } }

function Fresh { param([string]$Dir)
  if (Test-Path $Dir) { Remove-Item -Recurse -Force $Dir }
  New-Item -ItemType Directory -Path $Dir -Force | Out-Null
}
function MkVid { param([string]$Path,[int]$Sec=8,[string]$Enc='libx264')
  & $FFMPEG -hide_banner -loglevel error -f lavfi -i "testsrc=size=480x270:rate=25:duration=$Sec" -c:v $Enc -preset ultrafast -crf 32 $Path 2>$null | Out-Null
}

'############ EINDCONTROLE NA DE REVIEW-FIXES ############'
''
'--- 1. ondertitels: omnoemen bij origineel weg ---'
Fresh /tmp/e2e/f1
MkVid '/tmp/e2e/f1/een x264.mkv' 8
'a' > '/tmp/e2e/f1/een x264.srt'
'b' > '/tmp/e2e/f1/een x264.en.forced.srt'
'c' > '/tmp/e2e/f1/een x264.idx'
'd' > '/tmp/e2e/f1/een x264.sub'
'x' > '/tmp/e2e/f1/een x264b.srt'
Reset-Run (Std-Settings -DeleteOrig $true -Subs $true)
$j = New-Job -FullPath '/tmp/e2e/f1/een x264.mkv' -Dur 8.0
Enqueue-Jobs @($j)
$w = Start-W $ConvertWorker 'conv'; while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }; Stop-W $w | Out-Null
Drain-Log | Out-Null
$f1 = @(Get-ChildItem /tmp/e2e/f1 -File | ForEach-Object Name | Sort-Object)
Check 'video omgenoemd'            ($f1 -contains 'een.mkv')
Check 'srt mee'                    ($f1 -contains 'een.srt')
Check 'taalcode+vlag behouden'     ($f1 -contains 'een.en.forced.srt')
Check 'idx/sub paar mee'           (($f1 -contains 'een.idx') -and ($f1 -contains 'een.sub'))
Check 'origineel weg'              (-not ($f1 -contains 'een x264.mkv'))
Check 'oude ondertitels weg'       (-not ($f1 -contains 'een x264.srt'))
Check 'vreemde b.srt onaangeroerd' ($f1 -contains 'een x264b.srt')
''
'--- 2. ondertitels: kopieren bij origineel behouden ---'
Fresh /tmp/e2e/f2
MkVid '/tmp/e2e/f2/twee x264.mkv' 6
'a' > '/tmp/e2e/f2/twee x264.nl.srt'
Reset-Run (Std-Settings -DeleteOrig $false -Subs $true)
$j2 = New-Job -FullPath '/tmp/e2e/f2/twee x264.mkv' -Dur 6.0
Enqueue-Jobs @($j2)
$w = Start-W $ConvertWorker 'conv'; while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }; Stop-W $w | Out-Null
Drain-Log | Out-Null
$f2 = @(Get-ChildItem /tmp/e2e/f2 -File | ForEach-Object Name)
Check 'origineel blijft staan'     ($f2 -contains 'twee x264.mkv')
Check 'originele ondertitel blijft'($f2 -contains 'twee x264.nl.srt')
Check 'nieuwe video'               ($f2 -contains 'twee.mkv')
Check 'ondertitel gekopieerd'      ($f2 -contains 'twee.nl.srt')
''
'--- 3. noodstop na 3 fouten op rij, geslaagde zet teller terug ---'
Fresh /tmp/e2e/f3
'kapot' > /tmp/e2e/f3/k1.mkv
MkVid '/tmp/e2e/f3/goed_x264.mkv' 4
'kapot' > /tmp/e2e/f3/k2.mkv
'kapot' > /tmp/e2e/f3/k3.mkv
'kapot' > /tmp/e2e/f3/k4.mkv
MkVid '/tmp/e2e/f3/laatste_x264.mkv' 4
Reset-Run (Std-Settings -DeleteOrig $true -Subs $false)
$lst = @()
foreach ($n in 'k1.mkv','goed_x264.mkv','k2.mkv','k3.mkv','k4.mkv','laatste_x264.mkv') {
  $lst += (New-Job -FullPath "/tmp/e2e/f3/$n" -Dur 4.0)
}
Enqueue-Jobs $lst
$w = Start-W $ConvertWorker 'conv'; while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }; Stop-W $w | Out-Null
Drain-Log | Out-Null
Check 'noodstop geactiveerd'        ([bool]$sync.EmergencyStop)
Check 'teller op 3'                 ($sync.FailStreak -eq 3)
Check 'geslaagde zette teller terug'($sync.Success -eq 1 -and $sync.Failed -eq 4)
Check 'rest blijft in de wachtrij'  ($sync.Queue.Count -eq 1) "(wachtrij: $((($sync.Queue.ToArray())|%{$_.Name}) -join ','))"
''
'--- 4. herschikken tijdens de run: elk bestand precies een keer ---'
Fresh /tmp/e2e/f4
foreach ($i in 1..5) { MkVid "/tmp/e2e/f4/v$i`_x264.mkv" 5 }
Reset-Run (Std-Settings -DeleteOrig $true -Subs $false)
$lst4 = @(); foreach ($i in 1..5) { $lst4 += (New-Job -FullPath "/tmp/e2e/f4/v$i`_x264.mkv" -Dur 5.0) }
Enqueue-Jobs $lst4
$w = Start-W $ConvertWorker 'conv'
$sh = 0
while (-not $w.Handle.IsCompleted) {
  Start-Sleep -Milliseconds 250
  if ($sh -lt 3 -and $sync.CurPhasePct -gt 25 -and $sync.Queue.Count -ge 2) {
    $q=$sync.Queue
    [System.Threading.Monitor]::Enter($q.SyncRoot)
    try { $l=$q[$q.Count-1]; $q.RemoveAt($q.Count-1); $q.Insert(0,$l) } finally { [System.Threading.Monitor]::Exit($q.SyncRoot) }
    $sh++; Start-Sleep -Milliseconds 800
  }
}
Stop-W $w | Out-Null
Drain-Log | Out-Null
$done4 = @($lst4 | Where-Object { $_.Status -eq 'Geslaagd' })
$out4  = @(Get-ChildItem /tmp/e2e/f4 -File -Filter '*.mkv')
Check 'alle 5 geslaagd'             ($done4.Count -eq 5) "($($done4.Count))"
Check '5 uitvoerbestanden'          ($out4.Count -eq 5)  "($($out4.Count))"
Check 'geen dubbele verwerking'     ($sync.JobsDone -eq 5) "(JobsDone $($sync.JobsDone))"
Check 'wachtrij leeg'               ($sync.Queue.Count -eq 0)
Check 'werkmap opgeruimd'           (@(Get-ChildItem /tmp/x265work -Filter 'x265_*' -ErrorAction SilentlyContinue).Count -eq 0)
''
"############ {0} goed, {1} fout ############" -f $ok, $bad
