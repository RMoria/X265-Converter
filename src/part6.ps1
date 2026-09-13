
# ---------------------------------------------------------------------
# 10.  Runspace-beheer  (twee onafhankelijke slots: scan en conversie)
# ---------------------------------------------------------------------

$script:Slots = @{
    scan = @{ RS = $null; PS = $null; Handle = $null }
    conv = @{ RS = $null; PS = $null; Handle = $null }
}

function Start-Worker {
    param([scriptblock]$Body, [ValidateSet('scan','conv')][string]$WhichSlot)

    Clear-Slot $WhichSlot

    $entry = $script:Slots[$WhichSlot]

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)

    $inst = [powershell]::Create()
    $inst.Runspace = $rs
    [void]$inst.AddScript($HelperText + "`r`n" + $Body.ToString())

    $sync.WorkerError = $null
    if ($WhichSlot -eq 'scan') { $sync.ScanBusy = $true } else { $sync.ConvBusy = $true }

    try {
        $entry.RS     = $rs
        $entry.PS     = $inst
        $entry.Handle = $inst.BeginInvoke()
    }
    catch {
        # De vlag mag nooit blijven hangen; anders denkt de GUI voor
        # altijd dat er werk loopt.
        if ($WhichSlot -eq 'scan') { $sync.ScanBusy = $false } else { $sync.ConvBusy = $false }
        $entry.Handle = $null
        try { $inst.Dispose() } catch { }
        try { $rs.Close(); $rs.Dispose() } catch { }
        $entry.PS = $null
        $entry.RS = $null
        Write-Log "Kon de werk-thread niet starten: $($_.Exception.Message)" 'FOUT'
        throw
    }
}

function Clear-Slot {
    param([ValidateSet('scan','conv')][string]$WhichSlot)

    $entry = $script:Slots[$WhichSlot]
    if ($entry -eq $null) { return }

    if ($entry.PS -ne $null) {

        # Loopt de pijplijn nog? Netjes stoppen en kort wachten, anders
        # gaan meldingen uit de werk-thread verloren.
        if ($entry.Handle -ne $null -and -not $entry.Handle.IsCompleted) {
            try { $entry.PS.Stop() } catch { }
            try { [void]$entry.Handle.AsyncWaitHandle.WaitOne(2000) } catch { }
        }

        try {
            foreach ($e in $entry.PS.Streams.Error) {
                $sync.LogQueue.Enqueue(('[{0}] {1,-5} {2}' -f (Get-Date -Format 'HH:mm:ss'), 'FOUT', $e.ToString()))
            }
        } catch { }

        if ($entry.Handle -ne $null -and $entry.Handle.IsCompleted) {
            try { $entry.PS.EndInvoke($entry.Handle) | Out-Null }
            catch {
                # "pipeline has been stopped" is ons eigen Stop() hierboven
                if ($_.Exception.Message -notmatch 'pipeline has been stopped') {
                    try {
                        $sync.LogQueue.Enqueue(('[{0}] {1,-5} {2}' -f (Get-Date -Format 'HH:mm:ss'), 'FOUT',
                            "de werk-thread is gestopt met een fout: $($_.Exception.Message)"))
                    } catch { }
                }
            }
        }

        try {
            $reason = $entry.PS.InvocationStateInfo.Reason
            if ($reason -ne $null -and $reason.Message -notmatch 'pipeline has been stopped') {
                $sync.LogQueue.Enqueue(('[{0}] {1,-5} {2}' -f (Get-Date -Format 'HH:mm:ss'), 'FOUT',
                    "werk-thread beeindigd: $($reason.Message)"))
            }
        } catch { }

        try { $entry.PS.Dispose() } catch { }
        $entry.PS     = $null
        $entry.Handle = $null
    }

    if ($entry.RS -ne $null) {
        try { $entry.RS.Close(); $entry.RS.Dispose() } catch { }
        $entry.RS = $null
    }
}

function Clear-AllSlots {
    Clear-Slot 'scan'
    Clear-Slot 'conv'
}

# ---------------------------------------------------------------------
# 11.  Instellingen, wachtrij en totalen opslaan / laden
#
#      Alles gaat in hetzelfde bestand naast het script. Er is precies
#      één schrijver (de GUI-thread) en er wordt atomisch geschreven:
#      eerst naar een .tmp, dan vervangen. Een beschadigd of oud bestand
#      mag het programma nooit laten struikelen.
# ---------------------------------------------------------------------

$script:SaveDirty    = $false
$script:LastSaveTime = [DateTime]::MinValue

function Request-Save {
    $script:SaveDirty = $true
}

function Get-QueueSnapshot {
    # Kopie van de wachtrij (alleen de GUI-thread leest dit uit voor
    # opslaan en hernummeren).
    $out = @()
    $q = $sync.Queue
    [System.Threading.Monitor]::Enter($q.SyncRoot)
    try { $out = @($q.ToArray()) }
    finally { [System.Threading.Monitor]::Exit($q.SyncRoot) }
    return $out
}

function Save-Settings {
    param([switch]$Force)

    try {
        # ---- wachtrijposities bepalen ------------------------------
        $pos = @{}
        $i = 0
        foreach ($j in (Get-QueueSnapshot)) {
            if ($j -ne $null) { $i++; $pos[[string]$j.FullPath] = $i }
        }

        $rows = New-Object System.Collections.ArrayList
        foreach ($j in $jobs) {
            $p = 0
            if ($pos.ContainsKey([string]$j.FullPath)) { $p = [int]$pos[[string]$j.FullPath] }
            [void]$rows.Add([pscustomobject]@{
                FullPath    = [string]$j.FullPath
                Name        = [string]$j.Name
                Folder      = [string]$j.Folder
                SizeBytes   = [long]$j.SizeBytes
                DurationSec = [double]$j.DurationSec
                Codec       = [string]$j.RawCodec
                IsHevc      = [bool]$j.IsHevc
                Include     = [bool]$j.Include
                Status      = [string]$j.Status
                ResultText  = [string]$j.ResultText
                QueuePos    = $p
            })
        }

        $t = $sync.Totals
        $totals = $null
        [System.Threading.Monitor]::Enter($t.SyncRoot)
        try {
            $totals = [pscustomobject]@{
                Files     = [int]$t.Files
                OrigBytes = [long]$t.OrigBytes
                NewBytes  = [long]$t.NewBytes
                ActiveSec = [double]$t.ActiveSec
                VideoSec  = [double]$t.VideoSec
                FirstUsed = [string]$t.FirstUsed
                LastUsed  = [string]$t.LastUsed
            }
        }
        finally { [System.Threading.Monitor]::Exit($t.SyncRoot) }

        $obj = [pscustomobject]@{
            Version       = $AppVersion
            VersionDate   = $AppDate
            Folders       = @($ui.lstFolders.Items | ForEach-Object { [string]$_ })
            CodecIndex    = $ui.cmbCodec.SelectedIndex
            Preset        = [string]$ui.cmbPreset.SelectedItem
            Crf           = [int]$ui.sldCrf.Value
            Extensions    = $ui.txtExt.Text
            AudioMode     = (Get-AudioMode)
            WorkDir       = $ui.txtWork.Text
            Recursive     = [bool]$script:Recursive
            DeleteOrig    = [bool]$ui.chkDeleteOrig.IsChecked
            KeepDate      = [bool]$script:KeepDate
            HandleSubs    = [bool]$ui.chkSubs.IsChecked
            SmartRetry    = [bool]$script:SmartRetry
            ExitAfterStop = [bool]$ui.chkExitAfter.IsChecked
            SubExtensions = @($script:SubExtensions)
            MaxFailStreak = [int]$script:MaxFailStreak
            KeepAwakeSignal = [string]$script:KeepAwakeSignal
            PrefetchToWorkDir   = [bool]$script:PrefetchToWorkDir
            PrefetchOnlyNetwork = [bool]$script:PrefetchOnlyNetwork
            SharedLocks         = [bool]$script:SharedLocks
            LockStaleMinutes    = [double]$script:LockStaleMinutes
            FinalRemux         = [bool]$script:FinalRemux
            RemuxIfNeeded      = [bool]$script:RemuxIfNeeded
            CheckAudioTail     = [bool]$script:CheckAudioTail
            AudioTailTolerance = [double]$script:AudioTailTolerance
            AudioTailMargin    = [double]$script:AudioTailMargin
            AudioLossLimit     = [double]$script:AudioLossLimit
            PadShortAudio      = [bool]$script:PadShortAudio
            VcpMarker          = [string]$script:VcpMarker
            RestoreQueue  = [bool]$script:RestoreQueue
            Window        = (Get-WindowPlacement)
            Totals        = $totals
            Queue         = $(if ($script:RestoreQueue) { @($rows.ToArray()) } else { @() })
        }

        $json = $obj | ConvertTo-Json -Depth 6

        $tmp = $SettingsFile + '.tmp'
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -Force
        if (Test-PathSafe $SettingsFile) {
            Remove-Item -LiteralPath $SettingsFile -Force -ErrorAction SilentlyContinue
        }
        Move-Item -LiteralPath $tmp -Destination $SettingsFile -Force

        $script:SaveDirty    = $false
        $script:LastSaveTime = Get-Date
    }
    catch {
        # Opslaan mag nooit iets tegenhouden.
        try { Write-Log "Instellingen opslaan mislukte: $($_.Exception.Message)" 'WAARS' } catch { }
    }
}

function Load-Settings {
    if (-not (Test-PathSafe $SettingsFile)) { return $null }
    try { return (Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch {
        try { Write-Log 'Het instellingenbestand is onleesbaar; er wordt met een lege lijst gestart.' 'WAARS' } catch { }
        return $null
    }
}

# ---------------------------------------------------------------------
# 12.  ffmpeg controleren / ophalen
# ---------------------------------------------------------------------

function Test-Ffmpeg {
    return ((Test-PathSafe $FfmpegExe) -and (Test-PathSafe $FfprobeExe))
}

function Resolve-Ffmpeg {

    if (Test-Ffmpeg) {
        $sync.Ffmpeg  = $FfmpegExe
        $sync.Ffprobe = $FfprobeExe
        return $true
    }

    # in PATH?
    $inPath  = Get-Command ffmpeg.exe  -ErrorAction SilentlyContinue
    $inPath2 = Get-Command ffprobe.exe -ErrorAction SilentlyContinue
    if ($inPath -and $inPath2) {
        $sync.Ffmpeg  = $inPath.Source
        $sync.Ffprobe = $inPath2.Source
        Write-Log "ffmpeg gevonden in PATH: $($inPath.Source)"
        return $true
    }

    $answer = [System.Windows.MessageBox]::Show(
        "ffmpeg en ffprobe zijn niet gevonden in:`n`n$FfmpegDir\bin`n`nWil je de nieuwste release nu downloaden? (ongeveer 90 MB)",
        'ffmpeg ontbreekt', 'YesNo', 'Question')

    if ($answer -ne 'Yes') { return $false }

    try {
        $ui.txtStatus.Text = 'ffmpeg downloaden…'

        if (-not (Test-PathSafe $FfmpegDir)) { New-Item -ItemType Directory -Path $FfmpegDir -Force | Out-Null }

        $zip = Join-Path $env:TEMP 'ffmpeg_essentials.zip'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $prev = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' -OutFile $zip -UseBasicParsing
        $ProgressPreference = $prev

        $ui.txtStatus.Text = 'ffmpeg uitpakken…'
        Expand-Archive -LiteralPath $zip -DestinationPath $FfmpegDir -Force
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

        if (-not (Test-Ffmpeg)) {
            $sub = Get-ChildItem -LiteralPath $FfmpegDir -Directory -Filter 'ffmpeg-*' -ErrorAction SilentlyContinue |
                   Where-Object { Test-PathSafe (Join-Path $_.FullName 'bin\ffmpeg.exe') } | Select-Object -First 1
            if ($sub) {
                Copy-Item -Path (Join-Path $sub.FullName '*') -Destination $FfmpegDir -Recurse -Force
                Remove-Item -LiteralPath $sub.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        if (Test-Ffmpeg) {
            $sync.Ffmpeg  = $FfmpegExe
            $sync.Ffprobe = $FfprobeExe
            Write-Log 'ffmpeg succesvol gedownload en uitgepakt.'
            return $true
        }
    }
    catch {
        [System.Windows.MessageBox]::Show("Downloaden mislukt:`n`n$($_.Exception.Message)", 'Fout', 'OK', 'Error') | Out-Null
    }
    return $false
}

# ---------------------------------------------------------------------
# 13.  Bronmappen
# ---------------------------------------------------------------------

function Show-FolderPicker {

    $start = ''
    if ($ui.lstFolders.SelectedItem) { $start = [string]$ui.lstFolders.SelectedItem }
    elseif ($ui.lstFolders.Items.Count -gt 0) { $start = [string]$ui.lstFolders.Items[$ui.lstFolders.Items.Count - 1] }
    elseif ($ScriptDir) { $start = $ScriptDir }

    # moderne Explorer-dialoog: adresbalk, netwerklocaties, meerdere
    # mappen tegelijk. Valt terug op de klassieke boomstructuur wanneer
    # de COM-dialoog niet beschikbaar is.
    try {
        $owner = [IntPtr]::Zero
        try { $owner = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle } catch { }

        $picked = [X265.FolderPicker]::Pick(
            $owner,
            'Kies een of meer bronmappen  -  typ of plak desnoods een UNC-pad in de adresbalk',
            $start,
            $true)

        if ($picked -and $picked.Count -gt 0) {
            foreach ($p in $picked) { Add-Folder $p }
            return
        }
        return
    }
    catch {
        Write-Log "Moderne mapkiezer niet beschikbaar ($($_.Exception.Message)); klassieke dialoog gebruikt." 'WAARS'
    }

    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description         = 'Kies een bronmap'
    $dlg.ShowNewFolderButton = $false
    if ($start) { try { $dlg.SelectedPath = $start } catch { } }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Add-Folder $dlg.SelectedPath }
    $dlg.Dispose()
}

function Add-Folder {
    param([string]$FolderPath)

    if ([string]::IsNullOrWhiteSpace($FolderPath)) { return }

    $p = $FolderPath.Trim().Trim('"')
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\') }

    if (-not (Test-PathSafe $p -Container)) {
        [System.Windows.MessageBox]::Show("Deze map is niet bereikbaar:`n`n$p", 'Map niet gevonden', 'OK', 'Warning') | Out-Null
        return
    }

    foreach ($item in $ui.lstFolders.Items) {
        if ([string]$item -eq $p) { return }
    }
    [void]$ui.lstFolders.Items.Add($p)
    $ui.txtStatus.Text = "Map toegevoegd: $p"
}

# ---------------------------------------------------------------------
# 14.  GUI opbouwen
# ---------------------------------------------------------------------

$jobs = New-Object 'System.Collections.ObjectModel.ObservableCollection[X265.FileJob]'
$ui.grid.ItemsSource = $jobs

foreach ($k in ($CodecMap.Keys | Sort-Object)) { [void]$ui.cmbCodec.Items.Add($k) }
$ui.cmbCodec.SelectedItem = 'libx265 (CPU / x265)'

foreach ($k in $AudioModeList) { [void]$ui.cmbAudio.Items.Add($k) }
$ui.cmbAudio.SelectedIndex = 1     # AAC opnieuw encoderen

# Van keuzeregel naar ffmpeg-modus. Onbekende waarde -> de standaard,
# nooit stilletjes naar 'copy' terugvallen: dat is juist de instelling
# die het probleem geeft.
function Get-AudioMode {
    $k = [string]$ui.cmbAudio.SelectedItem
    if ($k -and $AudioModeMap.ContainsKey($k)) { return [string]$AudioModeMap[$k] }
    return [string]$script:DefaultAudioMode
}

function Fill-Presets {
    $key = [string]$ui.cmbCodec.SelectedItem
    if (-not $key -or -not $PresetMap.ContainsKey($key)) { return }
    $keep = [string]$ui.cmbPreset.SelectedItem
    $ui.cmbPreset.Items.Clear()
    foreach ($p in $PresetMap[$key]) { [void]$ui.cmbPreset.Items.Add($p) }
    if ($keep -and $PresetMap[$key] -contains $keep) { $ui.cmbPreset.SelectedItem = $keep }
    elseif ($key -eq 'libx265 (CPU / x265)') { $ui.cmbPreset.SelectedItem = 'medium' }
    elseif ($key -eq 'hevc_nvenc (NVIDIA GPU)') { $ui.cmbPreset.SelectedItem = 'p5' }
    elseif ($key -eq 'hevc_amf (AMD GPU)') { $ui.cmbPreset.SelectedItem = 'balanced' }
    else { $ui.cmbPreset.SelectedItem = 'medium' }
}
Fill-Presets

$ui.txtExt.Text  = $DefaultExtensions
$ui.txtWork.Text = $env:TEMP
$ui.sldCrf.Value = 23
$ui.txtCrf.Text  = '23'

# opgeslagen instellingen terugzetten
$saved = Load-Settings
$script:SavedSettings = $saved
if ($saved -ne $null) {
    try {
        if ($saved.CodecIndex -ne $null -and $saved.CodecIndex -ge 0 -and $saved.CodecIndex -lt $ui.cmbCodec.Items.Count) {
            $ui.cmbCodec.SelectedIndex = $saved.CodecIndex
        }
        Fill-Presets
        if ($saved.Preset)     { $ui.cmbPreset.SelectedItem = $saved.Preset }
        if ($saved.Crf -ne $null) { $ui.sldCrf.Value = [double]$saved.Crf }
        if ($saved.Extensions) { $ui.txtExt.Text = [string]$saved.Extensions }
        if ($saved.AudioMode) {
            $am  = [string]$saved.AudioMode
            $hit = $null
            foreach ($k in $AudioModeList) { if ([string]$AudioModeMap[$k] -eq $am) { $hit = $k; break } }
            if ($hit) { $ui.cmbAudio.SelectedItem = $hit }
        }
        if ($saved.WorkDir) {
            # Het bewaarde pad kan van een andere machine komen, of de
            # beheerder kan die map hebben dichtgezet. Dan is het geen
            # bruikbare werkmap en nemen we de tijdelijke map van de
            # gebruiker - daar mag altijd geschreven worden.
            $wdSaved = [string]$saved.WorkDir
            if (Test-DirWritable $wdSaved) { $ui.txtWork.Text = $wdSaved }
            else {
                $wdAlt = Join-Path $env:TEMP 'X265-Converter'
                if (Test-DirWritable $wdAlt) { $ui.txtWork.Text = $wdAlt }
                $script:WorkDirFallback = @{ Oud = $wdSaved; Nieuw = $ui.txtWork.Text }
            }
        }
        if ($saved.Recursive     -ne $null) { $script:Recursive  = [bool]$saved.Recursive }
        if ($saved.DeleteOrig    -ne $null) { $ui.chkDeleteOrig.IsChecked = [bool]$saved.DeleteOrig }
        if ($saved.KeepDate      -ne $null) { $script:KeepDate   = [bool]$saved.KeepDate }
        if ($saved.HandleSubs    -ne $null) { $ui.chkSubs.IsChecked       = [bool]$saved.HandleSubs }
        if ($saved.SmartRetry    -ne $null) { $script:SmartRetry = [bool]$saved.SmartRetry }
        if ($saved.ExitAfterStop -ne $null) { $ui.chkExitAfter.IsChecked  = [bool]$saved.ExitAfterStop }

        # SkipHevc uit oudere versies wordt bewust genegeerd: HEVC
        # overslaan is nu vast gedrag.

        if ($saved.SubExtensions) {
            $tmpExt = @($saved.SubExtensions | Where-Object { $_ -and ([string]$_).Trim().Length -gt 0 })
            if ($tmpExt.Count -gt 0) { $script:SubExtensions = @($tmpExt | ForEach-Object { [string]$_ }) }
        }
        if ($saved.FinalRemux -ne $null)    { $script:FinalRemux    = [bool]$saved.FinalRemux }
        if ($saved.RemuxIfNeeded -ne $null) { $script:RemuxIfNeeded = [bool]$saved.RemuxIfNeeded }
        if ($saved.PrefetchToWorkDir -ne $null)   { $script:PrefetchToWorkDir   = [bool]$saved.PrefetchToWorkDir }
        if ($saved.PrefetchOnlyNetwork -ne $null) { $script:PrefetchOnlyNetwork = [bool]$saved.PrefetchOnlyNetwork }
        if ($saved.SharedLocks -ne $null)         { $script:SharedLocks         = [bool]$saved.SharedLocks }
        if ($saved.LockStaleMinutes) {
            $m = [double]$saved.LockStaleMinutes
            # Onder de twee minuten wordt het gevaarlijk: dan geldt een pc
            # die even met een trage share worstelt al als verdwenen.
            if ($m -ge 2.0 -and $m -le 1440.0) { $script:LockStaleMinutes = $m }
        }
        if ($saved.RestoreQueue -ne $null) { $script:RestoreQueue = [bool]$saved.RestoreQueue }
        if ($saved.CheckAudioTail -ne $null) { $script:CheckAudioTail = [bool]$saved.CheckAudioTail }
        if ($saved.AudioTailTolerance -ne $null) {
            $tolD = 0.0
            if ([double]::TryParse([string]$saved.AudioTailTolerance,
                                   [Globalization.NumberStyles]::Float,
                                   [Globalization.CultureInfo]::InvariantCulture, [ref]$tolD) -and
                $tolD -ge 0 -and $tolD -le 3600) { $script:AudioTailTolerance = $tolD }
        }
        if ($saved.PadShortAudio -ne $null) { $script:PadShortAudio = [bool]$saved.PadShortAudio }
        if ($saved.VcpMarker) {
            $vm = ([string]$saved.VcpMarker).Trim()
            if ($vm.Length -gt 0 -and $vm -notmatch '[\\/:*?"<>|.]') { $script:VcpMarker = $vm }
        }
        if ($saved.AudioLossLimit -ne $null) {
            $limD = 0.0
            if ([double]::TryParse([string]$saved.AudioLossLimit,
                                   [Globalization.NumberStyles]::Float,
                                   [Globalization.CultureInfo]::InvariantCulture, [ref]$limD) -and
                $limD -ge 0 -and $limD -le 86400) { $script:AudioLossLimit = $limD }
        }
        if ($saved.AudioTailMargin -ne $null) {
            $marD = 0.0
            if ([double]::TryParse([string]$saved.AudioTailMargin,
                                   [Globalization.NumberStyles]::Float,
                                   [Globalization.CultureInfo]::InvariantCulture, [ref]$marD) -and
                $marD -ge 0 -and $marD -le 3600) { $script:AudioTailMargin = $marD }
        }
        if ($saved.KeepAwakeSignal -ne $null) { $script:KeepAwakeSignal = [string]$saved.KeepAwakeSignal }
        if ($saved.MaxFailStreak -ne $null) {
            $mf = 0
            if ([int]::TryParse([string]$saved.MaxFailStreak, [ref]$mf) -and $mf -ge 1 -and $mf -le 99) {
                $script:MaxFailStreak = $mf
            }
        }

        if ($saved.Folders) {
            foreach ($f in @($saved.Folders)) {
                if ($f -and (Test-PathSafe ([string]$f) -Container)) { [void]$ui.lstFolders.Items.Add([string]$f) }
            }
        }

        # ---- cumulatieve totalen terugzetten ------------------------
        if ($saved.Totals -ne $null) {
            $t = $sync.Totals
            [System.Threading.Monitor]::Enter($t.SyncRoot)
            try {
                if ($saved.Totals.Files     -ne $null) { $t.Files     = [int]$saved.Totals.Files }
                if ($saved.Totals.OrigBytes -ne $null) { $t.OrigBytes = [long]$saved.Totals.OrigBytes }
                if ($saved.Totals.NewBytes  -ne $null) { $t.NewBytes  = [long]$saved.Totals.NewBytes }
                if ($saved.Totals.ActiveSec -ne $null) { $t.ActiveSec = [double]$saved.Totals.ActiveSec }
                if ($saved.Totals.VideoSec  -ne $null) { $t.VideoSec  = [double]$saved.Totals.VideoSec }
                if ($saved.Totals.FirstUsed) { $t.FirstUsed = [string]$saved.Totals.FirstUsed }
                if ($saved.Totals.LastUsed)  { $t.LastUsed  = [string]$saved.Totals.LastUsed }
            }
            finally { [System.Threading.Monitor]::Exit($t.SyncRoot) }
        }
    } catch { }
}

# ---------------------------------------------------------------------
# 11b. Bewaarde wachtrij terugzetten
#
#      De regels komen terug in de bewaarde volgorde; wat in de wachtrij
#      stond wordt op positie gezet. Daarna wordt in de achtergrond
#      nagelopen of de bestanden er nog staan (zie Start-VerifyRound).
# ---------------------------------------------------------------------

$script:RestoredQueue = @()

function Restore-SavedQueue {
    param($Saved)

    if ($Saved -eq $null -or $Saved.Queue -eq $null) { return }

    $rows = @($Saved.Queue)
    if ($rows.Count -eq 0) { return }

    # eerst de regels in de bewaarde lijstvolgorde toevoegen
    $withPos = New-Object System.Collections.ArrayList

    foreach ($r in $rows) {
        try {
            $fp = [string]$r.FullPath
            if ([string]::IsNullOrWhiteSpace($fp)) { continue }
            if ($script:JobPaths.Contains($fp)) { continue }

            $fj = New-Object X265.FileJob($win.Dispatcher)
            $fj.FullPath     = $fp
            $fj.Name         = [string]$r.Name
            $fj.Folder       = [string]$r.Folder
            $fj.SizeBytes    = [long]$r.SizeBytes
            $fj.DurationSec  = [double]$r.DurationSec
            $fj.RawCodec     = [string]$r.Codec
            $fj.Codec        = [string]$r.Codec
            $fj.IsHevc       = [bool]$r.IsHevc
            $fj.SizeText     = Format-Size ([double]$r.SizeBytes)
            $fj.DurationText = if ([double]$r.DurationSec -gt 0) { Format-Clock ([double]$r.DurationSec) } else { '?' }
            # Een bewaarde status van een regel die bij het afsluiten nog
            # onder handen was ('Encoderen', 'Verplaatsen', ...) mag niet
            # terugkomen: alle bewakingen die op die statussen letten zouden
            # de regel dan als "nu bezig" behandelen, waardoor hij niet meer
            # uit de lijst of uit de wachtrij te halen is.
            $sst = [string]$r.Status
            if ($script:ActiveStatus -contains $sst -or $sst -eq 'Afgebroken') { $sst = 'In wachtrij' }
            $fj.Status       = $sst
            $fj.ResultText   = [string]$r.ResultText
            $fj.Include      = [bool]$r.Include        # setter weigert dit bij IsHevc
            $fj.Queued       = $false

            [void]$script:JobPaths.Add($fp)
            $jobs.Add($fj)
            Register-JobEvents $fj

            $qp = 0
            if ($r.QueuePos -ne $null) { $qp = [int]$r.QueuePos }
            if ($qp -gt 0 -and $fj.Include) {
                [void]$withPos.Add([pscustomobject]@{ Pos = $qp; Job = $fj })
            }
        }
        catch { }
    }

    # dan de wachtrij in de bewaarde volgorde vullen
    foreach ($e in ($withPos | Sort-Object Pos)) {
        $e.Job.Queued = $true
        $e.Job.Status = 'In wachtrij'
        [void]$sync.Queue.Add($e.Job)
    }

    Write-Log ("Bewaarde lijst teruggezet: {0} regel(s), {1} in de wachtrij." -f $jobs.Count, $sync.Queue.Count)
}

$ui.txtCrf.Text = [string][int]$ui.sldCrf.Value

# paden van de opdrachtregel
if ($Path) { foreach ($p in $Path) { Add-Folder $p } }
if ($ui.lstFolders.Items.Count -eq 0) { Add-Folder $ScriptDir }

$ui.txtSubTitle.Text = "Batch converter   -   scriptmap: $ScriptDir"
