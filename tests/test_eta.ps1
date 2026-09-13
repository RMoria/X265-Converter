. (Join-Path $PSScriptRoot 'testlib.ps1')
. (Join-Path $PSScriptRoot 'stub_settings.ps1')

'############ TEST ETA : nog te doen tijd na het oppakken van de bovenste ############'
$sync.Queue.Clear()
foreach ($d in 10,20,30) {
    $j = New-Object X265.FileJob
    $j.FullPath = "/x/$d.mkv"; $j.Name="$d.mkv"; $j.DurationSec = [double]$d
    $j.Queued=$true; [void]$sync.Queue.Add($j)
}
function Calc {
    $qSec = [double]0
    foreach ($qj in (Get-QueueSnapshot)) { if ($qj -ne $null) { $qSec += [double]$qj.DurationSec } }
    $rem = ([double]$sync.CurDurationSec - [double]$sync.CurVideoSec) + $qSec
    if ($rem -lt 0) { $rem = 0 }
    return @{ Q=$qSec; Rem=$rem }
}
$r = Calc; "wachtrij 10+20+30, niets bezig      -> wachtrij $($r.Q)s  resterend $($r.Rem)s   (verwacht 60 / 60)"

# werk-thread pakt de bovenste (10) en is 3 s onderweg
$q=$sync.Queue
[System.Threading.Monitor]::Enter($q.SyncRoot); try { $q.RemoveAt(0) } finally { [System.Threading.Monitor]::Exit($q.SyncRoot) }
$sync.CurDurationSec = 10; $sync.CurVideoSec = 3
$r = Calc; "10 opgepakt, 3s gedaan             -> wachtrij $($r.Q)s  resterend $($r.Rem)s   (verwacht 50 / 57)"

# gebruiker haalt 30 uit de wachtrij
[System.Threading.Monitor]::Enter($q.SyncRoot); try { $q.RemoveAt(1) } finally { [System.Threading.Monitor]::Exit($q.SyncRoot) }
$r = Calc; "30 uit de wachtrij gehaald         -> wachtrij $($r.Q)s  resterend $($r.Rem)s   (verwacht 20 / 27)"

# er komt een bestand van 40 bij
$j = New-Object X265.FileJob; $j.FullPath='/x/40.mkv'; $j.Name='40.mkv'; $j.DurationSec=40
[System.Threading.Monitor]::Enter($q.SyncRoot); try { [void]$q.Add($j) } finally { [System.Threading.Monitor]::Exit($q.SyncRoot) }
$r = Calc; "40 bijgeplaatst                    -> wachtrij $($r.Q)s  resterend $($r.Rem)s   (verwacht 60 / 67)"

# huidige is klaar
$sync.CurDurationSec = 0; $sync.CurVideoSec = 0
$r = Calc; "huidige klaar                      -> wachtrij $($r.Q)s  resterend $($r.Rem)s   (verwacht 60 / 60)"
