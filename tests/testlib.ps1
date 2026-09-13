# Hulpstuk voor de tests. Laadt de onderdelen uit src/ rechtstreeks, zodat
# de tests de echte worker-code draaien en geen kopie ervan.
#
# Nodig: PowerShell 7 (pwsh) en ffmpeg/ffprobe op het PATH.
# Testbestanden worden aangemaakt onder $WorkRoot en daar weer opgeruimd.
$Repo     = Split-Path -Parent $PSScriptRoot
$FFMPEG   = (Get-Command ffmpeg  -ErrorAction Stop).Source
$FFPROBE  = (Get-Command ffprobe -ErrorAction Stop).Source
$WorkRoot = Join-Path ([IO.Path]::GetTempPath()) 'x265tests'
if (-not (Test-Path $WorkRoot)) { New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null }

# Gedeelde opzet voor de tests in deze container.
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
namespace X265 { public static class NativeProc {
    public static bool Suspend(System.IntPtr h) { return true; }
    public static bool Resume(System.IntPtr h) { return true; }
    public static void HideConsole() { } } }
'@

# echte FileJob-klasse, met een nep-Dispatcher zodat het op Linux compileert
$fj = Get-Content -Raw (Join-Path $PSScriptRoot 'cs_filejob_test.cs')
Add-Type -TypeDefinition $fj

. (Join-Path $Repo 'src/part2.ps1')
. (Join-Path $Repo 'src/part4.ps1')
. (Join-Path $Repo 'src/part5.ps1')
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
    param([bool]$DeleteOrig=$true,[bool]$Subs=$true,[string]$WorkDir=(Join-Path $WorkRoot 'werk'),[string]$AudioMode='copy',[bool]$TailCheck=$true,[bool]$Remux=$false,[bool]$RemuxAuto=$true,[bool]$Pad=$true,[double]$Margin=2.0,[double]$Limit=30.0)
    if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    return @{
        Codec='libx265'; Preset='ultrafast'; Crf=32; WorkDir=$WorkDir
        SmartRetry=$true; DeleteOriginal=$DeleteOrig; KeepDate=$true
        DeleteAttempts=2; DeleteWait=1
        HandleSubs=$Subs; SubExtensions=@('srt','sub','idx','ssa','ass','vtt','sup','txt','smi','sbv')
        MaxFailStreak=3
        AppStamp="X265 Converter 1.0 (test)"
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
