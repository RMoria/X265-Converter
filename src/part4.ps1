
# ---------------------------------------------------------------------
# 7.  Hulpfuncties die ook in de werk-thread nodig zijn
# ---------------------------------------------------------------------

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
