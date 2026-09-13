# Losse kopie van de opslag-functies uit src/part6.ps1, zodat test_eta
# kan draaien zonder de hele GUI op te bouwen.

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
            Folders       = @($ui.lstFolders.Items | ForEach-Object { [string]$_ })
            CodecIndex    = $ui.cmbCodec.SelectedIndex
            Preset        = [string]$ui.cmbPreset.SelectedItem
            Crf           = [int]$ui.sldCrf.Value
            Extensions    = $ui.txtExt.Text
            WorkDir       = $ui.txtWork.Text
            Recursive     = [bool]$ui.chkRecursive.IsChecked
            DeleteOrig    = [bool]$ui.chkDeleteOrig.IsChecked
            KeepDate      = [bool]$ui.chkKeepDate.IsChecked
            HandleSubs    = [bool]$ui.chkSubs.IsChecked
            SmartRetry    = [bool]$ui.chkSmartRetry.IsChecked
            ExitAfterStop = [bool]$ui.chkExitAfter.IsChecked
            SubExtensions = @($script:SubExtensions)
            MaxFailStreak = [int]$script:MaxFailStreak
            Totals        = $totals
            Queue         = @($rows.ToArray())
        }

        $json = $obj | ConvertTo-Json -Depth 6

        $tmp = $SettingsFile + '.tmp'
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -Force
        if (Test-Path -LiteralPath $SettingsFile) {
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
    if (-not (Test-Path -LiteralPath $SettingsFile)) { return $null }
    try { return (Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch {
        try { Write-Log 'Het instellingenbestand is onleesbaar; er wordt met een lege lijst gestart.' 'WAARS' } catch { }
        return $null
    }
}

