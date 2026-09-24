
# ---------------------------------------------------------------------
# 15.  Knoppen en gebeurtenissen
# ---------------------------------------------------------------------

$script:EtaRate      = 0.0
$script:EtaFiles     = 0.0
$script:EtaLastCalc  = $null
$script:EtaStamp     = ''
$script:LogLines     = 0
$script:ExitAt       = $null
$script:ExitPending  = $false

# paden die al in de bestandslijst staan (voorkomt dubbele regels bij
# een tweede scan van een overlappende map)
$script:JobPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

# paden die deze sessie al met succes zijn omgezet; die worden bij een
# volgende scan niet opnieuw aangeboden, ook al staat het origineel er
# nog (bijvoorbeeld met "origineel verwijderen" uit)
$script:DonePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

# statussen waarbij een regel op dit moment onder handen is
$script:ActiveStatus = @('Encoderen','Herpoging','Verplaatsen','Origineel wissen','Ondertitels')

# voorkomt dat het bijwerken van een vinkje zichzelf opnieuw aanroept
$script:InIncludeChange = $false

# ---------------------------------------------------------------------
#  Vensterpositie bewaren en terugzetten
#
#  Het lastige is niet het bewaren maar het terugzetten. Een positie die
#  gisteren klopte kan vandaag buiten beeld liggen: een tweede scherm dat
#  uit staat, een laptop die van dock af is, een monitor die links van de
#  hoofdmonitor hing (negatieve X) en er niet meer is. Zonder controle
#  start het programma dan onzichtbaar op, en dan lijkt het kapot.
#
#  Daarom wordt een teruggezette positie altijd getoetst aan het scherm
#  zoals het NU is, en zo nodig teruggeschoven. De maten komen van
#  SystemParameters: die staan in dezelfde eenheden als $win.Left en
#  $win.Top. Via System.Windows.Forms.Screen zou het per monitor kunnen,
#  maar dat levert fysieke pixels op en dat gaat mis zodra er ergens een
#  schaling van 125% of 150% aanstaat.
# ---------------------------------------------------------------------
$script:WindowMoved = $false

function Get-WindowPlacement {
    try {
        if ($win -eq $null) { return $null }

        $max = ($win.WindowState -eq 'Maximized')
        $l = 0.0; $t = 0.0; $w = 0.0; $h = 0.0

        if ($win.WindowState -eq 'Normal') {
            $l = [double]$win.Left; $t = [double]$win.Top
            $w = [double]$win.Width; $h = [double]$win.Height
        }
        else {
            # Geminimaliseerd of gemaximaliseerd: Left/Top zijn dan
            # onbruikbaar (-32000 bij minimaliseren). RestoreBounds geeft
            # de plek waar het venster naartoe gaat als het weer normaal
            # wordt, en dat is precies wat we willen bewaren.
            $rb = $win.RestoreBounds
            if ($rb -eq $null -or $rb.Width -le 0 -or $rb.Height -le 0) { return $null }
            $l = [double]$rb.Left; $t = [double]$rb.Top
            $w = [double]$rb.Width; $h = [double]$rb.Height
        }

        foreach ($v in @($l,$t,$w,$h)) {
            if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { return $null }
        }
        if ($w -le 0 -or $h -le 0) { return $null }

        return [pscustomobject]@{
            Left      = [int][Math]::Round($l)
            Top       = [int][Math]::Round($t)
            Width     = [int][Math]::Round($w)
            Height    = [int][Math]::Round($h)
            Maximized = [bool]$max
        }
    }
    catch { return $null }
}

function Restore-WindowPlacement {
    param($Saved)

    if ($Saved -eq $null) { return }

    $l = 0.0; $t = 0.0; $w = 0.0; $h = 0.0
    $okAll = $true
    foreach ($paar in @(@('Left',[ref]$l), @('Top',[ref]$t), @('Width',[ref]$w), @('Height',[ref]$h))) {
        $ruw = $Saved.($paar[0])
        if ($ruw -eq $null) { $okAll = $false; break }
        $d = 0.0
        if (-not [double]::TryParse([string]$ruw, [Globalization.NumberStyles]::Float,
                                    [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { $okAll = $false; break }
        $paar[1].Value = $d
    }
    if (-not $okAll) { return }
    if ($w -le 0 -or $h -le 0) { return }

    # het scherm zoals het NU is (alle monitors samen)
    $vL = [double][System.Windows.SystemParameters]::VirtualScreenLeft
    $vT = [double][System.Windows.SystemParameters]::VirtualScreenTop
    $vW = [double][System.Windows.SystemParameters]::VirtualScreenWidth
    $vH = [double][System.Windows.SystemParameters]::VirtualScreenHeight
    if ($vW -le 0 -or $vH -le 0) { return }
    $vR = $vL + $vW
    $vB = $vT + $vH

    # nooit groter dan wat er nu aan schermruimte is, en nooit kleiner dan
    # het venster zelf aankan
    if ($w -gt $vW) { $w = $vW }
    if ($h -gt $vH) { $h = $vH }
    if ($w -lt [double]$win.MinWidth)  { $w = [double]$win.MinWidth }
    if ($h -lt [double]$win.MinHeight) { $h = [double]$win.MinHeight }

    $buiten = ($l -lt $vL) -or ($t -lt $vT) -or (($l + $w) -gt $vR) -or (($t + $h) -gt $vB)

    # helemaal binnen het beeld schuiven; past het niet, dan tegen de
    # linkerbovenhoek aan
    if (($l + $w) -gt $vR) { $l = $vR - $w }
    if (($t + $h) -gt $vB) { $t = $vB - $h }
    if ($l -lt $vL) { $l = $vL }
    if ($t -lt $vT) { $t = $vT }

    try {
        $win.WindowStartupLocation = 'Manual'
        $win.Left   = $l
        $win.Top    = $t
        $win.Width  = $w
        $win.Height = $h
        if ($Saved.Maximized) { $win.WindowState = 'Maximized' }
        $script:WindowMoved = $buiten
    }
    catch { }
}

# ---------------------------------------------------------------------
#  KeepAwake stoppen
#
#  Er draait een apart PowerShell-script dat Windows uit de slaapstand
#  houdt zolang er geconverteerd wordt. Dat luistert naar een named event;
#  zodra dat wordt gezet, stopt het. Netjes is: dat signaal geven zodra de
#  conversie klaar is, en in elk geval VOORDAT dit programma zichzelf
#  eventueel afsluit - anders blijft de pc wakker met niemand thuis.
#
#  Draait KeepAwake niet, dan bestaat het event niet en gooit OpenExisting
#  een WaitHandleCannotBeOpenedException. Dat is geen fout maar het normale
#  geval, en wordt dus stil afgehandeld.
# ---------------------------------------------------------------------
$script:KeepAwakeStopped = $false

function Stop-KeepAwake {
    param([switch]$Force)

    if ($script:KeepAwakeStopped -and -not $Force) { return }

    $naam = [string]$script:KeepAwakeSignal
    if ([string]::IsNullOrWhiteSpace($naam)) { return }

    $script:KeepAwakeStopped = $true
    try {
        $evt = [System.Threading.EventWaitHandle]::OpenExisting($naam)
        [void]$evt.Set()
        $evt.Dispose()
        Write-Log ("KeepAwake-signaal '{0}' verstuurd; de pc mag weer slapen." -f $naam)
    }
    catch [System.Threading.WaitHandleCannotBeOpenedException] {
        # KeepAwake draait niet; niets te doen en niets te melden
    }
    catch {
        Write-Log ("KeepAwake kon niet worden gestopt: {0}" -f $_.Exception.Message) 'WAARS'
    }
}

# Venstertitel, altijd met het versienummer erachter. Zo is bij een
# schermafdruk of een melding meteen te zien welke versie er draaide.
function Set-Title {
    param([string]$Text = '')
    $t = $AppTitle
    if ($Text) { $t = $t + '  -  ' + $Text }
    try { $win.Title = ('{0}   [v{1}]' -f $t, $AppVersion) } catch { }
}

function Set-Status {
    param([string]$Text)
    $ui.txtStatus.Text = $Text
}

# ---------------------------------------------------------------------
#  WACHTRIJBEHEER
#
#  De wachtrij ($sync.Queue) bevat alleen wat nog te doen staat, in de
#  volgorde waarin het gedaan wordt. De werk-thread pakt telkens de
#  bovenste. De GUI mag de rest vrij herschikken zolang dat onder een
#  lock gebeurt; het bestand dat onder handen is zit niet in de lijst.
#
#  Sync-QueueOrder is de enige plek waar wordt hernummerd. Die functie
#  zet ook de weergavevolgorde gelijk aan de wachtrijvolgorde (regels in
#  de wachtrij bovenaan, in wachtrijvolgorde) en rekent de nog te doen
#  speelduur uit, waardoor "Resterend" en "Klaar omstreeks" binnen één
#  slag meebewegen met elke wijziging.
# ---------------------------------------------------------------------

function Sync-QueueOrder {

    $snapshot = Get-QueueSnapshot

    # ---- hernummeren en nog te doen speelduur -----------------------
    $secs = [double]0
    $i    = 0
    foreach ($j in $snapshot) {
        if ($j -eq $null) { continue }
        $i++
        $j.QueuePos  = $i
        $j.QueueText = ('{0:0000}' -f $i)
        $secs = $secs + [double]$j.DurationSec
    }
    $sync.QueueVideoSec = $secs

    $inQueue = @{}
    foreach ($j in $snapshot) { if ($j -ne $null) { $inQueue[[string]$j.FullPath] = $true } }

    foreach ($j in $jobs) {
        if (-not $inQueue.ContainsKey([string]$j.FullPath)) {
            if ($j.QueueText -ne '') { $j.QueueText = '' }
            $j.QueuePos = 0
        }
    }

    # ---- weergavevolgorde gelijktrekken -----------------------------
    #  Regels in de wachtrij staan bovenaan in wachtrijvolgorde; de rest
    #  blijft in de bestaande onderlinge volgorde daaronder.
    $target = New-Object System.Collections.ArrayList
    foreach ($j in $snapshot) { if ($j -ne $null) { [void]$target.Add($j) } }
    foreach ($j in $jobs) {
        if (-not $inQueue.ContainsKey([string]$j.FullPath)) { [void]$target.Add($j) }
    }

    for ($k = 0; $k -lt $target.Count; $k++) {
        $want = $target[$k]
        if ($k -ge $jobs.Count) { break }
        if ([object]::ReferenceEquals($jobs[$k], $want)) { continue }
        $from = $jobs.IndexOf($want)
        if ($from -ge 0 -and $from -ne $k) { $jobs.Move($from, $k) }
    }

    Update-SelectionInfo
    Request-Save
}

function Add-ToQueueBack {
    param($JobList)

    $added = 0
    $q = $sync.Queue
    [System.Threading.Monitor]::Enter($q.SyncRoot)
    try {
        foreach ($j in $JobList) {
            if ($j -eq $null) { continue }
            if ($j.IsHevc) { continue }
            if ($j.Queued) { continue }
            $j.Status     = 'In wachtrij'
            $j.ResultText = ''
            $j.NewSizeText= ''
            $j.NewBytes   = 0
            $j.Queued     = $true
            [void]$q.Add($j)
            $added++
        }
    }
    finally { [System.Threading.Monitor]::Exit($q.SyncRoot) }

    if ($added -gt 0) { Sync-QueueOrder }
    return $added
}

function Remove-FromQueue {
    param($JobList)

    $removed = 0
    $q = $sync.Queue
    [System.Threading.Monitor]::Enter($q.SyncRoot)
    try {
        foreach ($j in $JobList) {
            if ($j -eq $null) { continue }
            $idx = $q.IndexOf($j)
            if ($idx -ge 0) {
                $q.RemoveAt($idx)
                $j.Queued = $false
                $removed++
            }
        }
    }
    finally { [System.Threading.Monitor]::Exit($q.SyncRoot) }

    if ($removed -gt 0) { Sync-QueueOrder }
    return $removed
}

function Move-InQueue {
    param($JobList, [ValidateSet('top','bottom')][string]$Where)

    # Alleen regels die daadwerkelijk in de wachtrij staan; de onderlinge
    # volgorde van de selectie blijft behouden.
    $moved = 0
    $q = $sync.Queue
    [System.Threading.Monitor]::Enter($q.SyncRoot)
    try {
        $picked = New-Object System.Collections.ArrayList
        foreach ($j in @($q.ToArray())) {
            foreach ($sel in $JobList) {
                if ([object]::ReferenceEquals($j, $sel)) { [void]$picked.Add($j); break }
            }
        }
        if ($picked.Count -eq 0) { return 0 }

        foreach ($j in $picked) {
            $idx = $q.IndexOf($j)
            if ($idx -ge 0) { $q.RemoveAt($idx) }
        }

        if ($Where -eq 'top') {
            $ins = 0
            foreach ($j in $picked) { $q.Insert($ins, $j); $ins++ }
        } else {
            foreach ($j in $picked) { [void]$q.Add($j) }
        }
        $moved = $picked.Count
    }
    finally { [System.Threading.Monitor]::Exit($q.SyncRoot) }

    if ($moved -gt 0) { Sync-QueueOrder }
    return $moved
}

# ---------------------------------------------------------------------
#  Reageren op het aan- en uitvinken van een regel
#
#  Het vinkje in de DataGrid loopt niet via een knop-handler, dus wordt
#  hier op de PropertyChanged van Include gehangen. Aanvinken zet de
#  regel ACHTERAAN de wachtrij, uitvinken haalt hem eruit; in beide
#  gevallen wordt meteen hernummerd en de resterende tijd bijgesteld.
# ---------------------------------------------------------------------

$script:JobPropChanged = {
    param($eSender, $eArgs)
    try {
        if ($eArgs.PropertyName -ne 'Include') { return }
        if ($script:InIncludeChange) { return }
        $script:InIncludeChange = $true
        try {
            $job = $eSender
            if ($job -eq $null) { return }

            if ($job.Include) {
                if (-not $job.Queued -and -not $job.IsHevc) {
                    [void](Add-ToQueueBack @($job))
                }
            }
            else {
                # Een regel die op dit moment onder handen is laten we staan.
                if ($script:ActiveStatus -notcontains $job.Status) {
                    [void](Remove-FromQueue @($job))
                    if ($job.Status -eq 'In wachtrij') { $job.Status = 'Niet in wachtrij' }
                }
            }
        }
        finally { $script:InIncludeChange = $false }
    }
    catch { }
}

# PowerShell maakt bij elke omzetting van een scriptblok een NIEUWE
# delegate. Voor remove_PropertyChanged moet het exact dezelfde instantie
# zijn, dus die wordt hier één keer gemaakt en hergebruikt.
$script:JobPropDelegate = [System.ComponentModel.PropertyChangedEventHandler]$script:JobPropChanged

function Register-JobEvents {
    param($Job)
    try { $Job.add_PropertyChanged($script:JobPropDelegate) } catch { }
}

function Unregister-JobEvents {
    param($Job)
    try { $Job.remove_PropertyChanged($script:JobPropDelegate) } catch { }
}

function Update-SelectionInfo {

    $total   = $jobs.Count
    $checked = 0
    $pending = 0
    $bytes   = [double]0
    $secs    = [double]0

    foreach ($j in $jobs) {
        if (-not $j.Include) { continue }
        $checked++
        if (-not $j.Queued) {
            $pending++
            $bytes = $bytes + $j.SizeBytes
            $secs  = $secs  + $j.DurationSec
        }
    }

    $qCount = $sync.Queue.Count

    if ($pending -gt 0) {
        $ui.txtSelInfo.Text = ("{0} regels  -  {1} in de wachtrij  -  {2} nog toe te voegen ({3}, {4})" -f `
            $total, $qCount, $pending, (Format-Size $bytes), (Format-Span $secs))
    } else {
        $ui.txtSelInfo.Text = ("{0} regels  -  {1} in de wachtrij" -f $total, $qCount)
    }

    $ui.btnStart.IsEnabled = (($pending -gt 0) -or ($qCount -gt 0 -and -not $sync.ConvBusy))
}

function Update-Buttons {

    $scanBusy = [bool]$sync.ScanBusy
    $convBusy = [bool]$sync.ConvBusy

    # Scannen mag ook terwijl er wordt geëncodeerd.
    $ui.btnScan.IsEnabled = $true
    if ($scanBusy) { $ui.btnScan.Content = 'Scan stoppen' } else { $ui.btnScan.Content = '1.  Scannen' }

    # De encoder-instellingen liggen vast zolang er een conversie loopt;
    # de bronmap- en scaninstellingen blijven vrij.
    foreach ($n in @('cmbCodec','cmbPreset','sldCrf','cmbAudio','txtWork','btnCleanTemp',
                     'chkDeleteOrig','chkSubs')) {
        if ($ui.ContainsKey($n)) { $ui[$n].IsEnabled = -not $convBusy }
    }

    if ($convBusy) { $ui.btnStart.Content = '2.  Toevoegen aan wachtrij' }
    else           { $ui.btnStart.Content = '2.  Start conversie' }

    $ui.btnPause.IsEnabled     = $convBusy
    $ui.btnStopAfter.IsEnabled = $convBusy

    # Hernoemen alleen als er niets loopt: een conversie leunt op de namen
    # (en op de locks naast de bron), een scan zou half oude namen zien.
    $hernoemBezig = $scanBusy -and (([string]$sync.ScanMode) -like 'hernoem*')
    $ui.btnRename.IsEnabled = (-not $scanBusy) -and (-not $convBusy)
    $ui.btnStart.IsEnabled  = -not $hernoemBezig

    if ($script:ExitAt -ne $null) {
        # tijdens de aftelling is dit de annuleerknop; het opschrift komt
        # uit de klok, dus hier alleen inschakelen
        $ui.btnStopNow.IsEnabled = $true
    } else {
        $ui.btnStopNow.IsEnabled = $convBusy
        $ui.btnStopNow.Content   = 'Stop direct'
    }

    $ui.btnToTop.IsEnabled    = ($sync.Queue.Count -gt 0)
    $ui.btnToBottom.IsEnabled = ($sync.Queue.Count -gt 0)

    if ([bool]$sync.PauseRequested) { $ui.btnPause.Content = 'Hervatten' } else { $ui.btnPause.Content = 'Pauze' }

    # "Stop na huidige" is een schakelaar: hij kan ook weer uit.
    if ($sync.StopAfterCurrent) {
        $ui.btnStopAfter.Content = 'Stop na huidige: AAN'
        $ui.btnStopAfter.ToolTip = 'Klik om het stoppen weer in te trekken; de conversie gaat dan gewoon verder met de bovenste uit de wachtrij.'
    } else {
        $ui.btnStopAfter.Content = 'Stop na huidige'
        $ui.btnStopAfter.ToolTip = 'Maakt het lopende bestand af en start daarna niets meer. Kan weer uitgezet worden.'
    }

    Update-SelectionInfo
}

# ---- bronmappen -----------------------------------------------------

$ui.btnBrowse.Add_Click({ Show-FolderPicker })

$ui.btnAddPath.Add_Click({
    Add-Folder $ui.txtPath.Text
    $ui.txtPath.Text = ''
})

$ui.txtPath.Add_KeyDown({
    param($eSender, $eArgs)
    if ($eArgs.Key -eq [System.Windows.Input.Key]::Return) {
        Add-Folder $ui.txtPath.Text
        $ui.txtPath.Text = ''
    }
})

$ui.btnRemoveFolder.Add_Click({
    $sel = @($ui.lstFolders.SelectedItems)
    foreach ($s in $sel) { $ui.lstFolders.Items.Remove($s) }
})

$ui.btnClearFolders.Add_Click({ $ui.lstFolders.Items.Clear() })

$ui.lstFolders.Add_PreviewDragOver({
    param($eSender, $eArgs)
    if ($eArgs.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $eArgs.Effects = [System.Windows.DragDropEffects]::Copy
    } else {
        $eArgs.Effects = [System.Windows.DragDropEffects]::None
    }
    $eArgs.Handled = $true
})

$ui.lstFolders.Add_Drop({
    param($eSender, $eArgs)
    if ($eArgs.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        foreach ($p in @($eArgs.Data.GetData([System.Windows.DataFormats]::FileDrop))) {
            if (Test-PathSafe $p -Container) { Add-Folder $p }
            else { Add-Folder ([IO.Path]::GetDirectoryName($p)) }
        }
    }
    $eArgs.Handled = $true
})

# ---- instellingen ---------------------------------------------------

$ui.cmbCodec.Add_SelectionChanged({ Fill-Presets })
$ui.sldCrf.Add_ValueChanged({ $ui.txtCrf.Text = [string][int]$ui.sldCrf.Value })

$ui.btnCleanTemp.Add_Click({
    $wd = $ui.txtWork.Text
    if (-not (Test-PathSafe $wd -Container)) {
        [System.Windows.MessageBox]::Show("Werkmap bestaat niet of is niet toegankelijk:`n$wd", 'Werkmap', 'OK', 'Warning') | Out-Null
        return
    }
    # Losse bestanden EN de x265_pre_*-mappen waarin een bron lokaal is
    # gezet. Die laatste zijn zo groot als het bronbestand, dus juist die
    # wil je hier zien.
    $old  = @(Get-ChildItem -LiteralPath $wd -File -Filter 'x265_*' -ErrorAction SilentlyContinue)
    $mapn = @(Get-ChildItem -LiteralPath $wd -Directory -Filter 'x265_pre_*' -ErrorAction SilentlyContinue)

    $sz = 0
    if ($old.Count -gt 0) { $sz = ($old | Measure-Object -Property Length -Sum).Sum }
    foreach ($m in $mapn) {
        try { $sz += (Get-ChildItem -LiteralPath $m.FullName -File -Recurse -ErrorAction SilentlyContinue |
                      Measure-Object -Property Length -Sum).Sum } catch { }
    }

    if ($old.Count -eq 0 -and $mapn.Count -eq 0) {
        Set-Status 'Geen achtergebleven tijdelijke bestanden gevonden.'
        return
    }

    $wat = @()
    if ($old.Count  -gt 0) { $wat += ("{0} bestand(en)" -f $old.Count) }
    if ($mapn.Count -gt 0) { $wat += ("{0} map(pen) met een lokale kopie" -f $mapn.Count) }

    $a = [System.Windows.MessageBox]::Show(
        ("Achtergebleven: {0} ({1}).`n`nVerwijderen?" -f ($wat -join ' en '), (Format-Size $sz)),
        'Werkmap opruimen', 'YesNo', 'Question')
    if ($a -eq 'Yes') {
        $n = 0
        foreach ($f in $old)  { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n++ } catch { } }
        foreach ($m in $mapn) { try { Remove-Item -LiteralPath $m.FullName -Recurse -Force -ErrorAction Stop; $n++ } catch { } }
        Set-Status "$n item(s) opgeruimd."
        Write-Log "$n achtergebleven item(s) verwijderd uit $wd"
    }
})

# ---- bestandslijst --------------------------------------------------

function Remove-JobRow {
    param($Job)

    if ($Job -eq $null) { return $false }
    if ($script:ActiveStatus -contains $Job.Status) { return $false }

    [void](Remove-FromQueue @($Job))

    [void]$script:JobPaths.Remove([string]$Job.FullPath)
    Unregister-JobEvents $Job
    [void]$jobs.Remove($Job)
    return $true
}

function Set-Include {
    param([bool]$Value, [bool]$OnlySelected)

    if ($OnlySelected) { $target = @($ui.grid.SelectedItems) } else { $target = @($jobs) }

    # Bij een hele lijst zou het per regel bijwerken van de wachtrij
    # kwadratisch worden; daarom de melding per regel onderdrukken en de
    # wachtrij in één keer bijwerken.
    $touched = New-Object System.Collections.ArrayList

    $script:InIncludeChange = $true
    try {
        foreach ($j in $target) {
            if ($j -eq $null) { continue }
            if ($Value -and $j.IsHevc) { continue }   # al HEVC: nooit aanvinken
            if ([bool]$j.Include -eq $Value) { continue }
            $j.Include = $Value
            [void]$touched.Add($j)
        }
    }
    finally { $script:InIncludeChange = $false }

    if ($touched.Count -eq 0) { Update-SelectionInfo; return }

    if ($Value) {
        [void](Add-ToQueueBack $touched)
    } else {
        $drop = New-Object System.Collections.ArrayList
        foreach ($j in $touched) {
            if ($script:ActiveStatus -notcontains $j.Status) {
                [void]$drop.Add($j)
                if ($j.Status -eq 'In wachtrij') { $j.Status = 'Niet in wachtrij' }
            }
        }
        [void](Remove-FromQueue $drop)
    }
    Sync-QueueOrder
}

$ui.btnCheckAll.Add_Click(  { Set-Include $true  $false })
$ui.btnUncheckAll.Add_Click({ Set-Include $false $false })
$ui.btnCheckSel.Add_Click(  { Set-Include $true  $true  })
$ui.btnUncheckSel.Add_Click({ Set-Include $false $true  })

$ui.btnToTop.Add_Click({
    $sel = @($ui.grid.SelectedItems)
    if ($sel.Count -eq 0) { Set-Status 'Geen regels geselecteerd.'; return }
    $n = Move-InQueue $sel 'top'
    if ($n -gt 0) { Set-Status "$n regel(s) bovenaan de wachtrij gezet." }
    else { Set-Status 'Geen van de geselecteerde regels staat in de wachtrij.' }
})

$ui.btnToBottom.Add_Click({
    $sel = @($ui.grid.SelectedItems)
    if ($sel.Count -eq 0) { Set-Status 'Geen regels geselecteerd.'; return }
    $n = Move-InQueue $sel 'bottom'
    if ($n -gt 0) { Set-Status "$n regel(s) onderaan de wachtrij gezet." }
    else { Set-Status 'Geen van de geselecteerde regels staat in de wachtrij.' }
})

$ui.btnRemoveSel.Add_Click({
    $sel = @($ui.grid.SelectedItems)
    if ($sel.Count -eq 0) { Set-Status 'Geen regels geselecteerd.'; return }
    $n = 0; $skip = 0
    foreach ($j in $sel) { if (Remove-JobRow $j) { $n++ } else { $skip++ } }
    Update-SelectionInfo
    if ($skip -gt 0) { Set-Status "$n regel(s) uit de lijst gehaald; $skip regel(s) zijn nu onder handen en blijven staan." }
    else             { Set-Status "$n regel(s) uit de lijst gehaald." }
})

$ui.btnClearList.Add_Click({
    $n = 0; $skip = 0
    foreach ($j in @($jobs)) { if (Remove-JobRow $j) { $n++ } else { $skip++ } }
    $script:DonePaths.Clear()
    Update-SelectionInfo
    if ($skip -gt 0) { Set-Status "$n regel(s) gewist; $skip regel(s) zijn onder handen en blijven staan." }
    else             { Set-Status 'Lijst gewist.' }
})

# ---- log ------------------------------------------------------------

$ui.btnClearLog.Add_Click({ $ui.txtLog.Clear(); $script:LogLines = 0 })

$ui.btnSaveLog.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter   = 'Tekstbestand (*.log)|*.log|Alle bestanden (*.*)|*.*'
    $dlg.FileName = 'x265-conversie_{0}.log' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss')
    $dlg.InitialDirectory = $ScriptDir
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            Set-Content -LiteralPath $dlg.FileName -Value $ui.txtLog.Text -Encoding UTF8 -Force
            Set-Status "Log opgeslagen: $($dlg.FileName)"
        } catch {
            [System.Windows.MessageBox]::Show("Opslaan mislukt:`n$($_.Exception.Message)", 'Fout', 'OK', 'Error') | Out-Null
        }
    }
    $dlg.Dispose()
})

# ---- instellingen uitlezen ------------------------------------------

# Start de conversie als die nog niet loopt. Gebruikt voor opdrachten van
# de opdrachtregel: die horen gewoon te gaan draaien, zonder dat er eerst
# op Start hoeft te worden geklikt. Loopt er al een conversie, dan staat
# het bestand nu in de wachtrij en pakt de worker het vanzelf op.
function Start-ConversionIfIdle {

    if ($sync.ConvBusy) { return }
    # Niet midden in het hernoemen van de bronmappen beginnen.
    if ([bool]$sync.ScanBusy -and ([string]$sync.ScanMode) -like 'hernoem*') { return }
    if ($sync.Queue.Count -lt 1) { return }

    $st = Get-ConvertSettings

    if (-not (Test-DirWritable $st.WorkDir)) {
        $terug = Join-Path $env:TEMP 'X265-Converter'
        if (Test-DirWritable $terug) {
            Write-Log ("Werkmap {0} is niet bruikbaar; uitgeweken naar {1}." -f $st.WorkDir, $terug) 'WAARS'
            $ui.txtWork.Text = $terug
            $st.WorkDir      = $terug
        }
        else {
            Write-Log ("Werkmap {0} is niet bruikbaar en er is geen alternatief; opdracht blijft in de wachtrij staan." -f $st.WorkDir) 'FOUT'
            return
        }
    }

    if (-not (Resolve-Ffmpeg)) {
        Write-Log 'ffmpeg ontbreekt; de opdracht blijft in de wachtrij staan.' 'FOUT'
        return
    }

    $script:KeepAwakeStopped = $false

    $sync.Settings         = $st
    $sync.Cancel           = $false
    $sync.StopAfterCurrent = $false
    $sync.PauseRequested   = $false
    $sync.IsPaused         = $false
    $sync.FailStreak       = 0
    $sync.EmergencyStop    = $false

    $dump = ''
    while ($sync.EmergencyFiles.TryDequeue([ref]$dump)) { }

    $script:ExitPending = $false

    Write-Log 'Conversie gestart vanuit een opdracht op de opdrachtregel.'
    Start-Worker $ConvertWorker 'conv'
    Update-Buttons
}

function Get-ScanSettings {
    param([bool]$AutoQueue = $false)
    return @{
        Folders    = @($ui.lstFolders.Items | ForEach-Object { [string]$_ })
        Extensions = @($ui.txtExt.Text -split '[,;\s]+' | Where-Object { $_.Trim().Length -gt 0 })
        Recursive  = [bool]$script:Recursive
        VcpMarker  = [string]$script:VcpMarker
        LockStaleMinutes = [double]$script:LockStaleMinutes
        AutoQueue  = $AutoQueue
    }
}

# ---------------------------------------------------------------------
#  Nascan: eenmalig rondkijken na een ronde waarin locks zijn gezien
#
#  De mopronde binnen de conversie pakt alleen terug wat DEZE pc zelf
#  had overgeslagen. Een andere pc kan echter ook dingen hebben laten
#  liggen die hier nooit in de lijst kwamen: bestanden die tijdens de rit
#  zijn bijgekomen, of die de ander halverwege heeft laten vallen toen
#  hij werd gestopt.
#
#  Daarom eenmalig - en alleen eenmalig - de bronmappen opnieuw
#  doorlopen, met wat er uitkomt meteen achteraan de wachtrij. Twee keer
#  zou een rondzingende lus opleveren: de nascan ziet weer locks, start
#  weer een nascan, en zo door zolang de andere pc bezig is.
# ---------------------------------------------------------------------
$script:NascanGedaan = $false

# ---------------------------------------------------------------------
#  Bronmappen in de gaten houden
#
#  Staat het vinkje aan, dan wordt er na een uur zonder werk uit zichzelf
#  opnieuw naar de bronmappen gekeken. Wat er nieuw bij staat gaat meteen
#  achteraan de wachtrij en de conversie begint vanzelf - zonder melding,
#  zonder klik. Zo kan het vinkje gewoon aan blijven staan.
#
#  $script:WatchVanaf is het moment waarop het stil werd. Zodra er weer
#  iets loopt gaat hij op $null en begint het uur straks opnieuw.
# ---------------------------------------------------------------------
$script:WatchVanaf = $null

function Set-WatchExitCombinatie {
    # Afsluiten na de conversie en elk uur opnieuw kijken sluiten elkaar
    # uit: een afgesloten programma kijkt nergens meer naar. Het vinkje
    # dat het laatst is aangezet wint, en het andere gaat uit en op slot,
    # zodat de combinatie niet stilletjes niets doet.
    if ([bool]$ui.chkWatch.IsChecked) {
        $ui.chkExitAfter.IsChecked = $false
        $ui.chkExitAfter.IsEnabled = $false
    }
    else {
        $ui.chkExitAfter.IsEnabled = $true
    }
}

function Start-WatchScan {

    if ($sync.ScanBusy -or $sync.ConvBusy) { return $false }
    if ($sync.Queue.Count -gt 0) { return $false }
    if ($ui.lstFolders.Items.Count -eq 0) { return $false }
    if (-not (Resolve-Ffmpeg)) { return $false }

    $sync.ScanMode        = 'scan'
    $sync.ScanSettings    = Get-ScanSettings -AutoQueue $true
    $sync.ScanCancel      = $false
    $sync.ScanTotal       = 0
    $sync.ScanChecked     = 0
    $sync.ScanFound       = 0
    $sync.ScanSkippedHevc = 0
    $sync.ScanSkippedVcp  = 0
    $sync.ScanSkippedNoVid= 0
    $sync.ScanStatus      = 'Kijken of er iets nieuws is…'

    # Een nieuwe ronde uit zichzelf: de nascan mag daarna weer een keer.
    # Bewust NIET resetten wanneer de nascan zelf een conversie start -
    # dan zou nascan-conversie-nascan kunnen blijven rondzingen zolang de
    # andere pc bezig is.
    $script:NascanGedaan = $false

    Write-Log ''
    Write-Log ('--- Automatisch kijken ({0:N0} uur zonder werk) -------------' -f ($script:WatchMinutes / 60.0))
    Start-Worker $ScanWorker 'scan'
    Update-Buttons
    return $true
}

function Start-Nascan {

    if ($script:NascanGedaan) { return $false }
    if ($sync.ScanBusy -or $sync.ConvBusy) { return $false }
    if ($ui.lstFolders.Items.Count -eq 0) { return $false }
    if (-not (Resolve-Ffmpeg)) { return $false }

    # Regels waarvan het oordeel inmiddels achterhaald kan zijn eerst uit
    # de lijst halen, anders slaat de scan ze over (het pad staat immers
    # al in de lijst) en blijven ze voor altijd op 'Andere pc bezig'
    # staan. Ze komen vanzelf terug als het bestand er nog is.
    $weg = 0
    foreach ($j in @($jobs)) {
        if ($j.Status -eq 'Andere pc bezig' -or $j.Status -eq 'Niet gevonden') {
            if (Remove-JobRow $j) { $weg++ }
        }
    }

    $script:NascanGedaan  = $true
    $sync.ScanMode        = 'scan'
    $sync.ScanSettings    = Get-ScanSettings -AutoQueue $true
    $sync.ScanCancel      = $false
    $sync.ScanTotal       = 0
    $sync.ScanChecked     = 0
    $sync.ScanFound       = 0
    $sync.ScanSkippedHevc = 0
    $sync.ScanSkippedVcp  = 0
    $sync.ScanSkippedNoVid= 0
    $sync.ScanStatus      = 'Nakijken…'

    Write-Log ''
    Write-Log '--- Nascan: er zijn locks van een andere pc gezien ---------'
    if ($weg -gt 0) {
        Write-Log ("{0} regel(s) die op een andere pc stonden opnieuw aangeboden." -f $weg)
    }
    Write-Log 'De bronmappen worden nog een keer doorlopen; wat er nog ligt gaat meteen in de wachtrij.'
    Start-Worker $ScanWorker 'scan'
    Update-Buttons
    Set-Status 'Nascan: kijken of er nog iets is blijven liggen.'
    return $true
}

function Get-ConvertSettings {
    $codecKey = [string]$ui.cmbCodec.SelectedItem
    $codec    = 'libx265'
    if ($CodecMap.ContainsKey($codecKey)) { $codec = $CodecMap[$codecKey] }

    $wd = $ui.txtWork.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($wd)) { $wd = $env:TEMP }

    return @{
        DeleteOriginal = [bool]$ui.chkDeleteOrig.IsChecked
        KeepDate       = [bool]$script:KeepDate
        SmartRetry     = [bool]$script:SmartRetry
        HandleSubs     = [bool]$ui.chkSubs.IsChecked
        SubExtensions  = @($script:SubExtensions)
        MaxFailStreak  = [int]$script:MaxFailStreak
        AppStamp       = [string]$AppStamp
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
        RenameAfterConvert = [bool]$ui.chkRenameAfter.IsChecked
        RenameUndoFile     = (Join-Path $DataDir ('hernoem_undo_{0}.csv' -f (Get-Date -Format 'yyyyMMdd')))
        Codec          = $codec
        Preset         = [string]$ui.cmbPreset.SelectedItem
        Crf            = [int]$ui.sldCrf.Value
        AudioMode      = (Get-AudioMode)
        WorkDir        = $wd
        DeleteAttempts = 10
        DeleteWait     = 10
    }
}

# ---- scannen --------------------------------------------------------

$ui.btnScan.Add_Click({

    if ($sync.ScanBusy) {
        $sync.ScanCancel = $true
        Write-Log 'Scan afbreken aangevraagd.' 'WAARS'
        Set-Status 'Scan wordt afgebroken…'
        Update-Buttons
        return
    }

    if ($ui.lstFolders.Items.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Voeg eerst minstens een bronmap toe.', 'Geen bronmap', 'OK', 'Information') | Out-Null
        return
    }
    if (-not (Resolve-Ffmpeg)) {
        Set-Status 'ffmpeg ontbreekt - scannen niet mogelijk.'
        return
    }

    $sync.ScanMode        = 'scan'
    $sync.ScanSettings    = Get-ScanSettings
    $sync.ScanCancel      = $false
    $sync.ScanTotal       = 0
    $sync.ScanChecked     = 0
    $sync.ScanFound       = 0
    $sync.ScanSkippedHevc = 0
    $sync.ScanSkippedVcp  = 0
    $sync.ScanSkippedNoVid= 0
    $sync.ScanStatus      = 'Starten…'

    Write-Log ''
    Write-Log '--- Nieuwe scan -------------------------------------------'
    Start-Worker $ScanWorker 'scan'
    Update-Buttons
    Set-Status 'Scannen gestart. Nieuwe bestanden komen onderaan de lijst.'
})

# ---- de bewaarde wachtrij nalopen ------------------------------------

function Start-VerifyRound {

    $paths = @()
    foreach ($j in $jobs) { $paths += [string]$j.FullPath }
    if ($paths.Count -eq 0) { return }

    if (-not (Resolve-Ffmpeg)) {
        Write-Log 'ffmpeg ontbreekt; de bewaarde lijst wordt niet nagelopen.' 'WAARS'
        return
    }

    $sync.ScanMode        = 'verify'
    $sync.ScanSettings    = @{ VerifyPaths = $paths }
    $sync.ScanCancel      = $false
    $sync.ScanTotal       = $paths.Count
    $sync.ScanChecked     = 0
    $sync.ScanFound       = 0
    $sync.ScanSkippedHevc = 0
    $sync.ScanSkippedVcp  = 0
    $sync.ScanSkippedNoVid= 0
    $sync.ScanStatus      = 'Bewaarde lijst nalopen…'

    $script:VerifyMissing = 0
    $script:VerifyRunning = $true

    Start-Worker $ScanWorker 'scan'
    Update-Buttons
    Set-Status 'Bewaarde lijst wordt nagelopen…'
}

# ---- bronmappen hernoemen --------------------------------------------
#
#  Twee rondes in de scan-slot: eerst een plan (niets wordt aangeraakt,
#  er komt een voorbeeld-CSV), dan na bevestiging het uitvoeren. Bestanden
#  waar een andere pc een lock op heeft blijven van tafel, ook als dat
#  lock er pas tussen plan en uitvoeren is bijgekomen.
# ---------------------------------------------------------------------

$RenameWorker = {
    $ErrorActionPreference = 'Continue'
    $cfg   = $sync.ScanSettings
    $stale = 15.0
    if ($cfg.LockStaleMinutes) { $stale = [double]$cfg.LockStaleMinutes }
    $sync.RenameError = ''

    try {
        if ($sync.ScanMode -eq 'hernoem-plan') {
            $R     = Get-RnRules
            $exts  = @($R.VideoExtensions) + @($R.SubExtensions)
            $alle  = New-Object System.Collections.Generic.List[string]
            $locks = New-Object System.Collections.Generic.List[string]
            foreach ($map in @($cfg.Folders)) {
                if ($sync.ScanCancel) { break }
                $sync.ScanStatus = "Hernoemen: $map doorlopen…"
                $items = @()
                try { $items = @(Get-ChildItem -LiteralPath $map -File -Recurse:([bool]$cfg.Recursive) -Force -ErrorAction SilentlyContinue) } catch { }
                foreach ($fi in $items) {
                    $n = $fi.Name
                    if ($n -like '*.x265lock') { $locks.Add($fi.FullName.Substring(0, $fi.FullName.Length - 9)); continue }
                    if ($n -like 'x265_*') { continue }            # werkbestanden
                    if ($exts -contains $fi.Extension.ToLower()) { $alle.Add($fi.FullName) }
                }
                $sync.ScanStatus = "Hernoemen: {0} bestanden gevonden…" -f $alle.Count
            }
            if ($sync.ScanCancel) { $sync.RenamePlan = $null; return }

            # Alleen levende locks houden een bestand vast; een verweesd lock
            # (pc uitgevallen) niet.
            $vast = @($locks | Where-Object { -not (Test-LockFree $_ $stale) })
            $sync.ScanStatus = 'Hernoemen: nieuwe namen bepalen…'
            $plan = Get-RnPlan -Files ([string[]]$alle.ToArray()) -Frozen ([string[]]$vast)

            try {
                @($plan) | Select-Object Type, Status, Map, Oud, Nieuw, @{ n = 'Opmerking'; e = { $_.KeptAs } } |
                    Export-Csv -LiteralPath $cfg.PreviewFile -NoTypeInformation -Delimiter ';' -Encoding UTF8
            }
            catch { W ("Voorbeeld-CSV kon niet worden geschreven: {0}" -f $_.Exception.Message) 'WAARS' }
            $sync.RenamePlan = $plan
        }
        elseif ($sync.ScanMode -eq 'hernoem-uit') {
            $sync.ScanStatus = 'Hernoemen: bezig…'
            $vrij = { param($p) Test-LockFree $p $stale }
            $sync.RenameResult = Invoke-RnPlan -Plan @($sync.RenamePlan) -UndoFile ([string]$cfg.UndoFile) -StillFree $vrij
        }
    }
    catch {
        $sync.RenameError = $_.Exception.Message
        W ("Hernoemen afgebroken: {0}" -f $_.Exception.Message) 'FOUT'
    }
}

$ui.btnRename.Add_Click({
    if ([bool]$sync.ScanBusy -or [bool]$sync.ConvBusy) { return }
    if ($ui.lstFolders.Items.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Kies eerst een of meer bronmappen.', 'Hernoemen', 'OK', 'Information') | Out-Null
        return
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $sync.ScanSettings = @{
        Folders          = @($ui.lstFolders.Items | ForEach-Object { [string]$_ })
        Recursive        = [bool]$script:Recursive
        LockStaleMinutes = [double]$script:LockStaleMinutes
        PreviewFile      = (Join-Path $DataDir ("hernoem_voorbeeld_$stamp.csv"))
        UndoFile         = (Join-Path $DataDir ("hernoem_undo_$stamp.csv"))
    }
    $sync.ScanMode     = 'hernoem-plan'
    $sync.ScanCancel   = $false
    $sync.ScanStatus   = 'Hernoemen: bronmappen doorlopen…'
    $sync.RenamePlan   = $null
    $sync.RenameResult = $null
    Write-Log ''
    Write-Log '--- Bronmappen hernoemen: overzicht maken (er verandert nog niets) ---'
    Start-Worker $RenameWorker 'scan'
    Update-Buttons
})

function Complete-Hernoemen {
    param([string]$Fase)

    if ($sync.RenameError) {
        [System.Windows.MessageBox]::Show("Hernoemen is afgebroken:`n`n$($sync.RenameError)", 'Hernoemen', 'OK', 'Error') | Out-Null
        return
    }

    if ($Fase -eq 'hernoem-plan') {
        $plan = @($sync.RenamePlan)
        if ($sync.RenamePlan -eq $null) { Write-Log 'Hernoemen gestopt; er is niets veranderd.'; Set-Status 'Hernoemen gestopt.'; return }

        $tel = @{}
        foreach ($r in $plan) { $k = ([string]$r.Status -split ' ')[0]; $tel[$k] = 1 + [int]$tel[$k] }
        $nRen  = [int]$tel['OK']
        $nDel  = [int]$tel['VERWIJDEREN']
        $nConf = [int]$tel['CONFLICT']
        $nGoed = [int]$tel['AL']
        $nOver = [int]$tel['OVERGESLAGEN']

        Write-Log ("Overzicht: {0} te hernoemen, {1} dubbel (naar de Prullenbak), {2} conflict, {3} al goed, {4} overgeslagen." -f `
            $nRen, $nDel, $nConf, $nGoed, $nOver)
        foreach ($r in @($plan | Where-Object { $_.Status -like 'VERWIJDEREN*' })) {
            Write-Log ("  dubbel: {0}  (blijft: {1})" -f $r.OldPath, $r.KeptAs)
        }
        foreach ($r in @($plan | Where-Object { $_.Status -like 'CONFLICT*' })) {
            Write-Log ("  conflict: {0} -> {1}  ({2})" -f $r.OldPath, $r.Nieuw, $r.KeptAs) 'WAARS'
        }
        Write-Log ("Volledig overzicht: {0}" -f $sync.ScanSettings.PreviewFile)

        if ($nRen + $nDel -eq 0) {
            Set-Status 'Hernoemen: alles staat al goed.'
            [System.Windows.MessageBox]::Show(("Er valt niets te hernoemen.`n`n{0} al goed, {1} conflict, {2} overgeslagen." -f $nGoed, $nConf, $nOver),
                'Hernoemen', 'OK', 'Information') | Out-Null
            return
        }

        $m = "In de bronmappen:`n`n" +
             ("  {0} bestand(en) hernoemen`n" -f $nRen) +
             ("  {0} dubbel(en) naar de Prullenbak (op een netwerkschijf zijn ze dan echt weg)`n" -f $nDel) +
             ("  {0} conflict(en) en {1} overgeslagen - die blijven zoals ze zijn`n`n" -f $nConf, $nOver) +
             "Het volledige overzicht staat in:`n$($sync.ScanSettings.PreviewFile)`n`nNu uitvoeren?"
        $a = [System.Windows.MessageBox]::Show($m, 'Bronmappen hernoemen', 'YesNo', 'Question')
        if ($a -ne 'Yes') {
            Write-Log 'Hernoemen niet uitgevoerd; er is niets veranderd.'
            Set-Status 'Hernoemen niet uitgevoerd.'
            return
        }
        # Terwijl de vraag openstond kan er iets zijn begonnen (een opdracht
        # van de opdrachtregel, automatisch kijken). Dan niet.
        if ([bool]$sync.ConvBusy -or [bool]$sync.ScanBusy) {
            Write-Log 'Er is intussen een scan of conversie gestart; hernoemen niet uitgevoerd. Probeer het straks opnieuw.' 'WAARS'
            return
        }
        Write-Log '--- Bronmappen hernoemen: uitvoeren ---'
        $sync.ScanMode   = 'hernoem-uit'
        $sync.ScanCancel = $false
        $sync.ScanStatus = 'Hernoemen: bezig…'
        Start-Worker $RenameWorker 'scan'
        Update-Buttons
        return
    }

    # ---- uitgevoerd: de lijst in het venster bijwerken ----------------
    $res = $sync.RenameResult
    if ($res -eq $null) { return }
    $bijgewerkt = 0
    foreach ($r in @($res.Renamed)) {
        if ($r.Type -ne 'video') { continue }
        foreach ($j in @($jobs)) {
            if ([string]::Equals([string]$j.FullPath, [string]$r.OldPath, [StringComparison]::OrdinalIgnoreCase)) {
                [void]$script:JobPaths.Remove([string]$j.FullPath)
                $j.FullPath = [string]$r.NewPath
                $j.Name     = [IO.Path]::GetFileName([string]$r.NewPath)
                [void]$script:JobPaths.Add([string]$r.NewPath)
                $bijgewerkt++
            }
        }
    }
    foreach ($p in @($res.Deleted)) {
        foreach ($j in @($jobs)) {
            if ([string]::Equals([string]$j.FullPath, $p, [StringComparison]::OrdinalIgnoreCase)) { [void](Remove-JobRow $j) }
        }
    }
    Sync-QueueOrder
    $txt = ("Hernoemen klaar: {0} hernoemd, {1} naar de Prullenbak, {2} mislukt." -f `
        @($res.Renamed).Count, @($res.Deleted).Count, [int]$res.Failed)
    Write-Log $txt
    if ($bijgewerkt -gt 0) { Write-Log ("{0} regel(s) in de lijst bijgewerkt naar de nieuwe naam." -f $bijgewerkt) }
    if (@($res.Renamed).Count -gt 0) {
        Write-Log ('Terugdraaien: powershell -ExecutionPolicy Bypass -File "{0}" -HernoemTerug "{1}" -Uitvoeren' -f $PSCommandPath, $sync.ScanSettings.UndoFile)
    }
    Set-Status $txt
    Request-Save
}

# ---- starten / toevoegen --------------------------------------------

$ui.chkWatch.Add_Checked({   Set-WatchExitCombinatie; $script:WatchVanaf = Get-Date; Request-Save })
$ui.chkWatch.Add_Unchecked({ Set-WatchExitCombinatie; $script:WatchVanaf = $null;     Request-Save })

$ui.txtWatchHours.Add_LostFocus({
    $u = Set-WatchHoursText $ui.txtWatchHours.Text
    $ui.txtWatchHours.Text = [string]$u
    Request-Save
})

$ui.btnStart.Add_Click({

    # Tijdens het hernoemen van de bronmappen niet beginnen: dan zou de
    # conversie namen oppakken die net veranderen.
    if ([bool]$sync.ScanBusy -and ([string]$sync.ScanMode) -like 'hernoem*') { return }

    # Handmatig starten is een nieuwe ronde: de nascan mag daarna weer.
    $script:NascanGedaan = $false

    # ---- 1. opgeruimde regels weghalen ------------------------------
    #  Alles wat klaar is en alles wat al HEVC is verdwijnt uit de lijst
    #  op het moment dat er gestart wordt; het pad blijft onthouden zodat
    #  een volgende scan het niet opnieuw aanbiedt.
    $tossed = 0
    foreach ($j in @($jobs)) {
        if ($j.IsHevc -or $j.Status -eq 'Geslaagd') {
            if ($script:ActiveStatus -contains $j.Status) { continue }
            [void]$script:DonePaths.Add([string]$j.FullPath)
            if (Remove-JobRow $j) { $tossed++ }
        }
    }
    if ($tossed -gt 0) {
        Write-Log ("{0} regel(s) uit de lijst gehaald bij het starten (al HEVC of al klaar)." -f $tossed)
    }

    # ---- 2. aangevinkte regels achteraan de wachtrij ----------------
    $new = @($jobs | Where-Object { $_.Include -and -not $_.Queued -and -not $_.IsHevc })

    $addBytes = [double]0
    $addSecs  = [double]0
    foreach ($j in $new) { $addBytes += $j.SizeBytes; $addSecs += $j.DurationSec }

    if ($new.Count -eq 0 -and $sync.Queue.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            'Er staat niets in de wachtrij en er zijn geen aangevinkte regels om toe te voegen.',
            'Niets te doen', 'OK', 'Information') | Out-Null
        return
    }
    if (-not (Resolve-Ffmpeg)) { return }

    # ---- 3a. loopt er al een conversie? dan alleen bijplaatsen ------
    if ($sync.ConvBusy) {
        if ($new.Count -gt 0) {
            [void](Add-ToQueueBack $new)
            Write-Log ("{0} bestand(en) achteraan de wachtrij gezet ({1}, {2} speelduur)." -f `
                $new.Count, (Format-Size $addBytes), (Format-Span $addSecs))
            Set-Status ("{0} bestand(en) toegevoegd aan de lopende wachtrij." -f $new.Count)
        } else {
            Set-Status 'Er is niets nieuws om toe te voegen.'
        }
        Update-Buttons
        return
    }

    # ---- 3b. nieuwe run --------------------------------------------
    $st = Get-ConvertSettings

    # De werkmap moet bestaan EN beschrijfbaar zijn. Een pad uit een
    # instellingenbestand van een andere machine (of een map die de
    # beheerder heeft dichtgezet) valt hier door de mand. In plaats van
    # afhaken wijken we uit naar de tijdelijke map van de gebruiker; daar
    # mag altijd geschreven worden, en dat scheelt starten als beheerder.
    if (-not (Test-DirWritable $st.WorkDir)) {
        $terug = Join-Path $env:TEMP 'X265-Converter'
        if (Test-DirWritable $terug) {
            # Geen venster: dit heeft zichzelf opgelost, en een klik
            # vragen voor iets wat al geregeld is houdt alleen maar op.
            Write-Log ("Werkmap {0} is niet bruikbaar; uitgeweken naar {1}." -f $st.WorkDir, $terug) 'WAARS'
            Set-Status ("Werkmap niet bruikbaar; uitgeweken naar {0}." -f $terug)
            $ui.txtWork.Text = $terug
            $st.WorkDir      = $terug
        }
        else {
            [System.Windows.MessageBox]::Show(
                ("De werkmap kan niet worden gebruikt en er is geen bruikbaar alternatief:`n{0}" -f $st.WorkDir),
                'Werkmap', 'OK', 'Error') | Out-Null
            return
        }
    }

    if ($new.Count -gt 0) { [void](Add-ToQueueBack $new) }

    $qCount = $sync.Queue.Count
    $qSecs  = [double]$sync.QueueVideoSec
    $qBytes = [double]0
    foreach ($j in (Get-QueueSnapshot)) { if ($j -ne $null) { $qBytes += $j.SizeBytes } }

    # Geen bevestigingsvenster meer: op Start drukken IS de bevestiging.
    # Het overzicht gaat naar de log, zodat je achteraf nog kunt zien met
    # welke instellingen een run is begonnen.
    Write-Log ("Start: {0} bestand(en), {1}, {2} speelduur." -f `
        $qCount, (Format-Size $qBytes), (Format-Span $qSecs))
    Write-Log ("Encoder {0}, preset {1}, CRF/kwaliteit {2}, geluid {3}." -f `
        $st.Codec, $st.Preset, $st.Crf, ([string]$ui.cmbAudio.SelectedItem))
    Write-Log ("Origineel verwijderen: {0}   ondertitels meenemen: {1}   afsluiten na stop: {2}" -f `
        $(if ($st.DeleteOriginal) { 'ja' } else { 'nee' }),
        $(if ($st.HandleSubs)     { 'ja' } else { 'nee' }),
        $(if ($ui.chkExitAfter.IsChecked) { 'ja' } else { 'nee' }))

    # nieuwe run: KeepAwake mag straks opnieuw worden gestopt
    $script:KeepAwakeStopped = $false

    $sync.Settings         = $st
    $sync.Cancel           = $false
    $sync.StopAfterCurrent = $false
    $sync.PauseRequested   = $false
    $sync.IsPaused         = $false
    $sync.JobsDone         = 0
    $sync.Success          = 0
    $sync.Failed           = 0
    $sync.Warned           = 0
    $sync.OrigBytes        = [long]0
    $sync.NewBytes         = [long]0
    $sync.DoneVideoSec     = 0.0
    $sync.CurVideoSec      = 0.0
    $sync.CurDurationSec   = 0.0
    $sync.ActiveSec        = 0.0
    $sync.WallSec          = 0.0
    $sync.PausedSec        = 0.0
    $sync.FailStreak       = 0
    $sync.EmergencyStop    = $false

    # oude noodstop-meldingen leegtrekken
    $dump = ''
    while ($sync.EmergencyFiles.TryDequeue([ref]$dump)) { }

    $script:EtaRate     = 0.0
    $script:EtaFiles    = 0.0
    $script:EtaLastCalc = $null
    $script:EtaStamp    = ''
    $script:ExitPending = $false

    $ui.grid.SelectedIndex = -1
    Save-Settings
    Start-Worker $ConvertWorker 'conv'
    Update-Buttons
    Set-Status 'Conversie gestart.'
})

# ---- pauze / stop ---------------------------------------------------

$ui.btnPause.Add_Click({
    if (-not $sync.ConvBusy) { return }
    $sync.PauseRequested = -not [bool]$sync.PauseRequested
    if ($sync.PauseRequested) { Set-Status 'Pauze aangevraagd - ffmpeg wordt bevroren.' }
    else { Set-Status 'Hervatten…' }
    Update-Buttons
})

$ui.btnStopAfter.Add_Click({
    if (-not $sync.ConvBusy) { return }

    # Schakelaar: aan én weer uit.
    if ($sync.StopAfterCurrent) {
        $sync.StopAfterCurrent = $false
        Write-Log 'Stop na huidige weer INGETROKKEN; de conversie gaat verder met de bovenste uit de wachtrij.' 'WAARS'
        Set-Status 'Stop na huidige ingetrokken - de conversie gaat door.'
    } else {
        $sync.StopAfterCurrent = $true
        Write-Log 'Stop na huidige AANGEVRAAGD.' 'WAARS'
        Set-Status 'Stopt zodra de huidige conversie klaar is. Nog een keer klikken trekt dat weer in.'
    }
    Update-Buttons
})

$ui.btnStopNow.Add_Click({

    # Loopt er een aftelling naar afsluiten? Dan is dit de annuleerknop.
    if ($script:ExitAt -ne $null) {
        $script:ExitAt      = $null
        $script:ExitPending = $false
        $ui.chkExitAfter.IsChecked = $false
        $ui.txtStatus2.Text = ''
        Write-Log 'Afsluiten geannuleerd; het vinkje is uitgezet.' 'WAARS'
        Set-Status 'Afsluiten geannuleerd.'
        Update-Buttons
        return
    }

    if (-not $sync.ConvBusy) { return }
    $a = [System.Windows.MessageBox]::Show(
        "Direct stoppen?`n`nDe lopende conversie wordt afgebroken en het tijdelijke bestand wordt verwijderd. De rest van de wachtrij blijft staan.",
        'Stop direct', 'YesNo', 'Warning')
    if ($a -ne 'Yes') { return }
    $sync.Cancel         = $true
    $sync.PauseRequested = $false
    Write-Log 'Stop direct aangevraagd.' 'WAARS'
    Set-Status 'Afbreken…'
    Update-Buttons
})
