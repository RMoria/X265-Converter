
# ---------------------------------------------------------------------
# 7.  Hulpfuncties die ook in de werk-thread nodig zijn
# ---------------------------------------------------------------------

# ---------------------------------------------------------------------
#  Lock-bestanden: twee computers op dezelfde map
#
#  Het lock-bestand heet <bronnaam met extensie>.x265lock en staat naast
#  de bron. Dus in dezelfde map, en niet in een centrale lijst: de ene pc
#  kent die map als \\10.0.0.242\g\One Piece en de andere misschien als
#  G:\One Piece of gewoon als C:\g\One Piece. Een centrale lijst op pad
#  zou die drie als drie verschillende bestanden zien; een lock naast de
#  bron heeft daar geen last van.
#
#  Het bestandje is leesbare tekst, zodat je in Kladblok kunt zien welke
#  pc ergens mee bezig is:
#
#      pc=ACERROB
#      pid=12345
#      gebruiker=rob
#      bestand=aflevering 12.mkv
#      laatst=2026-09-13T20:09:11Z
#      versie=X265 Converter 1.3 (2026-09-14)
#
#  Twee sloten op de deur:
#
#   1. AANMAKEN met FileMode::CreateNew. Bestaat het al, dan faalt het.
#      Dat is de harde garantie en die werkt overal hetzelfde.
#   2. OPEN HOUDEN met FileShare::Read zolang de conversie loopt. Op
#      Windows (en over SMB) kan een andere pc het bestand dan niet
#      hernoemen of weggooien, ook niet als hij denkt dat het lock oud
#      is. Op Linux wordt dit niet afgedwongen; daar doet alleen punt 1
#      en het tijdstempel het werk. Voor dit programma is dat geen
#      probleem - het draait op Windows - maar de tests in deze map
#      draaien wel op Linux en toetsen dus bewust punt 1.
# ---------------------------------------------------------------------

function Get-LockPath {
    param([string]$SourcePath)
    return ($SourcePath + '.x265lock')
}

function Read-LockInfo {
    param([string]$LockPath)

    $r = @{ Pc = ''; Proces = ''; Bestand = ''; Laatst = $null }
    $txt = ''
    try {
        $fs = New-Object System.IO.FileStream($LockPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            $txt = $sr.ReadToEnd()
        }
        finally { $fs.Dispose() }
    }
    catch { return $r }

    foreach ($regel in ($txt -split "`r?`n")) {
        $i = $regel.IndexOf('=')
        if ($i -lt 1) { continue }
        $sleutel = $regel.Substring(0, $i).Trim()
        $waarde  = $regel.Substring($i + 1).Trim()
        if ($sleutel -eq 'pc')      { $r.Pc      = $waarde }
        if ($sleutel -eq 'pid')     { $r.Proces  = $waarde }
        if ($sleutel -eq 'bestand') { $r.Bestand = $waarde }
        if ($sleutel -eq 'laatst') {
            $d = [DateTime]::MinValue
            $stijl = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor `
                     [System.Globalization.DateTimeStyles]::AssumeUniversal
            if ([DateTime]::TryParse($waarde,
                    [System.Globalization.CultureInfo]::InvariantCulture, $stijl, [ref]$d)) {
                $r.Laatst = $d
            }
        }
    }
    return $r
}

function Get-LockAge {
    param([string]$LockPath)

    # Hoe lang geleden liet de eigenaar voor het laatst van zich horen,
    # in minuten? Er wordt naar twee dingen gekeken - het tijdstempel IN
    # het bestand en dat van het bestand zelf - en de jongste telt.
    # Windows werkt het tijdstempel van een geopend bestand niet altijd
    # meteen bij, en over SMB al helemaal niet; het tijdstempel in de
    # inhoud wordt wel elke keer echt weggeschreven.
    $jongste = [DateTime]::MinValue
    try { $jongste = (Get-Item -LiteralPath $LockPath -ErrorAction Stop).LastWriteTimeUtc } catch { }

    $info = Read-LockInfo $LockPath
    if ($info.Laatst -ne $null -and $info.Laatst -gt $jongste) { $jongste = $info.Laatst }

    if ($jongste -eq [DateTime]::MinValue) { return [double]::MaxValue }
    return ([DateTime]::UtcNow - $jongste).TotalMinutes
}

function Write-LockBody {
    param($Stream, [string]$Bestand, [string]$Stamp)

    $tekst = (@(
        ('pc={0}'        -f [System.Environment]::MachineName)
        ('pid={0}'       -f $PID)
        ('gebruiker={0}' -f [System.Environment]::UserName)
        ('bestand={0}'   -f $Bestand)
        ('laatst={0}'    -f ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')))
        ('versie={0}'    -f $Stamp)
    ) -join "`r`n") + "`r`n"

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($tekst)
    $Stream.Position = 0
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.SetLength($bytes.Length)
    $Stream.Flush($true)
}

function Take-Lock {
    param(
        [string]$SourcePath,
        [double]$StaleMinutes = 15.0,
        [string]$Stamp = ''
    )

    # Geeft terug:
    #   Ok=$true                     wij hebben hem, .Lock moet later los
    #   Ok=$false, Busy=$true        een andere pc is ermee bezig
    #   Ok=$false, Busy=$false       lock kon niet worden aangemaakt
    $pad  = Get-LockPath $SourcePath
    $naam = [System.IO.Path]::GetFileName($SourcePath)

    for ($poging = 1; $poging -le 2; $poging++) {

        $fs = $null
        try {
            $fs = New-Object System.IO.FileStream($pad,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::Read)
        }
        catch { $fs = $null }

        if ($fs -ne $null) {
            try { Write-LockBody -Stream $fs -Bestand $naam -Stamp $Stamp } catch { }
            return @{
                Ok   = $true
                Busy = $false
                Lock = [pscustomobject]@{
                    Path    = $pad
                    Stream  = $fs
                    Bestand = $naam
                    Stamp   = $Stamp
                    Laatst  = [DateTime]::UtcNow
                }
            }
        }

        # Aanmaken lukte niet. Ligt er echt een lock, of is er iets anders
        # mis - map alleen-lezen, pad te lang, share weg?
        $bestaat = $false
        try { $bestaat = [System.IO.File]::Exists($pad) } catch { }
        if (-not $bestaat) {
            return @{ Ok = $false; Busy = $false; Owner = ''; AgeMin = 0.0 }
        }

        if ($poging -ge 2) { break }

        $leeftijd = Get-LockAge $pad
        if ($leeftijd -lt $StaleMinutes) {
            $info = Read-LockInfo $pad
            return @{ Ok = $false; Busy = $true; Owner = [string]$info.Pc; AgeMin = $leeftijd }
        }

        # Verweesd lock. Overnemen gebeurt met een HERNOEMING en niet met
        # een verwijdering. Hernoemen kan maar een keer slagen, dus twee
        # pc's die tegelijk tot dezelfde conclusie komen kunnen niet
        # allebei doorlopen - en ze kunnen elkaars zojuist aangemaakte
        # verse lock ook niet per ongeluk weggooien.
        $weg = $pad + '.oud_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        try { [System.IO.File]::Move($pad, $weg) }
        catch {
            # Hernoemen mislukt: of een ander was ons voor, of de eigenaar
            # houdt het bestand op Windows gewoon nog open. Beide keren is
            # het antwoord hetzelfde: afblijven.
            $info = Read-LockInfo $pad
            return @{ Ok = $false; Busy = $true; Owner = [string]$info.Pc; AgeMin = $leeftijd }
        }
        try { [System.IO.File]::Delete($weg) } catch { }
    }

    return @{ Ok = $false; Busy = $true; Owner = ''; AgeMin = 0.0 }
}

function Beat-Lock {
    param($Lock, [double]$EverySeconds = 60.0)

    # Laat de andere pc weten dat we nog leven. Houdt zichzelf op een keer
    # per minuut; de aanroepers zitten in poll-lussen die veel vaker langs
    # komen.
    if ($Lock -eq $null) { return }
    if (([DateTime]::UtcNow - $Lock.Laatst).TotalSeconds -lt $EverySeconds) { return }
    try {
        Write-LockBody -Stream $Lock.Stream -Bestand $Lock.Bestand -Stamp $Lock.Stamp
        $Lock.Laatst = [DateTime]::UtcNow
    }
    catch { }
}

function Release-Lock {
    param($Lock)

    if ($Lock -eq $null) { return }

    # Take-Lock geeft een uitslag terug met het lock erin. Wordt die
    # uitslag hier doorgegeven in plaats van het lock zelf, dan is dat
    # een vergissing met vervelende gevolgen: het lock blijft dan een
    # kwartier liggen en de andere pc kan er niet bij. Dus opvangen.
    if ($Lock.PSObject.Properties['Lock']) { $Lock = $Lock.Lock }
    if ($Lock -eq $null) { return }

    try { $Lock.Stream.Dispose() } catch { }
    try { [System.IO.File]::Delete($Lock.Path) } catch { }
}

function Test-LockOwned {
    param($Lock)

    # Hebben we dit lock nog steeds? Na een slaapstand of een lange
    # netwerkstoring kan een andere pc hem als verweesd hebben beschouwd
    # en zelf aan het bestand zijn begonnen. Dat is het moment om NIET
    # ons resultaat over dat van de ander heen te zetten.
    if ($Lock -eq $null) { return $true }                       # zonder lock gewerkt
    if ($Lock.PSObject.Properties['Lock']) { $Lock = $Lock.Lock }
    if ($Lock -eq $null) { return $true }

    $bestaat = $false
    try { $bestaat = [System.IO.File]::Exists($Lock.Path) } catch { return $true }

    if (-not $bestaat) {
        # Weg. Dat kan een andere pc zijn geweest die inmiddels ook alweer
        # klaar is, maar ook een hik van de share. Gewoon opnieuw proberen
        # te plaatsen: lukt dat, dan is er niemand anders en gaan we door.
        $fs = $null
        try {
            $fs = New-Object System.IO.FileStream($Lock.Path,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::Read)
        }
        catch { return $false }
        try { $Lock.Stream.Dispose() } catch { }
        $Lock.Stream = $fs
        $Lock.Laatst = [DateTime]::MinValue
        return $true
    }

    $info = Read-LockInfo $Lock.Path
    if ([string]::IsNullOrWhiteSpace([string]$info.Pc) -and
        [string]::IsNullOrWhiteSpace([string]$info.Proces)) {
        # Onleesbaar. Geen reden om uren rekenwerk weg te gooien.
        return $true
    }
    return ((([string]$info.Pc) -eq [System.Environment]::MachineName) -and
            (([string]$info.Proces) -eq ([string]$PID)))
}

function Test-LockFree {
    param([string]$SourcePath, [double]$StaleMinutes = 15.0)

    # Alleen kijken, niets claimen. Voor de vraag of het zin heeft een
    # bestand alvast naar de werkmap te halen.
    $pad = Get-LockPath $SourcePath
    try { if (-not [System.IO.File]::Exists($pad)) { return $true } } catch { return $true }
    return ((Get-LockAge $pad) -ge $StaleMinutes)
}

$HelperText = @"
function Format-Size {
$(${function:Format-Size})
}
function Format-Span {
$(${function:Format-Span})
}
function Format-Clock {
$(${function:Format-Clock})
}
function W {
    param([string]`$Message, [string]`$Level = 'INFO')
    `$sync.LogQueue.Enqueue(('[{0}] {1,-5} {2}' -f (Get-Date -Format 'HH:mm:ss'), `$Level, `$Message))
}
function Quote-Arg {
    param([string]`$a)
    if (`$a -match '[\s"]') { return '"' + (`$a -replace '"','\"') + '"' }
    return `$a
}
function Get-LockPath {
$(${function:Get-LockPath})
}
function Read-LockInfo {
$(${function:Read-LockInfo})
}
function Get-LockAge {
$(${function:Get-LockAge})
}
function Write-LockBody {
$(${function:Write-LockBody})
}
function Take-Lock {
$(${function:Take-Lock})
}
function Beat-Lock {
$(${function:Beat-Lock})
}
function Release-Lock {
$(${function:Release-Lock})
}
function Test-LockOwned {
$(${function:Test-LockOwned})
}
function Test-LockFree {
$(${function:Test-LockFree})
}
"@

# ---------------------------------------------------------------------
# 8.  WERK-THREAD  1 :  scannen
# ---------------------------------------------------------------------

$ScanWorker = {

    $ErrorActionPreference = 'Continue'

    function Probe-File {
        param([string]$FilePath)

        $aa = @(
            '-v','error'
            '-select_streams','v:0'
            '-show_entries','stream=codec_name,duration:format=duration'
            '-of','json'
            $FilePath
        )
        try   { $raw = (& $sync.Ffprobe @aa 2>$null) -join "`n" }
        catch { return $null }

        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

        try   { $j = $raw | ConvertFrom-Json }
        catch { return $null }

        if (-not $j.streams -or $j.streams.Count -lt 1) { return $null }

        $codec = [string]$j.streams[0].codec_name
        if ([string]::IsNullOrWhiteSpace($codec)) { return $null }

        $dur = 0.0
        foreach ($cand in @($j.format.duration, $j.streams[0].duration)) {
            if ($cand -and $cand -ne 'N/A') {
                $d = 0.0
                $okParse = [double]::TryParse(
                    ([string]$cand),
                    [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$d)
                if ($okParse -and $d -gt 0) { $dur = $d; break }
            }
        }

        return [pscustomobject]@{ Codec = $codec; DurationSec = $dur }
    }

    # =================================================================
    #  MODUS 'opdracht' : losse bestanden die via -In/-Out zijn
    #                     aangeleverd, elk met een vast uitvoerpad
    #
    #  Het probewerk gebeurt hier en niet op de UI-draad: een bestand op
    #  een share dat niet reageert kost seconden, en daar mag het venster
    #  niet op vastlopen.
    # =================================================================
    if ($sync.ScanMode -eq 'opdracht') {
        try {
            $opdrachten = @($sync.ScanSettings.Jobs)
            $sync.ScanTotal = $opdrachten.Count
            W ("{0} opdracht(en) van de opdrachtregel verwerken." -f $opdrachten.Count)

            foreach ($opd in $opdrachten) {

                if ($sync.ScanCancel) { break }

                $sync.ScanChecked = $sync.ScanChecked + 1
                $inPad  = [string]$opd.In
                $uitPad = [string]$opd.Out
                $sync.ScanStatus = "Opdracht $($sync.ScanChecked)/$($sync.ScanTotal): $([IO.Path]::GetFileName($inPad))"

                $fi = $null
                try { $fi = Get-Item -LiteralPath $inPad -ErrorAction Stop } catch { }
                if ($fi -eq $null) {
                    W ("Opdracht overgeslagen, bestand niet gevonden: {0}" -f $inPad) 'FOUT'
                    continue
                }

                $info = Probe-File $fi.FullName
                if ($info -eq $null) {
                    W ("Opdracht overgeslagen, geen leesbare video: {0}" -f $inPad) 'FOUT'
                    continue
                }

                $isHevc = ($info.Codec -match '(?i)^(hevc|h265|x265)$')
                if ($isHevc) {
                    W ("Opdracht overgeslagen, is al HEVC: {0}" -f $inPad) 'WAARS'
                    $sync.ScanSkippedHevc = $sync.ScanSkippedHevc + 1
                    continue
                }

                $sync.ScanFound = $sync.ScanFound + 1
                $sync.NewJobs.Enqueue([pscustomobject]@{
                    FullPath    = $fi.FullName
                    Name        = $fi.Name
                    Folder      = $fi.DirectoryName
                    SizeBytes   = [long]$fi.Length
                    DurationSec = [double]$info.DurationSec
                    Codec       = $info.Codec
                    IsHevc      = $false
                    Include     = $true
                    OutPath     = $uitPad
                    AutoQueue   = $true
                })
                W ("Opdracht toegevoegd: {0}{1}" -f $fi.FullName,
                    $(if ($uitPad) { " -> $uitPad" } else { '' }))
            }
        }
        catch {
            W ("Fout bij het verwerken van opdrachten: {0}" -f $_.Exception.Message) 'FOUT'
        }
        finally {
            $sync.ScanBusy = $false
        }
        return
    }

    # =================================================================
    #  MODUS 'verify' : alleen de opgegeven paden nalopen
    #
    #  Wordt bij het opstarten gebruikt voor een bewaarde wachtrij:
    #  bestaat het bestand nog, is het benaderbaar, en wat zijn nu de
    #  grootte, de speelduur en de codec? Dezelfde ronde dient dus als
    #  automatische herscan van alleen de regels in de lijst.
    # =================================================================

    if ($sync.ScanMode -eq 'verify') {
        try {
            $paths = @($sync.ScanSettings.VerifyPaths)
            $sync.ScanTotal = $paths.Count
            W ("Bewaarde wachtrij nalopen: {0} bestand(en)." -f $paths.Count)

            foreach ($fp in $paths) {

                if ($sync.ScanCancel) { break }

                $sync.ScanChecked = $sync.ScanChecked + 1
                $sync.ScanStatus  = "Controleren $($sync.ScanChecked)/$($sync.ScanTotal): $([IO.Path]::GetFileName($fp))"

                $res = [ordered]@{
                    FullPath    = [string]$fp
                    Ok          = $false
                    SizeBytes   = [long]0
                    DurationSec = 0.0
                    Codec       = ''
                    IsHevc      = $false
                    Error       = ''
                }

                $fi = $null
                try   { $fi = Get-Item -LiteralPath $fp -ErrorAction Stop }
                catch { $res.Error = 'niet gevonden of niet benaderbaar' }

                if ($fi -ne $null) {
                    $res.SizeBytes = [long]$fi.Length
                    if ($res.SizeBytes -le 0) {
                        $res.Error = 'bestand is leeg'
                    } else {
                        $info = Probe-File $fp
                        if ($info -eq $null) {
                            $res.Error = 'geen leesbare videostream'
                        } else {
                            $res.Codec       = $info.Codec
                            $res.DurationSec = [double]$info.DurationSec
                            $res.IsHevc      = ($info.Codec -match '(?i)^(hevc|h265|x265)$')
                            $res.Ok          = $true
                            $sync.ScanFound  = $sync.ScanFound + 1
                            if ($res.IsHevc) { $sync.ScanSkippedHevc = $sync.ScanSkippedHevc + 1 }
                        }
                    }
                }

                if (-not $res.Ok -and $res.Error) {
                    $sync.ScanSkippedNoVid = $sync.ScanSkippedNoVid + 1
                    W ("Niet bruikbaar ({0}): {1}" -f $res.Error, $fp) 'WAARS'
                }

                $sync.VerifyResults.Enqueue([pscustomobject]$res)
            }

            if ($sync.ScanCancel) { W 'Controleren afgebroken door gebruiker.' 'WAARS' }
            else { W 'Bewaarde wachtrij nagelopen.' }
        }
        catch {
            $sync.WorkerError = $_.Exception.Message
            W "Onverwachte fout tijdens controleren: $($_.Exception.Message)" 'FOUT'
        }
        finally {
            $sync.ScanStatus = ''
            $sync.ScanBusy   = $false
        }
        return
    }

    # =================================================================
    #  MODUS 'scan' : mappen doorzoeken
    # =================================================================

    try {
        $st   = $sync.ScanSettings

        # patroon voor de VCP-markering; leeg = niets overslaan
        $vcpPat = ''
        if ($st.VcpMarker) {
            $vm = ([string]$st.VcpMarker).Trim()
            if ($vm.Length -gt 0) { $vcpPat = ('(?i)\.{0}( \(\d+\))?$' -f [Regex]::Escape($vm)) }
        }

        $exts = @{}
        foreach ($e in $st.Extensions) {
            $x = $e.Trim().TrimStart('.').ToLower()
            if ($x) { $exts['.' + $x] = $true }
        }

        # ---- 1. bestanden opsommen ---------------------------------
        $seen  = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $files = New-Object System.Collections.ArrayList

        # Lock-bestanden komen in dezelfde opsomming langs. Ze worden hier
        # apart gehouden en na afloop nagelopen, zodat er geen tweede ronde
        # over de share nodig is.
        $locks = New-Object System.Collections.ArrayList

        foreach ($folder in $st.Folders) {

            if ($sync.ScanCancel) { break }

            $sync.ScanStatus = "Map doorzoeken: $folder"
            W "Doorzoeken: $folder  (recursief: $($st.Recursive))"

            try {
                $items = Get-ChildItem -LiteralPath $folder -File -Recurse:$st.Recursive -Force -ErrorAction SilentlyContinue
            }
            catch {
                W "Kan map niet lezen: $folder  ($($_.Exception.Message))" 'FOUT'
                continue
            }

            foreach ($f in $items) {
                if ($sync.ScanCancel) { break }

                if ($f.Name -like '*.x265lock' -or $f.Name -like '*.x265lock.oud_*') {
                    [void]$locks.Add($f)
                    continue
                }

                if (-not $exts.ContainsKey($f.Extension.ToLower())) { continue }
                if ($f.Length -le 0) { continue }
                if ($f.FullName -like '*\ffmpeg\bin\*') { continue }
                if ($f.Name -like 'x265_*.tmp.mkv') { continue }
                if ($f.Name -like 'x265_*.mux.mkv') { continue }
                if ($f.Name -like 'x265_*.pad.mkv') { continue }

                # Bestanden die eerder VCP kregen overslaan: bij die omzetting
                # ging geluid verloren dat in de bron wel zat, dus het heeft
                # geen zin er nog een keer uren in te steken. Weghalen van de
                # markering in de naam maakt hem weer gewoon zichtbaar.
                if ($vcpPat -and $f.BaseName -match $vcpPat) {
                    $sync.ScanSkippedVcp = $sync.ScanSkippedVcp + 1
                    continue
                }

                if ($seen.Add($f.FullName)) { [void]$files.Add($f) }
            }
        }

        # ---- 1b. achtergebleven lock-bestanden opruimen -------------
        #
        #  Een lock waarvan de bron niet meer bestaat kan alleen van een
        #  afgebroken run zijn: het bestand is omgezet, het origineel is
        #  weg, maar het opruimen is er niet meer van gekomen. Een lock
        #  waarvan de bron er nog wel is blijft staan - die kan van een pc
        #  zijn die op dit moment aan het werk is.
        if ($locks.Count -gt 0 -and -not $sync.ScanCancel) {
            # Er ligt een lock in deze map: er is dus een andere pc in de
            # weer geweest. Aan het eind van de rit is nog een rondje
            # kijken de moeite waard.
            $sync.LockGezien = $true
            $opgeruimd = 0
            $stale = 15.0
            if ($st.LockStaleMinutes) { $stale = [double]$st.LockStaleMinutes }
            foreach ($lk in $locks) {
                if ($sync.ScanCancel) { break }

                $bron = ''
                if ($lk.Name -like '*.x265lock') {
                    $bron = $lk.FullName.Substring(0, $lk.FullName.Length - 9)
                }
                else {
                    # een '.oud_xxxxxxxx'-restje van een overname
                    $i = $lk.FullName.LastIndexOf('.x265lock.oud_')
                    if ($i -gt 0) { $bron = $lk.FullName.Substring(0, $i) }
                }
                if (-not $bron) { continue }

                $bronErNog = $false
                try { $bronErNog = [System.IO.File]::Exists($bron) } catch { $bronErNog = $true }
                if ($bronErNog) { continue }
                if ((Get-LockAge $lk.FullName) -lt $stale) { continue }

                try { Remove-Item -LiteralPath $lk.FullName -Force -ErrorAction Stop; $opgeruimd++ }
                catch { }
            }
            if ($opgeruimd -gt 0) {
                W ("{0} achtergebleven lock-bestand(en) opgeruimd." -f $opgeruimd)
            }
        }

        $sync.ScanTotal = $files.Count
        W "$($files.Count) bestand(en) met een video-extensie gevonden. Nu analyseren met ffprobe."

        # ---- 2. analyseren -----------------------------------------
        foreach ($f in $files) {

            if ($sync.ScanCancel) { break }

            $sync.ScanChecked = $sync.ScanChecked + 1
            $sync.ScanStatus  = "Analyseren $($sync.ScanChecked)/$($sync.ScanTotal): $($f.Name)"

            $info = Probe-File $f.FullName

            if ($info -eq $null) {
                $sync.ScanSkippedNoVid = $sync.ScanSkippedNoVid + 1
                continue
            }

            # Al-HEVC-bestanden worden altijd overgeslagen (vast gedrag,
            # er is geen instelling meer voor).
            $isHevc = ($info.Codec -match '(?i)^(hevc|h265|x265)$')

            if ($isHevc) { $sync.ScanSkippedHevc = $sync.ScanSkippedHevc + 1 }
            $sync.ScanFound = $sync.ScanFound + 1

            $sync.NewJobs.Enqueue([pscustomobject]@{
                FullPath    = $f.FullName
                Name        = $f.Name
                Folder      = $f.DirectoryName
                SizeBytes   = [long]$f.Length
                DurationSec = [double]$info.DurationSec
                Codec       = $info.Codec
                IsHevc      = $isHevc
                Include     = -not $isHevc
                AutoQueue   = ([bool]$st.AutoQueue -and -not $isHevc)
            })
        }

        if ($sync.ScanCancel) {
            W 'Scan afgebroken door gebruiker.' 'WAARS'
        } else {
            $vcpTxt = ''
            if ($sync.ScanSkippedVcp -gt 0) { $vcpTxt = (" - eerder VCP: {0}" -f $sync.ScanSkippedVcp) }
            W ("Scan gereed. Video's: {0} - al HEVC: {1} - geen video/onleesbaar: {2}{3}" -f `
                $sync.ScanFound, $sync.ScanSkippedHevc, $sync.ScanSkippedNoVid, $vcpTxt)
        }
    }
    catch {
        $sync.WorkerError = $_.Exception.Message
        W "Onverwachte fout tijdens scannen: $($_.Exception.Message)" 'FOUT'
    }
    finally {
        $sync.ScanStatus = ''
        $sync.ScanBusy   = $false
    }
}
