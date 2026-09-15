# Gedeelde opzet voor de tests.
#
# Alles wordt hier uitgezocht vanaf de map waarin dit bestand staat, zodat
# de tests werken vanuit een verse clone (tests/ naast src/) EN vanuit een
# platte werkmap waarin alle bestanden door elkaar staan.
$ErrorActionPreference = 'Stop'

$TestDir = $PSScriptRoot
if (-not $TestDir) { $TestDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

# bronbestanden: eerst ../src, anders naast de tests
$SrcDir = Join-Path (Split-Path -Parent $TestDir) 'src'
if (-not (Test-Path (Join-Path $SrcDir 'part2.ps1'))) { $SrcDir = $TestDir }

# het samengestelde script: eerst de map boven tests, anders naast de tests
$AppScript = Join-Path (Split-Path -Parent $TestDir) 'X265-Converter.ps1'
if (-not (Test-Path $AppScript)) { $AppScript = Join-Path $TestDir 'X265-Converter.ps1' }

# ffmpeg van het PATH, met de gebruikelijke plek als terugval
$FFMPEG  = (Get-Command ffmpeg  -ErrorAction SilentlyContinue).Source
$FFPROBE = (Get-Command ffprobe -ErrorAction SilentlyContinue).Source
if (-not $FFMPEG)  { $FFMPEG  = '/usr/bin/ffmpeg' }
if (-not $FFPROBE) { $FFPROBE = '/usr/bin/ffprobe' }

# werkmap voor testbestanden
$WorkRoot = Join-Path ([IO.Path]::GetTempPath()) 'x265tests'
if (-not (Test-Path $WorkRoot)) { New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null }

Add-Type -TypeDefinition @'
namespace X265 { public static class NativeProc {
    public static bool Suspend(System.IntPtr h) { return true; }
    public static bool Resume(System.IntPtr h) { return true; }
    public static void HideConsole() { } } }
'@

# echte FileJob-klasse, met een nep-Dispatcher zodat het op Linux compileert
$fj = Get-Content -Raw (Join-Path $TestDir 'cs_filejob_test.cs')
Add-Type -TypeDefinition $fj

. (Join-Path $SrcDir 'part2.ps1')
. (Join-Path $SrcDir 'part4.ps1')
. (Join-Path $SrcDir 'part5.ps1')
Invoke-Expression $HelperText

$sync.Ffmpeg  = $FFMPEG
$sync.Ffprobe = $FFPROBE

function Drain-Jobs { $j=$null; while ($sync.NewJobs.TryDequeue([ref]$j)) { $j } }
function Drain-Log { $l=''; while ($sync.LogQueue.TryDequeue([ref]$l)) { $l } }

function Start-W {
    param([scriptblock]$Body, [string]$Kind)
    $rs=[runspacefactory]::CreateRunspace(); $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync',$sync)
    $i=[powershell]::Create(); $i.Runspace=$rs
    [void]$i.AddScript($HelperText + "`n" + $Body.ToString())
    if ($Kind -eq 'scan') { $sync.ScanBusy=$true } else { $sync.ConvBusy=$true }
    [pscustomobject]@{ Inst=$i; Handle=$i.BeginInvoke(); RS=$rs }
}

function Stop-W {
    param($w)
    try { $w.Inst.EndInvoke($w.Handle)|Out-Null } catch { "ENDINVOKE: $($_.Exception.Message)" }
    foreach($e in $w.Inst.Streams.Error){ "WORKER-FOUT: $e" }
    $w.Inst.Dispose(); $w.RS.Close(); $w.RS.Dispose()
}

function New-Job {
    param([string]$FullPath,[double]$Dur,[string]$Codec='h264',[bool]$Hevc=$false)
    $fi = Get-Item -LiteralPath $FullPath
    $j = New-Object X265.FileJob
    $j.FullPath    = $fi.FullName
    $j.Name        = $fi.Name
    $j.Folder      = $fi.DirectoryName
    $j.SizeBytes   = [long]$fi.Length
    $j.DurationSec = $Dur
    $j.RawCodec    = $Codec
    $j.Codec       = $Codec
    $j.IsHevc      = $Hevc
    $j.Status      = 'In wachtrij'
    return $j
}

function Probe-Dur { param([string]$p) [double](& $FFPROBE -v error -show_entries format=duration -of default=nw=1:nk=1 $p) }

function Enqueue-Jobs {
    param($JobList)
    $q = $sync.Queue
    [System.Threading.Monitor]::Enter($q.SyncRoot)
    try { foreach ($j in $JobList) { $j.Queued = $true; [void]$q.Add($j) } }
    finally { [System.Threading.Monitor]::Exit($q.SyncRoot) }
}

function Reset-Run {
    param([hashtable]$Settings)
    $sync.Settings = $Settings
    $sync.Queue.Clear()
    $sync.JobsDone=0; $sync.Success=0; $sync.Failed=0; $sync.Warned=0
    $sync.OrigBytes=[long]0; $sync.NewBytes=[long]0
    $sync.DoneVideoSec=0.0; $sync.CurVideoSec=0.0; $sync.CurDurationSec=0.0
    $sync.Cancel=$false; $sync.StopAfterCurrent=$false
    $sync.PauseRequested=$false; $sync.IsPaused=$false
    $sync.FailStreak=0; $sync.EmergencyStop=$false
    $d=''; while ($sync.EmergencyFiles.TryDequeue([ref]$d)) { }
}

function Std-Settings {
    param([bool]$DeleteOrig=$true,[bool]$Subs=$true,[string]$WorkDir='/tmp/x265work',[string]$AudioMode='copy',[bool]$TailCheck=$true,[bool]$Remux=$false,[bool]$RemuxAuto=$true,[bool]$Pad=$true,[double]$Margin=2.0,[double]$Limit=30.0,[bool]$Prefetch=$false,[bool]$PrefetchNetOnly=$true,[bool]$Locks=$false,[double]$StaleMin=15.0)
    if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    return @{
        Codec='libx265'; Preset='ultrafast'; Crf=32; WorkDir=$WorkDir
        SmartRetry=$true; DeleteOriginal=$DeleteOrig; KeepDate=$true
        DeleteAttempts=2; DeleteWait=1
        HandleSubs=$Subs; SubExtensions=@('srt','sub','idx','ssa','ass','vtt','sup','txt','smi','sbv')
        MaxFailStreak=3
        AppStamp="X265 Converter 1.2 (test)"
        PrefetchToWorkDir=$Prefetch
        PrefetchOnlyNetwork=$PrefetchNetOnly
        SharedLocks=$Locks
        LockStaleMinutes=$StaleMin
        AudioMode=$AudioMode
        FinalRemux=$Remux
        RemuxIfNeeded=$RemuxAuto
        CheckAudioTail=$TailCheck
        AudioTailTolerance=2.0
        AudioTailMargin=$Margin
        AudioLossLimit=$Limit
        PadShortAudio=$Pad
        VcpMarker='VCP'
    }
}
