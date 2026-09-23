
# ---------------------------------------------------------------------
# 16.  Klok:  GUI verversen, log leegtrekken, tijdsindicatie
# ---------------------------------------------------------------------

$script:TickCount     = 0
$script:LastScan      = $false
$script:LastConv      = $false
$script:LastPaused    = $false
$script:LastStopAfter = $false
$script:TickErrors    = 0
$script:VerifyRunning = $false
$script:VerifyMissing = 0
$script:VerifyHevc    = 0
$script:ExitAt        = $null
$script:ExitPending   = $false

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)

function Format-Totals {
    $t = $sync.Totals
    $f = 0; $ob = [long]0; $nb = [long]0; $ac = 0.0; $vs = 0.0; $last = ''
    [System.Threading.Monitor]::Enter($t.SyncRoot)
    try {
        $f = [int]$t.Files; $ob = [long]$t.OrigBytes; $nb = [long]$t.NewBytes
        $ac = [double]$t.ActiveSec; $vs = [double]$t.VideoSec; $last = [string]$t.LastUsed
    }
    finally { [System.Threading.Monitor]::Exit($t.SyncRoot) }

    if ($f -le 0) { return 'nog niets omgezet' }

    $saved = [double]$ob - [double]$nb
    $pct   = 0.0
    if ($ob -gt 0) { $pct = 100.0 * $saved / [double]$ob }

    return ("{0} bestanden   {1} -> {2}   bespaard {3} ({4:N1} %)   rekentijd {5}   speelduur {6}{7}" -f `
        $f, (Format-Size $ob), (Format-Size $nb), (Format-Size $saved), $pct,
        (Format-Span $ac), (Format-Span $vs),
        $(if ($last) { "   laatst $last" } else { '' }))
}

function Invoke-Tick {

    $script:TickCount = $script:TickCount + 1

    $scanBusy = [bool]$sync.ScanBusy
    $convBusy = [bool]$sync.ConvBusy

    # ---------- log ------------------------------------------------
    $sb = New-Object System.Text.StringBuilder
    $line = ''
    $n = 0
    while ($n -lt 500 -and $sync.LogQueue.TryDequeue([ref]$line)) {
        [void]$sb.AppendLine($line)
        $n++
    }
    if ($n -gt 0) {
        $script:LogLines = $script:LogLines + $n
        if ($script:LogLines -gt 8000) {
            $keep = @($ui.txtLog.Text -split "`r?`n")
            if ($keep.Count -gt 4000) {
                $ui.txtLog.Text = ($keep[($keep.Count - 4000)..($keep.Count - 1)] -join "`r`n")
            }
            $script:LogLines = 4000
        }
        $ui.txtLog.AppendText($sb.ToString())
        $ui.txtLog.ScrollToEnd()
    }

    # ---------- nieuwe scanresultaten onderaan de lijst -------------
    $added = 0
    $item  = $null
    $autoQueue = New-Object System.Collections.ArrayList

    while ($added -lt 300 -and $sync.NewJobs.TryDequeue([ref]$item)) {

        $full = [string]$item.FullPath
        if ($script:JobPaths.Contains($full))  { continue }   # staat al in de lijst
        if ($script:DonePaths.Contains($full)) { continue }   # deze sessie al afgehandeld

        $fj = New-Object X265.FileJob($win.Dispatcher)
        $fj.FullPath     = $full
        $fj.Name         = [string]$item.Name
        $fj.Folder       = [string]$item.Folder
        $fj.SizeBytes    = [long]$item.SizeBytes
        $fj.DurationSec  = [double]$item.DurationSec
        $fj.RawCodec     = [string]$item.Codec
        $fj.Codec        = [string]$item.Codec
        $fj.IsHevc       = [bool]$item.IsHevc          # zet Include zelf op false
        $fj.SizeText     = Format-Size ([double]$item.SizeBytes)
        $fj.DurationText = if ($item.DurationSec -gt 0) { Format-Clock ([double]$item.DurationSec) } else { '?' }
        $fj.Queued       = $false
        if ($item.PSObject.Properties.Name -contains 'OutPath') { $fj.OutPath = [string]$item.OutPath }
        if ($fj.IsHevc) { $fj.Status = 'Al HEVC' } else { $fj.Status = 'Niet in wachtrij' }
        if (-not $fj.IsHevc) { $fj.Include = [bool]$item.Include }

        [void]$script:JobPaths.Add($full)
        $jobs.Add($fj)
        Register-JobEvents $fj
        $added++

        # Van de opdrachtregel aangeleverd: meteen achteraan de wachtrij,
        # anders zou er nog op een klik op Start moeten worden gewacht.
        if ($item.PSObject.Properties.Name -contains 'AutoQueue' -and [bool]$item.AutoQueue) {
            [void]$autoQueue.Add($fj)
        }
    }
    if ($autoQueue.Count -gt 0) {
        [void](Add-ToQueueBack $autoQueue)
        Write-Log ("{0} bestand(en) automatisch achteraan de wachtrij gezet." -f $autoQueue.Count)
        Start-ConversionIfIdle
    }
    if ($added -gt 0) { Request-Save }

    # ---------- opdrachten van een tweede aanroep -------------------
    # Read-Inbox houdt zichzelf op een ronde per twee seconden.
    Read-Inbox

    # ---------- elk uur opnieuw kijken ------------------------------
    #  De klok loopt alleen als er niets te doen is. Zodra er weer iets
    #  draait of er staat weer werk klaar, begint het uur opnieuw.
    if ([bool]$ui.chkWatch.IsChecked) {
        if ($sync.ScanBusy -or $sync.ConvBusy -or $sync.Queue.Count -gt 0) {
            $script:WatchVanaf = $null
        }
        elseif ($script:WatchVanaf -eq $null) {
            $script:WatchVanaf = Get-Date
        }
        elseif (((Get-Date) - $script:WatchVanaf).TotalMinutes -ge [double]$script:WatchMinutes) {
            $script:WatchVanaf = $null
            [void](Start-WatchScan)
        }
    }
    elseif ($script:WatchVanaf -ne $null) { $script:WatchVanaf = $null }

    # ---------- uitkomsten van de controleronde ---------------------
    $verified = 0
    $vr = $null
    while ($verified -lt 200 -and $sync.VerifyResults.TryDequeue([ref]$vr)) {

        $verified++
        $fp = [string]$vr.FullPath
        $row = $null
        foreach ($j in $jobs) { if ([string]$j.FullPath -eq $fp) { $row = $j; break } }
        if ($row -eq $null) { continue }

        if (-not $vr.Ok) {
            # niet aanwezig of niet benaderbaar: uitvinken en laten staan
            $row.Include    = $false
            $row.Status     = 'Niet gevonden'
            $row.ResultText = [string]$vr.Error
            $script:VerifyMissing = $script:VerifyMissing + 1
            continue
        }

        # gegevens verversen
        $row.SizeBytes   = [long]$vr.SizeBytes
        $row.SizeText    = Format-Size ([double]$vr.SizeBytes)
        $row.DurationSec = [double]$vr.DurationSec
        $row.DurationText= if ([double]$vr.DurationSec -gt 0) { Format-Clock ([double]$vr.DurationSec) } else { '?' }
        $row.RawCodec    = [string]$vr.Codec
        $row.Codec       = [string]$vr.Codec

        if ([bool]$vr.IsHevc) {
            # inmiddels al HEVC: uit de wachtrij en niet meer aanvinkbaar
            $row.IsHevc = $true            # de setter zet Include op false
            $row.Status = 'Al HEVC'
            $script:VerifyHevc = $script:VerifyHevc + 1
        }
        elseif ($row.Status -eq 'Niet gevonden') {
            $row.Status     = 'Niet in wachtrij'
            $row.ResultText = ''
        }
    }
    if ($verified -gt 0) { Sync-QueueOrder }

    # ---------- afgeronde regels uit de lijst halen -----------------
    $removed  = 0
    $released = 0
    foreach ($j in @($jobs)) {
        if ($j.Status -eq 'Geslaagd') {
            [void]$script:JobPaths.Remove([string]$j.FullPath)
            [void]$script:DonePaths.Add([string]$j.FullPath)
            Unregister-JobEvents $j
            [void]$jobs.Remove($j)
            $removed++
        }
        elseif ($j.Include -and -not $j.Queued -and ($j.Status -eq 'Mislukt' -or $j.Status -eq 'Let op')) {
            # blijft staan zodat je hem ziet; vinkje eraf zodat hij niet
            # meteen weer wordt meegenomen
            $script:InIncludeChange = $true
            try { $j.Include = $false } finally { $script:InIncludeChange = $false }
            $released++
        }
    }
    if ($removed -gt 0 -or $released -gt 0) { Sync-QueueOrder }

    # ---------- scanvoortgang ---------------------------------------
    if ($scanBusy) {
        $wat = switch ($sync.ScanMode) {
            'verify'   { 'Controleren' }
            'opdracht' { 'Opdrachten nakijken' }
            default    { 'Scannen' }
        }
        if ($sync.ScanTotal -gt 0) {
            $ui.txtScanState.Text = ("{0}: {1}/{2}  -  video's {3}  -  al HEVC {4}  -  onbruikbaar {5}" -f `
                $wat, $sync.ScanChecked, $sync.ScanTotal, $sync.ScanFound, $sync.ScanSkippedHevc, $sync.ScanSkippedNoVid)
        } else {
            $ui.txtScanState.Text = "$wat : bestanden opsommen…"
        }

        if (-not $convBusy) {
            $ui.txtOverallLabel.Text = $wat
            if ($sync.ScanTotal -gt 0) {
                $ui.pbOverall.IsIndeterminate = $false
                $ui.pbOverall.Value = 100.0 * $sync.ScanChecked / $sync.ScanTotal
                $ui.txtOverallInfo.Text = "$($sync.ScanChecked) / $($sync.ScanTotal)"
            } else {
                $ui.pbOverall.IsIndeterminate = $true
                $ui.txtOverallInfo.Text = 'bestanden opsommen…'
            }
            $ui.txtCurrentFile.Text = [string]$sync.ScanStatus
            $ui.txtCurrentInfo.Text = ''
            $ui.pbCurrent.IsIndeterminate = $false
            $ui.pbCurrent.Value     = 0
            Set-Status "$wat…  video's: $($sync.ScanFound)   al HEVC: $($sync.ScanSkippedHevc)   onbruikbaar: $($sync.ScanSkippedNoVid)"
        }
    }
    elseif ($ui.txtScanState.Text -ne '') {
        $ui.txtScanState.Text = ''
    }

    # ---------- conversievoortgang ----------------------------------
    #  Nog te doen = de rest van het huidige bestand + de hele wachtrij.
    #  Daardoor bewegen "Resterend" en "Klaar omstreeks" binnen één slag
    #  mee met elke wijziging van de wachtrij.
    #  De nog te doen speelduur van de wachtrij wordt hier elke slag
    #  opnieuw opgeteld. Dat moet: de werk-thread haalt de bovenste regel
    #  van de lijst zonder de teller bij te werken, dus een gecachte
    #  waarde zou het bestand dat bezig is dubbel tellen zolang er geen
    #  wachtrijwijziging langskomt.
    $qSec = [double]0
    foreach ($qj in (Get-QueueSnapshot)) { if ($qj -ne $null) { $qSec = $qSec + [double]$qj.DurationSec } }
    $sync.QueueVideoSec = $qSec

    $remainSec = ([double]$sync.CurDurationSec - [double]$sync.CurVideoSec) + $qSec
    if ($remainSec -lt 0) { $remainSec = 0 }
    $doneWork  = [double]$sync.DoneVideoSec + [double]$sync.CurVideoSec
    $totalWork = $doneWork + $remainSec

    $inQueue = $sync.Queue.Count
    $busyOne = 0
    if ($sync.CurrentJob -ne $null) { $busyOne = 1 }

    # Is de speelduur bruikbaar? Kan ffprobe de duur van de bronnen niet
    # geven, dan is de optelling van de wachtrij nul en zou 'nog te doen'
    # nul zijn - met een volle balk terwijl er nog honderden bestanden
    # wachten, en een tijdsindicatie van niks. Dan liever tellen op AANTAL
    # BESTANDEN: grover, maar het klopt tenminste.
    $duurBruikbaar = (($qSec -gt 0) -or ($inQueue -eq 0)) -and ($totalWork -gt 0)

    if ($convBusy) {

        $ui.pbOverall.IsIndeterminate = $false
        $ui.txtOverallLabel.Text = 'Totale voortgang'

        if ($duurBruikbaar) {
            $p = 100.0 * $doneWork / $totalWork
            if ($p -gt 100) { $p = 100 }
            $ui.pbOverall.Value = $p
            $ui.txtOverallInfo.Text = ("{0} klaar  -  {1} in wachtrij  -  {2:N1} %" -f $sync.JobsDone, $inQueue, $p)
        }
        else {
            $alle = $sync.JobsDone + $inQueue + $busyOne
            $p = 0.0
            if ($alle -gt 0) { $p = 100.0 * $sync.JobsDone / $alle }
            $ui.pbOverall.Value = $p
            $ui.txtOverallInfo.Text = ("{0} klaar  -  {1} in wachtrij  -  {2:N1} %  (op aantal bestanden; speelduur onbekend)" -f `
                $sync.JobsDone, $inQueue, $p)
        }

        $phase = [string]$sync.CurPhase
        $pre   = ''
        if ($sync.IsPaused)              { $pre = '[GEPAUZEERD] ' }
        elseif ($sync.Cancel)            { $pre = '[AFBREKEN] ' }
        elseif ($sync.StopAfterCurrent)  { $pre = '[STOPT HIERNA] ' }

        if ($sync.CurFile) { $ui.txtCurrentFile.Text = "$pre$phase : $($sync.CurFile)" }
        else               { $ui.txtCurrentFile.Text = "$pre$phase" }

        # Geen bekende speelduur betekent geen percentage: dat wordt
        # berekend als bereikte seconde gedeeld door totale duur. De balk
        # zou dan de hele conversie dood op nul blijven staan terwijl er
        # wel degelijk wordt gewerkt. In dat geval laten we hem heen en
        # weer lopen en tonen we hoeveel speeltijd er al door de encoder
        # is gegaan.
        $duurOnbekend = (($phase -eq 'Encoderen') -and ([double]$sync.CurDurationSec -le 0))
        if ($ui.pbCurrent.IsIndeterminate -ne $duurOnbekend) { $ui.pbCurrent.IsIndeterminate = $duurOnbekend }
        if (-not $duurOnbekend) { $ui.pbCurrent.Value = [double]$sync.CurPhasePct }

        $bits = New-Object System.Collections.ArrayList
        if ($duurOnbekend) {
            [void]$bits.Add((Format-Clock ([double]$sync.CurVideoSec)) + ' verwerkt')
            [void]$bits.Add('speelduur onbekend')
        }
        else {
            [void]$bits.Add(('{0:N1} %' -f [double]$sync.CurPhasePct))
            if ($sync.CurDurationSec -gt 0 -and $phase -eq 'Encoderen') {
                [void]$bits.Add((Format-Clock ([double]$sync.CurVideoSec)) + ' / ' + (Format-Clock ([double]$sync.CurDurationSec)))
            }
        }
        if ($sync.CurSpeed)          { [void]$bits.Add('snelheid ' + $sync.CurSpeed) }
        if ($sync.CurFps)            { [void]$bits.Add($sync.CurFps + ' fps') }
        if ($sync.CurTempSize -gt 0) { [void]$bits.Add((Format-Size ([double]$sync.CurTempSize))) }
        $ui.txtCurrentInfo.Text = ($bits -join '   ')

        # ---- tijdsindicatie: rekenfactor het eerste halfuur elke 30 s,
        #      daarna elke 2 minuten bijwerken
        $active   = [double]$sync.ActiveSec
        $interval = 30
        if ($active -ge 1800) { $interval = 120 }

        $doRecalc = $false
        if (-not $sync.IsPaused) {
            if ($script:EtaLastCalc -eq $null) {
                if ($active -ge 15 -and $doneWork -gt 0) { $doRecalc = $true }
            }
            elseif (((Get-Date) - $script:EtaLastCalc).TotalSeconds -ge $interval) {
                $doRecalc = $true
            }
        }

        # Zonder bruikbare speelduur kan er niet op speeltijd worden
        # gerekend. Dan maar op ervaring: hoeveel wandkloktijd kostte een
        # bestand gemiddeld, maal wat er nog ligt. Dat kan pas zodra er een
        # bestand af is.
        if (-not $duurBruikbaar) {
            if ($sync.JobsDone -gt 0 -and $active -gt 0) {
                $perFile = $active / [double]$sync.JobsDone
                $script:EtaRate  = -1                      # vlag: tellen op bestanden
                $script:EtaFiles = $perFile * ($inQueue + $busyOne)
                if ($script:EtaLastCalc -eq $null -or
                    ((Get-Date) - $script:EtaLastCalc).TotalSeconds -ge $interval) {
                    $script:EtaLastCalc = Get-Date
                    $script:EtaStamp    = (Get-Date -Format 'HH:mm:ss')
                }
            }
            else { $script:EtaRate = 0; $script:EtaFiles = 0 }
        }
        elseif ($doRecalc -and $doneWork -gt 0 -and $active -gt 0) {
            $script:EtaRate     = $doneWork / $active
            $script:EtaLastCalc = Get-Date
            $script:EtaStamp    = (Get-Date -Format 'HH:mm:ss')
        }

        if (-not $duurBruikbaar) {
            if ($script:EtaFiles -gt 0) {
                $remain = [double]$script:EtaFiles
                $ui.stEta.Text = Format-Span $remain
                if ($sync.IsPaused) { $ui.stEtaClock.Text = 'gepauzeerd' }
                else {
                    $done = (Get-Date).AddSeconds($remain)
                    if ($done.Date -eq (Get-Date).Date) { $ui.stEtaClock.Text = $done.ToString('HH:mm') }
                    else { $ui.stEtaClock.Text = $done.ToString('ddd HH:mm') }
                }
                $ui.txtStatus2.Text = "tijdsindicatie op aantal bestanden, bijgewerkt $($script:EtaStamp)"
            }
            else {
                $ui.stEta.Text      = 'berekenen…'
                $ui.stEtaClock.Text = '--:--'
            }
        }
        elseif ($script:EtaRate -gt 0) {
            $remain = $remainSec / $script:EtaRate
            $ui.stEta.Text = Format-Span $remain
            if ($sync.IsPaused) {
                $ui.stEtaClock.Text = 'gepauzeerd'
            } else {
                $done = (Get-Date).AddSeconds($remain)
                if ($done.Date -eq (Get-Date).Date) { $ui.stEtaClock.Text = $done.ToString('HH:mm') }
                else { $ui.stEtaClock.Text = $done.ToString('ddd HH:mm') }
            }
            $ui.txtStatus2.Text = "tijdsindicatie bijgewerkt $($script:EtaStamp)  (elke $interval s)"
        } else {
            $ui.stEta.Text      = 'berekenen…'
            $ui.stEtaClock.Text = '--:--'
        }

        # Gemiddelde encode-snelheid is speeltijd gedeeld door rekentijd.
        # Zonder bekende speelduur is dat een verzonnen getal; dan liever
        # een streepje dan een cijfer waar iemand op gaat rekenen.
        if (-not $duurBruikbaar) { $ui.stSpeed.Text = '-' }
        elseif ($active -gt 0 -and $doneWork -gt 0) {
            $ui.stSpeed.Text = ('{0:N2}x' -f ($doneWork / $active))
        }

        # venstertitel en taakbalk
        Set-Title ('{0:N0} %  -  {1} klaar, {2} te gaan' -f `
            $ui.pbOverall.Value, $sync.JobsDone, ($inQueue + $busyOne))
        if ($ui.ContainsKey('taskbar')) {
            try {
                if ($sync.IsPaused)   { $ui.taskbar.ProgressState = 'Paused' }
                elseif ($sync.Cancel) { $ui.taskbar.ProgressState = 'Error' }
                else                  { $ui.taskbar.ProgressState = 'Normal' }
                $ui.taskbar.ProgressValue = ([double]$ui.pbOverall.Value / 100.0)
            } catch { }
        }

        if ($sync.IsPaused)             { Set-Status 'Gepauzeerd - ffmpeg staat stil.' }
        elseif ($sync.Cancel)           { Set-Status 'Afbreken…' }
        elseif ($sync.StopAfterCurrent) { Set-Status 'Stopt na de huidige conversie. Nog een keer op de knop trekt dat weer in.' }
        else                            { Set-Status "Bezig: $($sync.CurFile)" }
    }
    elseif (-not $scanBusy -and $script:ExitAt -eq $null) {
        $ui.stEta.Text      = Format-Span $remainSec
        $ui.stEtaClock.Text = '--:--'
    }

    # ---------- statistiek ------------------------------------------
    $ui.stActive.Text = Format-Clock ([double]$sync.ActiveSec)
    $ui.stWall.Text   = (Format-Clock ([double]$sync.WallSec)) + '  /  ' + (Format-Clock ([double]$sync.PausedSec))
    $ui.stFiles.Text  = "$($sync.JobsDone) / $($sync.Queue.Count)"
    $ui.stOrig.Text   = Format-Size ([double]$sync.OrigBytes)
    $ui.stNew.Text    = Format-Size ([double]$sync.NewBytes)

    $savedB = [double]$sync.OrigBytes - [double]$sync.NewBytes
    $ui.stSaved.Text = Format-Size $savedB
    if ($sync.OrigBytes -gt 0) { $ui.stSavedPct.Text = ('{0:N1} %' -f (100.0 * $savedB / [double]$sync.OrigBytes)) }
    else { $ui.stSavedPct.Text = '0 %' }
    $ui.stResult.Text = "$($sync.Success) / $($sync.Failed)"
    $ui.stWarn.Text   = [string]$sync.Warned

    if (($script:TickCount % 5) -eq 0 -or $sync.TotalsDirty) {
        $ui.stTotals.Text = Format-Totals
    }

    # ---------- totalen en wachtrij wegschrijven ---------------------
    if ($sync.TotalsDirty) {
        $sync.TotalsDirty = $false
        Save-Settings
    }
    elseif ($script:SaveDirty -and ((Get-Date) - $script:LastSaveTime).TotalSeconds -ge 2) {
        Save-Settings
    }

    # ---------- knoppen bijwerken als de toestand omslaat ------------
    if ($script:LastScan      -ne $scanBusy -or
        $script:LastConv      -ne $convBusy -or
        $script:LastPaused    -ne [bool]$sync.IsPaused -or
        $script:LastStopAfter -ne [bool]$sync.StopAfterCurrent) {

        $script:LastScan      = $scanBusy
        $script:LastConv      = $convBusy
        $script:LastPaused    = [bool]$sync.IsPaused
        $script:LastStopAfter = [bool]$sync.StopAfterCurrent
        Update-Buttons
    }

    # ---------- scan / controleronde afgerond -----------------------
    $slotScan = $script:Slots['scan']
    if ($slotScan.Handle -ne $null -and $slotScan.Handle.IsCompleted) {

        $wasVerify   = ($sync.ScanMode -eq 'verify')
        $wasOpdracht = ($sync.ScanMode -eq 'opdracht')

        $sync.ScanBusy = $false
        $scanBusy      = $false
        Clear-Slot 'scan'
        $sync.ScanCancel = $false
        $ui.txtScanState.Text = ''

        if ($wasVerify) {
            $script:VerifyRunning = $false
            Sync-QueueOrder

            $txt = ("Bewaarde lijst nagelopen: {0} in orde, {1} niet gevonden, {2} inmiddels al HEVC." -f `
                $sync.ScanFound, $script:VerifyMissing, $script:VerifyHevc)
            Write-Log $txt
            Set-Status $txt

            if ($script:VerifyMissing -gt 0 -or $script:VerifyHevc -gt 0) {
                $m = "De bewaarde lijst is nagelopen.`n`n"
                if ($script:VerifyMissing -gt 0) {
                    $m = $m + ("$($script:VerifyMissing) bestand(en) zijn niet gevonden of niet benaderbaar. Die staan nog in de lijst, maar zijn uitgevinkt.`n")
                }
                if ($script:VerifyHevc -gt 0) {
                    $m = $m + ("$($script:VerifyHevc) bestand(en) zijn inmiddels al HEVC en zijn uit de wachtrij gehaald.`n")
                }
                [System.Windows.MessageBox]::Show($m, 'Bewaarde lijst', 'OK', 'Information') | Out-Null
            }
            Set-Title 'Batch Converter'
        }
        elseif ($wasOpdracht) {
            # Opdrachten van de opdrachtregel: geen schermvullende melding en
            # vooral niet de weergave van een lopende conversie leegmaken.
            $sync.ScanMode = 'scan'
            Write-Log ("Opdrachten verwerkt: {0} aangenomen, {1} al HEVC, {2} niet bruikbaar." -f `
                $sync.ScanFound, $sync.ScanSkippedHevc, $sync.ScanSkippedNoVid)
        }
        else {
            $txt = ("Scan gereed. {0} video's gevonden, {1} al HEVC, {2} zonder videostream." -f `
                $sync.ScanFound, $sync.ScanSkippedHevc, $sync.ScanSkippedNoVid)
            if ($convBusy) {
                Write-Log $txt
            } else {
                $ui.pbOverall.IsIndeterminate = $false
                $ui.pbOverall.Value     = 0
                $ui.txtOverallInfo.Text = ''
                $ui.txtCurrentFile.Text = 'Geen actieve conversie'
                $ui.txtCurrentInfo.Text = ''
                $ui.pbCurrent.IsIndeterminate = $false
                $ui.pbCurrent.Value     = 0
                Set-Status $txt
                Set-Title 'Batch Converter'
            }
        }
        Request-Save
        Update-Buttons
    }

    # ---------- conversie afgerond ----------------------------------
    $slotConv = $script:Slots['conv']
    if ($slotConv.Handle -ne $null -and $slotConv.Handle.IsCompleted) {

        $emergency = [bool]$sync.EmergencyStop

        # Nu vastleggen: hieronder worden deze vlaggen gewist, en voor de
        # nascan moet ik weten of de gebruiker zelf heeft gestopt.
        $gestopt = ([bool]$sync.Cancel -or [bool]$sync.StopAfterCurrent)

        $sync.ConvBusy         = $false
        $convBusy              = $false
        $sync.StopAfterCurrent = $false
        $sync.Cancel           = $false
        $sync.PauseRequested   = $false
        $sync.IsPaused         = $false
        $script:LastPaused     = $false
        $script:LastStopAfter  = $false

        Clear-Slot 'conv'

        # Wat nog in de wachtrij staat blijft daar staan; alleen de status
        # netjes zetten zodat de lijst leesbaar blijft.
        foreach ($j in (Get-QueueSnapshot)) {
            if ($j -ne $null -and $j.Status -ne 'In wachtrij') { $j.Status = 'In wachtrij' }
        }
        Sync-QueueOrder

        $ui.pbOverall.IsIndeterminate = $false
        $ui.pbCurrent.IsIndeterminate = $false
        $ui.pbCurrent.Value     = 0
        $ui.txtCurrentFile.Text = 'Geen actieve conversie'
        $ui.txtCurrentInfo.Text = ''
        $ui.txtStatus2.Text     = ''

        $svd = [double]$sync.OrigBytes - [double]$sync.NewBytes
        $eind = ("Gereed. {0} geslaagd, {1} mislukt, {2} met aandacht. Nog {3} in de wachtrij. Rekentijd {4}. Bespaard {5}." -f `
            $sync.Success, $sync.Failed, $sync.Warned, $sync.Queue.Count,
            (Format-Span ([double]$sync.ActiveSec)), (Format-Size $svd))

        if ($ui.ContainsKey('taskbar')) {
            try { $ui.taskbar.ProgressState = 'None'; $ui.taskbar.ProgressValue = 0 } catch { }
        }

        Save-Settings

        # De conversie is klaar - hoe dan ook, ook na een stop of een
        # noodstop. De pc hoeft niet langer wakker gehouden te worden, en
        # dit moet gebeuren VOOR de afsluitteller hieronder.
        Stop-KeepAwake

        if ($emergency) {
            # ---- NOODSTOP: nooit afsluiten, hoe het vinkje ook staat --
            $files = New-Object System.Collections.ArrayList
            $one = ''
            while ($sync.EmergencyFiles.TryDequeue([ref]$one)) { [void]$files.Add($one) }

            $detail = ''
            if ($files.Count -gt 0) { $detail = "`n`n" + (($files | Select-Object -Last 5) -join "`n") }

            Set-Status ("GESTOPT na {0} fouten op rij. {1}" -f $script:MaxFailStreak, $eind)
            Set-Title 'GESTOPT na fouten'

            [System.Windows.MessageBox]::Show(
                ("De conversie is automatisch gestopt: {0} keer op rij ging het fout.`n`nEr is vermoedelijk iets structureel mis - bijvoorbeeld een share die read-only is geworden, een volle schijf, of een werkmap die niet beschikbaar is.`n`nDe rest van de wachtrij ({1} bestand(en)) blijft staan. Los de oorzaak op en druk opnieuw op Start.{2}" -f `
                    $script:MaxFailStreak, $sync.Queue.Count, $detail),
                'Gestopt na drie fouten op rij', 'OK', 'Warning') | Out-Null
        }
        else {
            Set-Status $eind
            Set-Title 'gereed'

            # ---- nog een keer rondkijken -----------------------------
            #  Alleen als er tijdens deze ronde ergens een lock van een
            #  andere pc is gezien, en alleen als de gebruiker niet zelf
            #  heeft gestopt. Start-Nascan doet het hoogstens een keer.
            #
            #  Dit staat bewust VOOR de afsluitteller: die wacht vanzelf
            #  op een lopende scan, en vervalt zodra de conversie weer
            #  aanslaat.
            $nascan = $false
            if (-not $gestopt -and [bool]$sync.LockGezien) {
                $nascan = Start-Nascan
            }

            # ---- afsluiten na stop, als dat is aangevinkt -----------
            if (-not $nascan -and [bool]$ui.chkExitAfter.IsChecked) {
                $script:ExitAt      = (Get-Date).AddSeconds(10)
                $script:ExitPending = $true
                Write-Log 'Afsluiten na conversie is aangevinkt; het programma sluit over 10 seconden.' 'WAARS'
            }
        }

        Update-Buttons
    }

    # ---------- aftellen naar afsluiten -----------------------------
    if ($script:ExitAt -ne $null) {

        if ($sync.ConvBusy) {
            # er loopt weer een conversie: afsluiten vervalt
            $script:ExitAt = $null
            $script:ExitPending = $false
            Write-Log 'Afsluiten geannuleerd: er loopt weer een conversie.' 'WAARS'
            Update-Buttons
        }
        elseif ($sync.ScanBusy) {
            # er loopt nog een scan: niet afbreken, maar wachten tot die
            # klaar is en de aftelling daarna opnieuw laten lopen
            $script:ExitAt = (Get-Date).AddSeconds(10)
            $ui.txtStatus2.Text = 'afsluiten wacht tot de scan klaar is'
        }
        else {
            $left = [int][Math]::Ceiling((($script:ExitAt) - (Get-Date)).TotalSeconds)
            if ($left -lt 0) { $left = 0 }
            $ui.btnStopNow.IsEnabled = $true
            $ui.btnStopNow.Content   = "Afsluiten annuleren ($left)"
            $ui.txtStatus2.Text      = "het programma sluit over $left seconden"

            if ($left -le 0) {
                $script:ExitAt = $null
                Write-Log 'Afsluiten na conversie.' 'WAARS'
                Save-Settings
                try { $timer.Stop() } catch { }
                $win.Close()
                return
            }
        }
    }

    # elke ~2 s de selectie-info bijwerken
    if (($script:TickCount % 5) -eq 0) { Update-SelectionInfo }
}

# Een fout in een enkele slag mag de klok niet stilzetten; anders zou de
# hele weergave bevriezen terwijl de conversie doorloopt.
$timer.Add_Tick({
    try {
        Invoke-Tick
    }
    catch {
        $script:TickErrors = $script:TickErrors + 1
        if ($script:TickErrors -le 25) {
            try {
                $ui.txtLog.AppendText(('[{0}] FOUT  fout in GUI-verversing: {1}' -f `
                    (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message) + "`r`n")
            } catch { }
        }
    }
})

# ---------------------------------------------------------------------
# 17.  Vensterafhandeling
# ---------------------------------------------------------------------

# ---------------------------------------------------------------------
#  Postbus: opdrachten van een tweede aanroep
#
#  Een tweede aanroep met -In/-Out schrijft een klein json-bestandje in
#  de map 'opdrachten' en sluit zichzelf af. Hier wordt die map om de twee
#  seconden bekeken. Niet elke tik: dat zou 150 keer per minuut een
#  mapuitlezing zijn voor iets wat zelden gebeurt.
#
#  Het probewerk (duur, codec, grootte) gebeurt in de scan-worker en niet
#  hier, want een bestand op een trage share mag het venster niet ophouden.
# ---------------------------------------------------------------------
$script:InboxLaatst = [DateTime]::MinValue

function Read-Inbox {

    if ((Get-Date) - $script:InboxLaatst -lt [TimeSpan]::FromSeconds(2)) { return }
    $script:InboxLaatst = Get-Date

    if (-not (Test-PathSafe $InboxDir -Container)) { return }

    $bestanden = @()
    try { $bestanden = @(Get-ChildItem -LiteralPath $InboxDir -File -Filter 'opdracht_*.json' -ErrorAction SilentlyContinue) }
    catch { return }
    if ($bestanden.Count -lt 1) { return }

    # De scan-worker kan maar een ding tegelijk. Is die bezig, dan blijven
    # de opdrachten gewoon liggen tot de volgende ronde.
    if ($sync.ScanBusy) { return }

    $opdrachten = New-Object System.Collections.ArrayList
    foreach ($b in $bestanden) {
        try {
            $j = (Get-Content -Raw -LiteralPath $b.FullName -ErrorAction Stop) | ConvertFrom-Json
            if ($j -and $j.In) {
                [void]$opdrachten.Add([pscustomobject]@{ In = [string]$j.In; Out = [string]$j.Out })
                Write-Log ("Opdracht ontvangen: {0}{1}" -f $j.In, $(if ($j.Out) { " -> $($j.Out)" } else { '' }))
            }
        }
        catch { Write-Log ("Onleesbare opdracht {0}: {1}" -f $b.Name, $_.Exception.Message) 'WAARS' }

        # Ook een onleesbare opdracht weghalen, anders blijft hij elke
        # ronde opnieuw langskomen.
        try { Remove-Item -LiteralPath $b.FullName -Force -ErrorAction Stop } catch { }
    }

    if ($opdrachten.Count -lt 1) { return }

    $sync.ScanMode        = 'opdracht'
    $sync.ScanSettings    = @{ Jobs = @($opdrachten.ToArray()) }
    $sync.ScanCancel      = $false
    $sync.ScanTotal       = $opdrachten.Count
    $sync.ScanChecked     = 0
    $sync.ScanFound       = 0
    $sync.ScanSkippedHevc = 0
    $sync.ScanSkippedVcp  = 0
    $sync.ScanSkippedNoVid= 0
    $sync.ScanStatus      = 'Opdrachten verwerken…'
    Start-Worker $ScanWorker 'scan'
    Update-Buttons
}

$win.Add_Loaded({

    Set-Title 'Batch Converter'
    Write-Log ('{0}  -  gestart {1}' -f $AppStamp, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Log ('Script: {0}' -f $PSCommandPath)
    Write-Log ('Instellingen en logboek: {0}' -f $DataDir)

    # Uitgeweken naar een andere plek omdat de oorspronkelijke niet
    # bruikbaar was? Zeg dat, anders staat er ineens een ander pad zonder
    # uitleg.
    if ($script:WorkDirFallback) {
        Write-Log ("De bewaarde werkmap {0} is niet bruikbaar op deze machine; er wordt {1} gebruikt." -f `
            $script:WorkDirFallback.Oud, $script:WorkDirFallback.Nieuw) 'WAARS'
    }
    if ($DataDir -ne $ScriptDir) {
        Write-Log ("De map naast het script is niet beschrijfbaar; instellingen en logboek staan in {0}." -f $DataDir) 'WAARS'
    }
    if ($script:WindowMoved) {
        Write-Log 'De bewaarde vensterpositie lag buiten het huidige beeld (scherm uit of losgekoppeld); het venster is teruggeschoven.' 'WAARS'
    }

    if (Test-Ffmpeg) {
        $ui.txtFfmpegState.Text = 'ffmpeg: gevonden in scriptmap'
        $ui.txtFfmpegState.Foreground = $win.FindResource('Ok')
    } else {
        $ui.txtFfmpegState.Text = 'ffmpeg: niet gevonden'
        $ui.txtFfmpegState.Foreground = $win.FindResource('Warn')
    }

    Write-Log '============================================================'
    Write-Log 'Video naar H.265 / HEVC - batch converter gestart.'
    Write-Log "Scriptmap: $ScriptDir"
    Write-Log "Werkmap  : $($ui.txtWork.Text)"
    Write-Log '============================================================'

    # Bewaarde lijst en wachtrij terugzetten - alleen als dat aanstaat.
    # Standaard staat het uit: bij het opstarten hoort de lijst leeg te
    # zijn, zodat een nieuwe scan niet bij de resten van de vorige keer
    # komt te staan.
    if ($script:RestoreQueue) {
        try {
            Restore-SavedQueue $script:SavedSettings
            Sync-QueueOrder
            if ($jobs.Count -gt 0) { Start-VerifyRound }
        }
        catch {
            Write-Log "Bewaarde lijst kon niet worden teruggezet: $($_.Exception.Message)" 'WAARS'
        }
    }
    else {
        $bewaard = 0
        if ($script:SavedSettings -and $script:SavedSettings.Queue) { $bewaard = @($script:SavedSettings.Queue).Count }
        if ($bewaard -gt 0) {
            Write-Log ("De lijst begint leeg. Er stonden nog {0} regel(s) van de vorige keer in het instellingenbestand; die worden bij de eerstvolgende keer opslaan weggeschreven als lege lijst. Zet RestoreQueue op true om de wachtrij wel te bewaren." -f $bewaard)
        }
    }

    # Zelf met -In gestart: die opdracht gaat door dezelfde postbus als een
    # tweede aanroep. Zo is er maar een weg naar binnen, en die is getest.
    if (-not [string]::IsNullOrWhiteSpace($In)) {
        if (Write-Opdracht -InPad $In -UitPad $Out) {
            Write-Log ("Opdracht van de opdrachtregel: {0}{1}" -f $In, $(if ($Out) { " -> $Out" } else { '' }))
        } else {
            Write-Log ("De opdracht van de opdrachtregel kon niet worden opgeslagen: {0}" -f $In) 'WAARS'
        }
    }

    # ---- wat heeft de updater bij deze start gedaan? ---------------
    #
    #  Bijwerken.ps1 draait vanuit de starter, in een venster dat binnen
    #  een seconde weg is. Zonder dit stukje is er geen enkele manier om
    #  te zien of hij iets heeft gevonden, er niet bij kon, of helemaal
    #  niet is gedraaid - en dat laatste is precies wat er gebeurt als
    #  het programma niet via X265-Converter.cmd wordt gestart.
    $updLog = ''
    foreach ($k in @((Join-Path $ScriptDir 'X265-Bijwerken.log'),
                     (Join-Path $DataDir  'X265-Bijwerken.log'),
                     (Join-Path (Join-Path $env:LOCALAPPDATA 'X265-Converter') 'X265-Bijwerken.log'))) {
        if ($k -and (Test-PathSafe $k)) { $updLog = $k; break }
    }

    if (-not $updLog) {
        Write-Log 'Bijwerken: nog nooit gedraaid. Start via X265-Converter.cmd om automatisch bij te werken.' 'WAARS'
    }
    else {
        $verse = $false
        try { $verse = ((Get-Date) - (Get-Item -LiteralPath $updLog).LastWriteTime).TotalMinutes -lt 5 } catch { }

        if (-not $verse) {
            Write-Log ('Bijwerken: is bij deze start niet gedraaid. Start via X265-Converter.cmd, anders blijft deze pc op de huidige versie staan. Logboek: {0}' -f $updLog) 'WAARS'
        }
        else {
            try {
                $regels = @(Get-Content -LiteralPath $updLog -Tail 40 -ErrorAction Stop)
                # alleen de laatste ronde tonen
                $start = -1
                for ($i = $regels.Count - 1; $i -ge 0; $i--) {
                    if ($regels[$i] -match 'bijwerken gestart') { $start = $i; break }
                }
                if ($start -ge 0) { $regels = $regels[$start..($regels.Count - 1)] }
                foreach ($r in $regels) {
                    $t = ([string]$r)
                    if ($t.Length -gt 20) { $t = $t.Substring(20) } else { $t = $t.Trim() }
                    if ($t) { Write-Log ('Bijwerken: ' + $t) }
                }
            }
            catch { Write-Log ('Bijwerken: logboek kon niet worden gelezen ({0}).' -f $updLog) 'WAARS' }
        }
    }

    # Afsluiten-na-conversie en elk-uur-kijken sluiten elkaar uit; de
    # bewaarde stand kan die combinatie wel bevatten.
    Set-WatchExitCombinatie
    if ([bool]$ui.chkWatch.IsChecked) {
        $script:WatchVanaf = Get-Date
        Write-Log ('Opnieuw kijken staat aan: na {0:N0} uur zonder werk worden de bronmappen opnieuw doorlopen.' -f ($script:WatchMinutes / 60.0))
    }

    $ui.stTotals.Text = Format-Totals
    Update-Buttons
    $timer.Start()
})

$win.Add_Closing({
    param($eSender, $eArgs)

    if ($sync.ConvBusy -or $sync.ScanBusy) {
        $a = [System.Windows.MessageBox]::Show(
            "Er loopt nog werk.`n`nAfsluiten breekt de lopende conversie af. De wachtrij blijft bewaard. Doorgaan?",
            'Afsluiten', 'YesNo', 'Warning')
        if ($a -ne 'Yes') { $eArgs.Cancel = $true; return }

        # Wel afsluiten terwijl er nog werk liep: ook dan hoeft de pc niet
        # langer wakker te blijven.
        Stop-KeepAwake

        # De verwijzing NU vastpakken: de werk-thread zet CurrentJob op
        # $null in zijn finally, en dat gebeurt vóórdat ConvBusy op false
        # gaat. Na het wachten hieronder is hij dus altijd al leeg.
        $cur = $sync.CurrentJob

        $sync.Cancel         = $true
        $sync.ScanCancel     = $true
        $sync.PauseRequested = $false

        $p = $sync.CurrentProcess
        if ($p -ne $null) {
            try { [void][X265.NativeProc]::Resume($p.Handle) } catch { }
            try { if (-not $p.HasExited) { $p.Kill() } } catch { }
        }

        $deadline = (Get-Date).AddSeconds(8)
        while (($sync.ConvBusy -or $sync.ScanBusy) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 150 }

        # Het bestand dat onder handen was hoort weer vooraan de wachtrij,
        # zodat het na een herstart als eerste wordt opgepakt. Alleen doen
        # als het niet inmiddels toch is afgerond, en als het nog niet in
        # de rij staat.
        if ($cur -ne $null -and
            $cur.Status -ne 'Geslaagd' -and $cur.Status -ne 'Let op' -and $cur.Status -ne 'Mislukt') {
            try {
                $q = $sync.Queue
                [System.Threading.Monitor]::Enter($q.SyncRoot)
                try {
                    if ($q.IndexOf($cur) -lt 0) {
                        $cur.Status = 'In wachtrij'
                        $cur.Queued = $true
                        $q.Insert(0, $cur)
                    }
                }
                finally { [System.Threading.Monitor]::Exit($q.SyncRoot) }
            } catch { }
        }
    }

    try { $timer.Stop() } catch { }
    Save-Settings -Force
    Clear-AllSlots
})

# ---------------------------------------------------------------------
# 18.  Starten
# ---------------------------------------------------------------------

# Vensterpositie terugzetten voordat het venster in beeld komt. Na het
# tonen zou het zichtbaar verspringen.
if ($script:SavedSettings -ne $null -and $script:SavedSettings.Window -ne $null) {
    Restore-WindowPlacement $script:SavedSettings.Window
}

[void]$win.ShowDialog()

Clear-AllSlots

# De eenmaal-tegelijk-grendel loslaten. Gebeurt dit niet, dan blijft de
# grendel tot het proces echt weg is vasthangen; bij een self-exit die
# nog even nawerkt zou een volgende aanroep zich dan onterecht als
# tweede instantie gedragen.
try {
    if ($script:AppMutex -ne $null) {
        if ($script:IsPrimair) { try { $script:AppMutex.ReleaseMutex() } catch { } }
        $script:AppMutex.Dispose()
        $script:AppMutex = $null
    }
} catch { }
