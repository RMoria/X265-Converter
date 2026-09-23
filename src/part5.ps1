
# ---------------------------------------------------------------------
# 9.  WERK-THREAD  2 :  converteren
# ---------------------------------------------------------------------

$ConvertWorker = {

    $ErrorActionPreference = 'Continue'

    $st       = $sync.Settings
    $swWall   = [Diagnostics.Stopwatch]::StartNew()
    $swActive = [Diagnostics.Stopwatch]::StartNew()

    # -----------------------------------------------------------------
    function Update-Timers {
        $sync.WallSec   = $swWall.Elapsed.TotalSeconds
        $sync.ActiveSec = $swActive.Elapsed.TotalSeconds
        $pd = $sync.WallSec - $sync.ActiveSec
        if ($pd -lt 0) { $pd = 0 }
        $sync.PausedSec = $pd

        # De hartslag van het lock hoort hier en niet in elke lus apart.
        # Update-Timers wordt aangeroepen vanuit ALLE poll-lussen -
        # encoderen, remuxen, opvullen, kopieren, verplaatsen, wachten
        # tijdens een pauze - dus zo kan er geen lus zijn die hem vergeet.
        # Beat-Lock houdt zichzelf op een keer per minuut, dus dit kost
        # niets.
        Beat-Lock $script:HuidigLock
    }

    function Sync-PauseState {
        param($Proc)
        if ($sync.PauseRequested -and -not $sync.IsPaused) {
            if ($Proc -ne $null) {
                try { if (-not $Proc.HasExited) { [void][X265.NativeProc]::Suspend($Proc.Handle) } } catch { }
            }
            $swActive.Stop()
            $sync.IsPaused = $true
            W 'Gepauzeerd.' 'PAUZE'
        }
        elseif (-not $sync.PauseRequested -and $sync.IsPaused) {
            if ($Proc -ne $null) {
                try { if (-not $Proc.HasExited) { [void][X265.NativeProc]::Resume($Proc.Handle) } } catch { }
            }
            $swActive.Start()
            $sync.IsPaused = $false
            W 'Hervat.' 'PAUZE'
        }
    }

    function Wait-WhilePaused {
        param($Proc)
        Sync-PauseState $Proc
        while ($sync.IsPaused -and -not $sync.Cancel) {
            Update-Timers
            Start-Sleep -Milliseconds 250
            Sync-PauseState $Proc
        }
    }

    function Sleep-Interruptible {
        param([double]$Seconds)
        $end = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $end) {
            if ($sync.Cancel) { return }
            Wait-WhilePaused $null
            Update-Timers
            Start-Sleep -Milliseconds 250
        }
    }

    # -----------------------------------------------------------------
    function Get-CleanBase {
        param([string]$Base)
        $n = $Base
        # h264 / h.264 / h 264 / x264 / x.264 verwijderen, samen met een
        # eventueel scheidingsteken ervoor, zodat er geen '..' achterblijft
        $n = $n -replace '(?i)[\s._-]*(?<![a-z0-9])[hx][\.\s_-]?264(?![0-9])', ''
        $n = $n -replace '(?i)[\s._-]*(?<![a-z0-9])avc(?![a-z0-9])', ''
        $n = $n -replace '\(\s*\)', ''
        $n = $n -replace '\[\s*\]', ''
        $n = $n -replace '\{\s*\}', ''
        $n = $n -replace '\.{2,}', '.'
        $n = $n -replace '_{2,}', '_'
        $n = $n -replace '\s{2,}', ' '
        $n = $n -replace '\s+\.', '.'
        $n = $n -replace '\.\s+', '.'
        $n = $n.Trim(' ', '.', '-', '_')
        if ([string]::IsNullOrWhiteSpace($n)) { $n = $Base.Trim() }
        return $n
    }

    function New-OutputPath {
        param([string]$SourcePath, [string]$Fixed = '')

        # Is er met -Out een naam meegegeven, dan is dat de naam. Geen
        # '.x265' erachter, geen '(2)' erbij: wie het pad zelf opgeeft
        # verwacht precies dat pad. Wel de map aanmaken als die ontbreekt.
        if (-not [string]::IsNullOrWhiteSpace($Fixed)) {
            try {
                $od = [IO.Path]::GetDirectoryName($Fixed)
                if ($od -and -not (Test-Path -LiteralPath $od)) {
                    New-Item -ItemType Directory -Path $od -Force -ErrorAction Stop | Out-Null
                }
            }
            catch { W ("Uitvoermap kon niet worden gemaakt: {0}" -f $_.Exception.Message) 'WAARS' }
            return $Fixed
        }

        $dir   = [IO.Path]::GetDirectoryName($SourcePath)
        $base  = Get-CleanBase ([IO.Path]::GetFileNameWithoutExtension($SourcePath))
        $cand  = Join-Path $dir ($base + '.x265.mkv')
        $i = 2
        while (Test-Path -LiteralPath $cand) {
            $cand = Join-Path $dir ('{0}.x265 ({1}).mkv' -f $base, $i)
            $i++
            if ($i -gt 500) { break }
        }
        return $cand
    }

    function Remove-WithRetry {
        param([string]$FilePath, [int]$Attempts = 10, [int]$WaitSeconds = 10)

        if (-not (Test-Path -LiteralPath $FilePath)) { return $true }

        for ($n = 1; $n -le $Attempts; $n++) {

            if (-not (Test-Path -LiteralPath $FilePath)) { return $true }

            try { Remove-Item -LiteralPath $FilePath -Force -ErrorAction Stop }
            catch { }

            if (-not (Test-Path -LiteralPath $FilePath)) {
                if ($n -gt 1) { W "Verwijderd na poging $n : $FilePath" }
                return $true
            }

            if ($n -lt $Attempts) {
                W "Bestand nog in gebruik (poging $n/$Attempts), $WaitSeconds s wachten: $FilePath" 'WAARS'
                Sleep-Interruptible $WaitSeconds
                if ($sync.Cancel) { return $false }
            }
        }

        W "Kon bestand niet verwijderen: $FilePath" 'FOUT'
        return $false
    }

    function Move-WithProgress {
        param([string]$Source, [string]$Target)

        # snelle weg: zelfde volume
        try {
            [IO.File]::Move($Source, $Target)
            $sync.CurPhasePct = 100
            return $true
        }
        catch { }

        # trage weg: gebufferd kopieren met voortgang (ander volume / UNC)
        $in = $null; $out = $null
        try {
            $bufSize = 4194304
            $buf     = New-Object byte[] $bufSize
            $in      = [IO.File]::Open($Source, [IO.FileMode]::Open,   [IO.FileAccess]::Read,  [IO.FileShare]::Read)
            $out     = [IO.File]::Open($Target, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)

            $total = $in.Length
            $done  = [long]0

            while ($true) {
                $n = $in.Read($buf, 0, $bufSize)
                if ($n -le 0) { break }
                $out.Write($buf, 0, $n)
                $done = $done + $n
                if ($total -gt 0) { $sync.CurPhasePct = 100.0 * $done / $total }
                if ($sync.Cancel) { throw 'Afgebroken door gebruiker.' }
                Wait-WhilePaused $null
                if ($sync.Cancel) { throw 'Afgebroken door gebruiker.' }
                Update-Timers
            }

            $out.Flush()
            $out.Dispose(); $out = $null
            $in.Dispose();  $in  = $null

            Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
            return $true
        }
        catch {
            $sync.LastMoveError = $_.Exception.Message
            if ($out -ne $null) { try { $out.Dispose() } catch { } }
            if ($in  -ne $null) { try { $in.Dispose()  } catch { } }
            Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
            return $false
        }
        finally {
            if ($out -ne $null) { try { $out.Dispose() } catch { } }
            if ($in  -ne $null) { try { $in.Dispose()  } catch { } }
        }
    }

    # -----------------------------------------------------------------
    function Read-EncodeProgress {
        param([string]$ProgressPath)

        if (-not (Test-Path -LiteralPath $ProgressPath)) { return }

        try {
            $fs = [IO.File]::Open($ProgressPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                $len = $fs.Length
                if ($len -le 0) { return }
                $take = [int][Math]::Min([long]12288, $len)
                [void]$fs.Seek($len - $take, [IO.SeekOrigin]::Begin)
                $buf  = New-Object byte[] $take
                $read = $fs.Read($buf, 0, $take)
                $txt  = [Text.Encoding]::ASCII.GetString($buf, 0, $read)
            }
            finally { $fs.Dispose() }
        }
        catch { return }

        foreach ($line in ($txt -split "`n")) {
            $l = $line.Trim()
            if ($l.Length -lt 3) { continue }
            $eq = $l.IndexOf('=')
            if ($eq -lt 1) { continue }
            $k = $l.Substring(0, $eq)
            $v = $l.Substring($eq + 1).Trim()

            switch ($k) {
                'out_time' {
                    try {
                        $ts = [TimeSpan]::Parse($v, [Globalization.CultureInfo]::InvariantCulture)
                        if ($ts.TotalSeconds -ge 0) {
                            $sync.CurVideoSec = $ts.TotalSeconds
                            if ($sync.CurDurationSec -gt 0) {
                                $pct = 100.0 * $ts.TotalSeconds / $sync.CurDurationSec
                                if ($pct -gt 100) { $pct = 100 }
                                $sync.CurPhasePct = $pct
                            }
                        }
                    } catch { }
                }
                'fps'        { $sync.CurFps     = $v }
                'speed'      { $sync.CurSpeed   = $v }
                'bitrate'    { $sync.CurBitrate = $v }
                'total_size' {
                    $tmpL = [long]0
                    if ([long]::TryParse($v, [ref]$tmpL)) { $sync.CurTempSize = $tmpL }
                }
            }
        }
    }

    # -----------------------------------------------------------------
    #  Speelduur van een bestand
    #
    #  Drie manieren, van goedkoop naar duur. De eerste is wat de scan
    #  ook doet. Geeft die niets, dan wordt er zonder -select_streams
    #  gevraagd, en als laatste wordt de tijdstempel van het allerlaatste
    #  videopakket opgevraagd - dat werkt ook bij een container die zijn
    #  duur helemaal niet opschrijft, maar kost een keer doorlezen.
    # -----------------------------------------------------------------
    function Get-DurationSec {
        param([string]$FilePath)

        function ParseDur {
            param([string]$Tekst)
            if ([string]::IsNullOrWhiteSpace($Tekst)) { return 0.0 }
            $t = $Tekst.Trim()
            if ($t -eq 'N/A') { return 0.0 }
            $d = 0.0
            $ok = [double]::TryParse($t,
                    [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$d)
            if ($ok -and $d -gt 0) { return $d }
            return 0.0
        }

        try {
            $r = (& $sync.Ffprobe -v error -show_entries format=duration `
                    -of default=nw=1:nk=1 $FilePath 2>$null) -join ' '
            $d = ParseDur $r
            if ($d -gt 0) { return $d }
        } catch { }

        try {
            $r = (& $sync.Ffprobe -v error -select_streams v:0 -show_entries stream=duration `
                    -of default=nw=1:nk=1 $FilePath 2>$null) -join ' '
            $d = ParseDur $r
            if ($d -gt 0) { return $d }
        } catch { }

        # Laatste redmiddel: de tijdstempel van het laatste videopakket.
        # -read_intervals springt naar het eind, dus dit is niet het hele
        # bestand doorlezen.
        try {
            $r = (& $sync.Ffprobe -v error -select_streams v:0 -show_entries packet=pts_time `
                    -of csv=p=0 -read_intervals '999999%+#1' $FilePath 2>$null)
            $laatste = 0.0
            foreach ($regel in @($r)) {
                $d = ParseDur ([string]$regel)
                if ($d -gt $laatste) { $laatste = $d }
            }
            if ($laatste -gt 0) { return $laatste }
        } catch { }

        return 0.0
    }

    # -----------------------------------------------------------------
    #  Is dit bestand al een keer omgezet?
    #
    #  De bron hoort na een geslaagde omzetting te verdwijnen, en daarop
    #  leunt het overslaan bij twee pc's. Maar verwijderen kan mislukken -
    #  het bestand is nog in gebruik, de share weigert het - en dan blijft
    #  de bron liggen met het resultaat ernaast ('x265 aangemaakt,
    #  origineel NIET verwijderd'). De andere pc ziet dan een gewoon
    #  h264-bestand en begint vrolijk opnieuw, met een '(2)' als resultaat.
    #
    #  Vandaar deze controle: ligt er al een uitvoerbestand naast dat ook
    #  echt HEVC is, dan is het werk al gedaan.
    # -----------------------------------------------------------------
    function Test-AlOmgezet {
        param([string]$SourcePath, [string]$FixedOut = '')

        $kandidaat = ''
        if (-not [string]::IsNullOrWhiteSpace($FixedOut)) {
            $kandidaat = $FixedOut
        }
        else {
            try {
                $dir  = [IO.Path]::GetDirectoryName($SourcePath)
                $base = Get-CleanBase ([IO.Path]::GetFileNameWithoutExtension($SourcePath))
                $kandidaat = Join-Path $dir ($base + '.x265.mkv')
            }
            catch { return '' }
        }

        if ([string]::IsNullOrWhiteSpace($kandidaat)) { return '' }
        try { if (-not [System.IO.File]::Exists($kandidaat)) { return '' } } catch { return '' }

        $lengte = 0
        try { $lengte = (Get-Item -LiteralPath $kandidaat -ErrorAction Stop).Length } catch { return '' }
        if ($lengte -le 0) { return '' }

        # Bestaan is niet genoeg: een half afgebroken bestand van een
        # eerdere poging mag de bron niet voor altijd blokkeren.
        $codec = ''
        try {
            $codec = (& $sync.Ffprobe -v error -select_streams v:0 `
                        -show_entries stream=codec_name -of default=nw=1:nk=1 $kandidaat 2>$null) -join ''
        }
        catch { return '' }
        if (([string]$codec).Trim() -match '(?i)^(hevc|h265|x265)$') { return $kandidaat }
        return ''
    }

    # -----------------------------------------------------------------
    #  Aantal audiokanalen van de bron
    #
    #  Nodig om een verstandige bitrate te kiezen en om te voorkomen dat
    #  een 7.1-track aan een encoder wordt aangeboden die niet verder
    #  komt dan 5.1. Faalt de probe, dan wordt 2 aangenomen: dat is voor
    #  elke encoder veilig.
    # -----------------------------------------------------------------
    function Get-AudioChannels {
        param([string]$FilePath)

        $aa = @(
            '-v','error'
            '-select_streams','a'
            '-show_entries','stream=channels'
            '-of','csv=p=0'
            $FilePath
        )

        $max = 0
        try {
            $raw = @(& $sync.Ffprobe @aa 2>$null)
            foreach ($l in $raw) {
                $t = ([string]$l).Trim().TrimEnd(',')
                if ($t.Length -lt 1) { continue }
                $n = 0
                if ([int]::TryParse($t, [ref]$n)) { if ($n -gt $max) { $max = $n } }
            }
        }
        catch { }

        if ($max -lt 1) { return 2 }
        return $max
    }

    # -----------------------------------------------------------------
    #  Welke sporen gaan mee, en hoe
    #
    #  Blind '-map 0' gaat stuk op mp4's. MKV kan namelijk alleen beeld,
    #  geluid en ondertitels opslaan, en een mp4 bevat vaak meer:
    #
    #    - een timecodespoor (tmcd), dat als 'data' binnenkomt. MKV weigert
    #      dat, de header wordt niet geschreven, en ffmpeg meldt "Nothing
    #      was written into output file, because at least one of its
    #      streams received no packets".
    #    - mov_text-ondertitels, die MKV niet kan kopieren ("Subtitle codec
    #      94213 is not supported"). Die moeten naar srt worden omgezet.
    #    - een omslagafbeelding als tweede videospoor, die anders onnodig
    #      door de x265-encoder gaat.
    #
    #  Daarom worden de sporen vooraf opgevraagd en wordt er een expliciete
    #  maplijst gebouwd. Ondertitelcodecs krijgen per spoor hun eigen
    #  instelling: een PGS-spoor mag niet naar srt (dat zijn plaatjes), een
    #  mov_text-spoor moet dat juist wel.
    # -----------------------------------------------------------------
    function Get-StreamPlan {
        param([string]$FilePath)

        $res = [pscustomobject]@{ Ok = $false; Map = @(); SubArgs = @(); Notes = @() }

        $aa = @('-v','error','-show_entries',
                'stream=index,codec_type,codec_name:stream_disposition=attached_pic',
                '-of','json',$FilePath)
        try   { $raw = (& $sync.Ffprobe @aa 2>$null) -join "`n" }
        catch { return $res }
        if ([string]::IsNullOrWhiteSpace($raw)) { return $res }
        try   { $j = $raw | ConvertFrom-Json }
        catch { return $res }
        if (-not $j.streams -or @($j.streams).Count -lt 1) { return $res }

        # wat matroska aan ondertitels kan bewaren zoals het is
        $subCopy = @('subrip','srt','ass','ssa','webvtt','hdmv_pgs_subtitle','dvd_subtitle','dvb_subtitle')
        # tekstformaten uit mp4/mov die eerst naar srt moeten
        $subNaarSrt = @('mov_text','tx3g','text')

        $map    = New-Object System.Collections.ArrayList
        $subs   = New-Object System.Collections.ArrayList
        $notes  = New-Object System.Collections.ArrayList
        $subIdx = 0
        $vids   = 0

        foreach ($stm in @($j.streams)) {
            $ix = [int]$stm.index
            $ty = [string]$stm.codec_type
            $cn = ([string]$stm.codec_name).ToLowerInvariant()

            switch ($ty) {
                'video' {
                    $isPic = $false
                    try { $isPic = ([int]$stm.disposition.attached_pic -eq 1) } catch { }
                    if ($isPic) { [void]$notes.Add(("spoor {0}: omslagafbeelding, niet meegenomen" -f $ix)); break }
                    [void]$map.Add('-map'); [void]$map.Add(('0:{0}' -f $ix))
                    $vids++
                }
                'audio' {
                    [void]$map.Add('-map'); [void]$map.Add(('0:{0}' -f $ix))
                }
                'subtitle' {
                    if ($subCopy -contains $cn) {
                        [void]$map.Add('-map'); [void]$map.Add(('0:{0}' -f $ix))
                        [void]$subs.Add(('-c:s:{0}' -f $subIdx)); [void]$subs.Add('copy')
                        $subIdx++
                    }
                    elseif ($subNaarSrt -contains $cn) {
                        [void]$map.Add('-map'); [void]$map.Add(('0:{0}' -f $ix))
                        [void]$subs.Add(('-c:s:{0}' -f $subIdx)); [void]$subs.Add('srt')
                        [void]$notes.Add(("spoor {0}: {1}-ondertitels worden omgezet naar srt" -f $ix, $cn))
                        $subIdx++
                    }
                    else {
                        [void]$notes.Add(("spoor {0}: ondertitelformaat {1} kan niet in mkv, niet meegenomen" -f $ix, $cn))
                    }
                }
                'attachment' {
                    [void]$map.Add('-map'); [void]$map.Add(('0:{0}' -f $ix))
                }
                default {
                    # data, timecode en al het andere: mkv kan er niets mee
                    [void]$notes.Add(("spoor {0}: {1} ({2}) kan niet in mkv, niet meegenomen" -f $ix, $ty, $cn))
                }
            }
        }

        if ($vids -lt 1) { return $res }

        $res.Ok      = $true
        $res.Map     = $map.ToArray()
        $res.SubArgs = $subs.ToArray()
        $res.Notes   = $notes.ToArray()
        return $res
    }

    # -----------------------------------------------------------------
    #  Audio-argumenten
    #
    #  'aresample=async=1' is hier het hele punt: filling and trimming.
    #  Een gat in de bronstream wordt met stilte opgevuld en een overlap
    #  weggeknipt, in plaats van dat de sprong in de tijdstempels wordt
    #  overgenomen. 'first_pts=0' laat de nieuwe track netjes op nul
    #  beginnen. Zonder dat blijft een scheve start staan.
    # -----------------------------------------------------------------
    function Get-AudioArgs {
        param([string]$Mode, [int]$Channels)

        $a = New-Object System.Collections.ArrayList

        if ($Mode -eq 'copy' -or [string]::IsNullOrWhiteSpace($Mode)) {
            [void]$a.Add('-c:a'); [void]$a.Add('copy')
            return $a.ToArray()
        }

        $ch = $Channels
        if ($ch -lt 1) { $ch = 2 }

        switch ($Mode) {
            'ac3' {
                # de ac3-encoder komt niet verder dan 5.1
                if ($ch -gt 6) { [void]$a.Add('-ac'); [void]$a.Add('6'); $ch = 6 }
                $br = 224
                if ($ch -ge 6) { $br = 448 } elseif ($ch -ge 3) { $br = 384 }
                foreach ($x in @('-c:a','ac3','-b:a',("{0}k" -f $br))) { [void]$a.Add($x) }
            }
            'flac' {
                foreach ($x in @('-c:a','flac','-compression_level','5')) { [void]$a.Add($x) }
            }
            default {
                if ($ch -gt 8) { [void]$a.Add('-ac'); [void]$a.Add('8'); $ch = 8 }
                $br = 192
                switch ($ch) {
                    1 { $br = 96 }
                    2 { $br = 192 }
                    6 { $br = 384 }
                    8 { $br = 512 }
                    default { $br = [int]($ch * 80); if ($br -lt 96) { $br = 96 } }
                }
                foreach ($x in @('-c:a','aac','-b:a',("{0}k" -f $br))) { [void]$a.Add($x) }
            }
        }

        foreach ($x in @('-af','aresample=async=1:first_pts=0')) { [void]$a.Add($x) }
        return $a.ToArray()
    }

    function Get-EncodeArgs {
        param([string]$Variant, [int]$Channels, $Plan)

        $a = New-Object System.Collections.ArrayList

        if ($Variant -eq 'safe') {
            # laatste redmiddel: alleen beeld en geluid, verder niets
            foreach ($x in @('-map','0:v:0','-map','0:a?')) { [void]$a.Add($x) }
        }
        elseif ($Plan -ne $null -and $Plan.Ok) {
            foreach ($x in $Plan.Map) { [void]$a.Add($x) }
        }
        else {
            # kon de sporen niet uitlezen: neem alles behalve datastromen,
            # want die weigert de mkv-muxer sowieso
            foreach ($x in @('-map','0','-map','-0:d')) { [void]$a.Add($x) }
        }

        [void]$a.Add('-c:v'); [void]$a.Add($st.Codec)

        switch ($st.Codec) {
            'libx265' {
                foreach ($x in @('-preset', $st.Preset, '-crf', "$($st.Crf)",
                                 '-x265-params', 'log-level=error')) { [void]$a.Add($x) }
            }
            'hevc_nvenc' {
                foreach ($x in @('-preset', $st.Preset, '-rc', 'vbr', '-cq', "$($st.Crf)", '-b:v', '0')) { [void]$a.Add($x) }
            }
            'hevc_qsv' {
                foreach ($x in @('-preset', $st.Preset, '-global_quality', "$($st.Crf)")) { [void]$a.Add($x) }
            }
            'hevc_amf' {
                foreach ($x in @('-quality', $st.Preset, '-rc', 'cqp', '-qp_i', "$($st.Crf)", '-qp_p', "$($st.Crf)")) { [void]$a.Add($x) }
            }
            default {
                foreach ($x in @('-preset', $st.Preset, '-crf', "$($st.Crf)")) { [void]$a.Add($x) }
            }
        }

        foreach ($x in (Get-AudioArgs -Mode ([string]$st.AudioMode) -Channels $Channels)) { [void]$a.Add($x) }

        if ($Variant -eq 'safe') {
            # geen ondertitels in de veilige variant
        }
        elseif ($Plan -ne $null -and $Plan.Ok) {
            # per ondertitelspoor apart: kopieren waar dat kan, omzetten
            # naar srt waar het moet. Een vaste '-c:s copy' gaat stuk op
            # mov_text, en een vaste '-c:s srt' zou beeldondertitels slopen.
            foreach ($x in $Plan.SubArgs) { [void]$a.Add($x) }
            [void]$a.Add('-c:t'); [void]$a.Add('copy')
        }
        else {
            foreach ($x in @('-c:s','copy','-c:t','copy')) { [void]$a.Add($x) }
        }

        # '-max_interleave_delta 0': de muxer mag niet meer voortijdig een
        # pakket wegschrijven omdat hij te lang op een dun bezet spoor
        # wacht. Standaard doet hij dat na 10 seconden, en dan komen beeld,
        # geluid en ondertitels niet meer netjes door elkaar in het bestand
        # te staan. Een speler leest lineair en verliest dan geluid en
        # ondertitels terwijl het beeld doorloopt - precies de klacht.
        #
        # Dit is de documentatieregel erachter: "above which libavformat
        # will output a packet regardless of whether it has queued a packet
        # for all the streams". Met 0 blijft hij wachten.
        foreach ($x in @('-max_interleave_delta','0')) { [void]$a.Add($x) }

        return $a.ToArray()
    }

    function Invoke-Encode {
        param(
            [string]   $SourcePath,
            [string]   $TempPath,
            [string]   $ProgressPath,
            [string[]] $EncodeArgs
        )

        Remove-Item -LiteralPath $ProgressPath -Force -ErrorAction SilentlyContinue

        $all = New-Object System.Collections.ArrayList
        foreach ($x in @('-hide_banner','-nostdin','-loglevel','warning','-nostats',
                         '-progress', $ProgressPath, '-y', '-i', $SourcePath)) { [void]$all.Add($x) }
        foreach ($x in $EncodeArgs) { [void]$all.Add($x) }
        [void]$all.Add($TempPath)

        $cmdLine = (($all | ForEach-Object { Quote-Arg $_ }) -join ' ')
        W "ffmpeg $cmdLine" 'CMD'

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $sync.Ffmpeg
        $psi.Arguments              = $cmdLine
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.RedirectStandardInput  = $true
        $psi.WorkingDirectory       = $st.WorkDir

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi

        try { [void]$p.Start() }
        catch {
            return [pscustomobject]@{ Code = -1; Err = "ffmpeg kon niet worden gestart: $($_.Exception.Message)" }
        }

        $sync.CurrentProcess = $p
        $errTask = $p.StandardError.ReadToEndAsync()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        try { $p.StandardInput.Close() } catch { }

        while (-not $p.HasExited) {
            if ($sync.Cancel) {
                W 'Conversie wordt afgebroken…' 'WAARS'
                if ($sync.IsPaused) {
                    try { [void][X265.NativeProc]::Resume($p.Handle) } catch { }
                    $swActive.Start()
                    $sync.IsPaused       = $false
                    $sync.PauseRequested = $false
                }
                try { $p.Kill() } catch { }
                break
            }
            Sync-PauseState $p
            Read-EncodeProgress $ProgressPath
            Update-Timers
            Start-Sleep -Milliseconds 400
        }

        try { $p.WaitForExit(20000) | Out-Null } catch { }
        Read-EncodeProgress $ProgressPath

        $stderrText = ''
        try { $stderrText = $errTask.Result } catch { }
        try { $null = $outTask.Result } catch { }

        $code = -1
        try { $code = $p.ExitCode } catch { }

        $sync.CurrentProcess = $null
        try { $p.Dispose() } catch { }

        return [pscustomobject]@{ Code = $code; Err = $stderrText }
    }

    # -----------------------------------------------------------------
    #  Staart met stilte opvullen
    #
    #  Voor bronnen waarvan het geluid zelf al voor het beeld ophoudt. Er
    #  komt geen geluid bij dat er niet was; het spoor wordt doorgetrokken
    #  tot het einde van het beeld, zodat spelers aan het eind niet
    #  struikelen over een audiospoor dat er ineens niet meer is.
    #
    #  Het beeld wordt gekopieerd, alleen het geluid gaat opnieuw door de
    #  encoder. Dat is een kwestie van seconden, geen tweede volledige
    #  conversie. 'apad' met whole_dur knipt nooit iets af: is het geluid
    #  al lang genoeg, dan gebeurt er niets.
    # -----------------------------------------------------------------
    function Invoke-PadAudio {
        param([string]$InPath, [string]$OutPath, [double]$DurationSec, [int]$Channels)

        $dur = [string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$DurationSec)

        $aa = New-Object System.Collections.ArrayList
        foreach ($x in @('-hide_banner','-nostdin','-loglevel','warning','-nostats','-y',
                         '-i',$InPath,'-map','0','-c','copy')) { [void]$aa.Add($x) }
        foreach ($x in (Get-AudioArgs -Mode 'aac' -Channels $Channels)) { [void]$aa.Add($x) }
        # de -af uit Get-AudioArgs vervangen door dezelfde plus apad
        for ($i = 0; $i -lt $aa.Count; $i++) {
            if ($aa[$i] -eq '-af') { $aa[$i+1] = ('aresample=async=1:first_pts=0,apad=whole_dur={0}' -f $dur); break }
        }
        foreach ($x in @('-max_interleave_delta','0',$OutPath)) { [void]$aa.Add($x) }

        $cmdLine = (($aa | ForEach-Object { Quote-Arg $_ }) -join ' ')
        W "ffmpeg $cmdLine" 'CMD'

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $sync.Ffmpeg
        $psi.Arguments              = $cmdLine
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.WorkingDirectory       = $st.WorkDir

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        try { [void]$p.Start() }
        catch { return [pscustomobject]@{ Ok = $false; Err = ('opvullen kon niet starten: ' + $_.Exception.Message) } }

        $sync.CurrentProcess = $p
        $errTask = $p.StandardError.ReadToEndAsync()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        while (-not $p.HasExited) {
            if ($sync.Cancel) { try { $p.Kill() } catch { }; break }
            Sync-PauseState $p
            Update-Timers
            Start-Sleep -Milliseconds 300
        }
        try { $p.WaitForExit(20000) | Out-Null } catch { }
        $errText = ''
        try { $errText = $errTask.Result } catch { }
        try { $null = $outTask.Result } catch { }
        $code = -1
        try { $code = $p.ExitCode } catch { }
        $sync.CurrentProcess = $null
        try { $p.Dispose() } catch { }

        if ($sync.Cancel) { return [pscustomobject]@{ Ok = $false; Err = 'afgebroken' } }
        [void](Write-FfmpegWarnings $errText)

        $ok = $false
        if ($code -eq 0 -and (Test-Path -LiteralPath $OutPath)) {
            try { $ok = ((Get-Item -LiteralPath $OutPath).Length -gt 0) } catch { }
        }
        if (-not $ok) { return [pscustomobject]@{ Ok = $false; Err = ("opvullen mislukt (exitcode {0})" -f $code) } }
        return [pscustomobject]@{ Ok = $true; Err = '' }
    }

    # -----------------------------------------------------------------
    #  Bron markeren als VCP
    #
    #  Voor bestanden waarbij de omzetting aantoonbaar geluid heeft
    #  verloren dat in de bron wel zat. Het resultaat gaat weg, de bron
    #  blijft en krijgt VCP in de naam. De scanner slaat zulke bestanden
    #  over, zodat een volgende ronde over dezelfde map er geen uren meer
    #  in steekt.
    # -----------------------------------------------------------------
    function Set-VcpName {
        param([string]$FilePath, [string]$Marker)

        try {
            $dir  = [IO.Path]::GetDirectoryName($FilePath)
            $base = [IO.Path]::GetFileNameWithoutExtension($FilePath)
            $ext  = [IO.Path]::GetExtension($FilePath)

            if ($base -match ("(?i)\.{0}$" -f [Regex]::Escape($Marker))) {
                return [pscustomobject]@{ Ok = $true; Path = $FilePath; Note = 'stond al gemarkeerd' }
            }

            $cand = Join-Path $dir ($base + '.' + $Marker + $ext)
            $n = 2
            while (Test-Path -LiteralPath $cand) {
                $cand = Join-Path $dir ($base + '.' + $Marker + " ($n)" + $ext)
                $n++
                if ($n -gt 99) { return [pscustomobject]@{ Ok = $false; Path = $FilePath; Note = 'geen vrije naam' } }
            }

            Move-Item -LiteralPath $FilePath -Destination $cand -Force
            return [pscustomobject]@{ Ok = $true; Path = $cand; Note = '' }
        }
        catch {
            return [pscustomobject]@{ Ok = $false; Path = $FilePath; Note = $_.Exception.Message }
        }
    }

    # -----------------------------------------------------------------
    #  Interleaving nameten: ligt het geluid waar het beeld is?
    #
    #  Waarom dit er is: als de sporen niet netjes door elkaar in het
    #  bestand staan, vallen bij het afspelen geluid EN ondertitels
    #  ergens halverwege weg terwijl het beeld doorloopt, en doorspoelen
    #  lokt het uit. Dat is precies wat er gebeurde.
    #
    #  De meting doet na wat een speler doet: op een aantal punten in het
    #  bestand springen en kijken of daar meteen audiopakketten liggen die
    #  bij het beeld op diezelfde plek horen. Een seek landt altijd op het
    #  keyframe voor het gevraagde punt, dus er wordt met VIDEO vergeleken
    #  en niet met het gevraagde tijdstip - anders geeft elke meting alarm.
    #
    #  Kosten: seeks, geen volledige leesronde. Enkele MB voor een hele
    #  film, en het bestand is net geschreven dus het staat nog in de
    #  cache. LET OP: '-select_streams' mag hier NIET bij, dat blokkeert
    #  de seek en dan wordt het hele bestand alsnog gelezen.
    # -----------------------------------------------------------------
    function Test-Interleave {
        param([string]$FilePath, [double]$DurationSec, [int]$Punten = 8, [double]$Tolerantie = 5.0)

        $res = [pscustomobject]@{ Checked = $false; Ok = $true; Bad = 0; Punten = 0; Note = '' }

        if ([double]::IsNaN($DurationSec) -or $DurationSec -le 30) { $res.Note = 'te kort om te meten'; return $res }

        # video- en audio-index uit de kop
        $vIdx = -1
        $aIdx = New-Object System.Collections.ArrayList
        try {
            $raw = (& $sync.Ffprobe -v error -show_entries stream=index,codec_type -of csv=p=0 $FilePath 2>$null)
            foreach ($l in @($raw)) {
                $a = ([string]$l).Split(',')
                if ($a.Count -lt 2) { continue }
                $ix = 0
                if (-not [int]::TryParse($a[0].Trim(), [ref]$ix)) { continue }
                if ($a[1] -eq 'video' -and $vIdx -lt 0) { $vIdx = $ix }
                elseif ($a[1] -eq 'audio') { [void]$aIdx.Add($ix) }
            }
        }
        catch { $res.Note = 'kon de sporen niet uitlezen'; return $res }

        if ($vIdx -lt 0 -or $aIdx.Count -lt 1) { $res.Note = 'geen beeld- of geluidsspoor'; return $res }

        $bad = 0
        $gedaan = 0
        for ($i = 1; $i -le $Punten; $i++) {
            if ($sync.Cancel) { return $res }

            $t  = $DurationSec * $i / ($Punten + 1)
            $iv = ('{0}%+6' -f [string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$t))

            try {
                $lines = @(& $sync.Ffprobe -v error -read_intervals $iv -show_packets `
                             -show_entries packet=stream_index,pts_time -of csv=p=0 $FilePath 2>$null)
            }
            catch { continue }

            $eerste = @{}
            foreach ($l in $lines) {
                $a = ([string]$l).Split(',')
                if ($a.Count -lt 2) { continue }
                $ix = 0
                if (-not [int]::TryParse($a[0].Trim(), [ref]$ix)) { continue }
                $pt = 0.0
                if (-not [double]::TryParse($a[1], [Globalization.NumberStyles]::Float,
                                            [Globalization.CultureInfo]::InvariantCulture, [ref]$pt)) { continue }
                if (-not $eerste.ContainsKey($ix)) { $eerste[$ix] = $pt }
                elseif ($pt -lt $eerste[$ix])       { $eerste[$ix] = $pt }
            }

            if (-not $eerste.ContainsKey($vIdx)) { continue }
            $gedaan++
            $vT = $eerste[$vIdx]

            foreach ($ai in $aIdx) {
                if (-not $eerste.ContainsKey($ai)) { $bad++; break }
                if ([Math]::Abs($eerste[$ai] - $vT) -gt $Tolerantie) { $bad++; break }
            }
        }

        if ($gedaan -lt 1) { $res.Note = 'geen bruikbare meetpunten'; return $res }

        $res.Checked = $true
        $res.Punten  = $gedaan
        $res.Bad     = $bad
        $res.Ok      = ($bad -eq 0)
        if (-not $res.Ok) { $res.Note = ('{0} van {1} punten zonder geluid bij het beeld' -f $bad, $gedaan) }
        return $res
    }

    # -----------------------------------------------------------------
    #  Container opnieuw opbouwen (remux)
    #
    #  Waarom dit er altijd achteraan gaat en niet alleen als er iets mis
    #  lijkt: een remux van het net gemaakte bestand is bewijsbaar
    #  verliesvrij en kost seconden, en hij geeft elke uitvoer dezelfde
    #  containerstructuur - dezelfde die in de praktijk aantoonbaar wel
    #  goed doorspoelt. Nagemeten op een testbestand: video-md5 en
    #  audio-md5 identiek voor en na, en 280 ms voor 2 MB.
    #
    #  De vlag alleen in de encode zetten was niet genoeg om op te
    #  vertrouwen: het defect bleek synthetisch niet na te maken, dus is er
    #  niets om die aanname tegen te testen. Deze stap maakt het resultaat
    #  onafhankelijk van die aanname.
    # -----------------------------------------------------------------
    function Invoke-Remux {
        param([string]$InPath, [string]$OutPath)

        $aa = New-Object System.Collections.ArrayList
        foreach ($x in @('-hide_banner','-nostdin','-loglevel','warning','-nostats','-y',
                         '-i',$InPath,'-map','0','-c','copy',
                         '-max_interleave_delta','0',$OutPath)) { [void]$aa.Add($x) }

        $cmdLine = (($aa | ForEach-Object { Quote-Arg $_ }) -join ' ')
        W "ffmpeg $cmdLine" 'CMD'

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $sync.Ffmpeg
        $psi.Arguments              = $cmdLine
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.WorkingDirectory       = $st.WorkDir

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        try { [void]$p.Start() }
        catch { return [pscustomobject]@{ Ok = $false; Err = ('remux kon niet starten: ' + $_.Exception.Message) } }

        $sync.CurrentProcess = $p
        $errTask = $p.StandardError.ReadToEndAsync()
        $outTask = $p.StandardOutput.ReadToEndAsync()

        while (-not $p.HasExited) {
            if ($sync.Cancel) { try { $p.Kill() } catch { }; break }
            Sync-PauseState $p
            Update-Timers
            Start-Sleep -Milliseconds 300
        }
        try { $p.WaitForExit(20000) | Out-Null } catch { }

        $errText = ''
        try { $errText = $errTask.Result } catch { }
        try { $null = $outTask.Result } catch { }
        $code = -1
        try { $code = $p.ExitCode } catch { }
        $sync.CurrentProcess = $null
        try { $p.Dispose() } catch { }

        if ($sync.Cancel) { return [pscustomobject]@{ Ok = $false; Err = 'afgebroken' } }

        [void](Write-FfmpegWarnings $errText)

        $ok = $false
        if ($code -eq 0 -and (Test-Path -LiteralPath $OutPath)) {
            try { $ok = ((Get-Item -LiteralPath $OutPath).Length -gt 0) } catch { }
        }
        if (-not $ok) { return [pscustomobject]@{ Ok = $false; Err = ("remux mislukt (exitcode {0})" -f $code) } }

        # controleren dat er niets is kwijtgeraakt: even veel sporen, zelfde
        # speelduur. Een remux die streams laat vallen is erger dan geen remux.
        try {
            $q = @('-v','error','-show_entries','stream=index','-show_entries','format=duration','-of','json')
            $a1 = ((& $sync.Ffprobe @q $InPath  2>$null) -join "`n") | ConvertFrom-Json
            $a2 = ((& $sync.Ffprobe @q $OutPath 2>$null) -join "`n") | ConvertFrom-Json
            $n1 = @($a1.streams).Count
            $n2 = @($a2.streams).Count
            if ($n1 -ne $n2) { return [pscustomobject]@{ Ok = $false; Err = ("remux liet sporen vallen ({0} -> {1})" -f $n1, $n2) } }

            $d1 = 0.0; $d2 = 0.0
            [void][double]::TryParse(([string]$a1.format.duration),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$d1)
            [void][double]::TryParse(([string]$a2.format.duration),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$d2)
            if ($d1 -gt 0 -and [Math]::Abs($d1 - $d2) -gt 1.0) {
                return [pscustomobject]@{ Ok = $false; Err = ("speelduur wijkt af na remux ({0:N1} -> {1:N1} s)" -f $d1, $d2) }
            }
        }
        catch { }

        return [pscustomobject]@{ Ok = $true; Err = '' }
    }

    # -----------------------------------------------------------------
    #  Haalt het geluid het einde van het nieuwe bestand?
    #
    #  Dit is het gebrek dat het langst onopgemerkt bleef: de audiotrack
    #  houdt halverwege op en komt niet meer terug, terwijl het beeld
    #  gewoon doorloopt. Een controle op gaten TUSSEN pakketten ziet dat
    #  niet - er is geen gat, de track is er simpelweg niet meer.
    #
    #  De controle is bijna gratis. Er wordt naar de staart van het
    #  bestand gesprongen en daar een venster gelezen; het bestand is net
    #  geschreven en staat dus nog in de cache van het besturingssysteem.
    #
    #  Let op bij het lezen van deze code: '-select_streams' mag er NIET
    #  bij staan. Met die optie negeert ffprobe de seek en leest het het
    #  hele bestand alsnog (nagemeten: 13,4 MB tegen 0,6 MB op hetzelfde
    #  bestand). Daarom komen alle pakketten binnen met hun stream-index
    #  ervoor en wordt er hier op index gefilterd.
    # -----------------------------------------------------------------
    function Test-AudioTail {
        param([string]$FilePath, [double]$ToleranceSec, [double]$WindowSec = 20)

        $res = [pscustomobject]@{
            Checked  = $false
            Ok       = $true
            EndSec   = 0.0
            ShortSec = 0.0
            Note     = ''
        }

        try {
            $aa = @('-v','error',
                    '-show_entries','format=duration',
                    '-show_entries','stream=index,codec_type',
                    '-of','json',$FilePath)
            $raw = (& $sync.Ffprobe @aa 2>$null) -join "`n"
            if ([string]::IsNullOrWhiteSpace($raw)) { $res.Note = 'kon het nieuwe bestand niet uitlezen'; return $res }

            $j = $raw | ConvertFrom-Json

            $dur = 0.0
            if (-not [double]::TryParse(([string]$j.format.duration),
                                        [Globalization.NumberStyles]::Float,
                                        [Globalization.CultureInfo]::InvariantCulture, [ref]$dur)) { $dur = 0.0 }
            if ($dur -le 0) { $res.Note = 'speelduur onbekend'; return $res }

            $ai = -1
            foreach ($stm in @($j.streams)) {
                if ([string]$stm.codec_type -eq 'audio') { $ai = [int]$stm.index; break }
            }
            if ($ai -lt 0) { $res.Note = 'geen audiospoor'; return $res }

            $start = $dur - $WindowSec
            if ($start -lt 0) { $start = 0 }
            $iv = ('{0}%+{1}' -f `
                    ([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$start)), `
                    ([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',($WindowSec + 5))))

            $pa = @('-v','error','-read_intervals',$iv,'-show_packets',
                    '-show_entries','packet=stream_index,pts_time','-of','csv=p=0',$FilePath)
            $lines = @(& $sync.Ffprobe @pa 2>$null)

            $max = [double]::NaN
            foreach ($l in $lines) {
                $parts = ([string]$l).Split(',')
                if ($parts.Count -lt 2) { continue }
                $ix = 0
                if (-not [int]::TryParse($parts[0].Trim(), [ref]$ix)) { continue }
                if ($ix -ne $ai) { continue }
                $t = 0.0
                if (-not [double]::TryParse($parts[1], [Globalization.NumberStyles]::Float,
                                            [Globalization.CultureInfo]::InvariantCulture, [ref]$t)) { continue }
                if ([double]::IsNaN($max) -or $t -gt $max) { $max = $t }
            }

            $res.Checked = $true

            if ([double]::IsNaN($max)) {
                # geen enkel audiopakket in de staart: het stopt eerder dan
                # het venster, hoeveel eerder weten we zo niet
                $res.Ok       = $false
                $res.EndSec   = -1
                $res.ShortSec = $WindowSec
                $res.Note     = ('geen geluid in de laatste {0:N0} seconden' -f $WindowSec)
                return $res
            }

            $res.EndSec   = $max
            $res.ShortSec = $dur - $max
            if ($res.ShortSec -gt $ToleranceSec) {
                $res.Ok   = $false
                $res.Note = ('geluid tot {0:N1} s van {1:N1} s ({2:N1} s tekort)' -f $max, $dur, $res.ShortSec)
            }
            return $res
        }
        catch {
            $res.Note = ('controle mislukt: ' + $_.Exception.Message)
            return $res
        }
    }

    # -----------------------------------------------------------------
    #  Waarschuwingen van ffmpeg
    #
    #  ffmpeg loopt nu op '-loglevel warning' in plaats van 'error'. Juist
    #  de waarschuwingen zijn hier interessant: 'Non-monotonous DTS' en
    #  'Delay between the first packet and last packet in the muxing
    #  queue' zijn precies de meldingen die horen bij geluid dat later in
    #  het bestand wegvalt. Die werden eerder weggegooid.
    # -----------------------------------------------------------------
    function Write-FfmpegWarnings {
        param([string]$Text)

        if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }

        $lines = @($Text -split "`r?`n" |
                   Where-Object { $_.Trim().Length -gt 0 } |
                   Where-Object { $_ -notmatch '^\s*(x265|x264|\[libx26)' } |
                   Where-Object { $_ -notmatch '^\s*(encoded|frame [IPB]:|consecutive)' })

        if ($lines.Count -lt 1) { return 0 }

        $shown = 0
        foreach ($l in $lines) {
            if ($shown -ge 8) { break }
            W ('ffmpeg: ' + $l.Trim()) 'WAARS'
            $shown++
        }
        if ($lines.Count -gt $shown) {
            W ('... en nog {0} regel(s) van ffmpeg (niet getoond).' -f ($lines.Count - $shown)) 'WAARS'
        }

        if ($Text -match '(?i)(non-monoton|muxing queue|invalid.*timestamp|timestamp.*invalid|Application provided invalid)') {
            W 'LET OP: ffmpeg meldt iets over tijdstempels. Dat is de klassieke oorzaak van geluid dat verderop in het bestand wegvalt. Staat "Geluid" nog op kopieren, zet het dan op opnieuw encoderen.' 'WAARS'
        }

        return $lines.Count
    }

    # -----------------------------------------------------------------
    #  Bron eerst lokaal zetten
    #
    #  Waarom: ffmpeg leest een bestand niet in één ruk maar blijft er de
    #  hele encode lang uit lezen. Staat de bron op een share, dan levert
    #  dat een half uur lang netwerkverkeer en schijfactiviteit op de
    #  andere machine op. Eén keer in zijn geheel overhalen is voor beide
    #  kanten rustiger, en de encode leest daarna van een lokale schijf.
    #
    #  Het kopieren van het VOLGENDE bestand loopt mee terwijl het huidige
    #  wordt geencodeerd; er staat dus hooguit één bestand vooruit klaar,
    #  niet de hele wachtrij. Daarvoor is robocopy handig: die draait als
    #  eigen proces, dus de lus blijft ondertussen gewoon lopen.
    #
    #  Opruimen is hier belangrijker dan snelheid. Een achtergebleven kopie
    #  van een paar GB is erger dan een kopie die opnieuw moet, dus elke
    #  uitgang - geslaagd, mislukt, afgebroken, afsluiten - ruimt op.
    # -----------------------------------------------------------------
    function Test-NetworkPath {
        param([string]$Path)

        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        if ($Path.StartsWith('\\')) { return $true }      # UNC

        # Toegewezen netwerkschijf (letter die naar een share wijst)
        try {
            $root = [IO.Path]::GetPathRoot($Path)
            if ([string]::IsNullOrWhiteSpace($root)) { return $false }
            $d = New-Object System.IO.DriveInfo $root
            return ($d.DriveType -eq [System.IO.DriveType]::Network)
        }
        catch { return $false }
    }

    function Start-Prefetch {
        param($Job)

        if ($Job -eq $null) { return $null }
        if (-not $st.PrefetchToWorkDir) { return $null }
        if ($st.PrefetchOnlyNetwork -and -not (Test-NetworkPath $Job.FullPath)) { return $null }

        $bron = [string]$Job.FullPath
        $naam = [IO.Path]::GetFileName($bron)
        if ([string]::IsNullOrWhiteSpace($naam)) { return $null }

        # Vooruit halen heeft geen zin als een andere pc dit bestand al
        # onder handen heeft: straks bij het oppakken lukt het lock toch
        # niet en dan is er voor niets een paar GB over het netwerk
        # getrokken. Alleen kijken, niets claimen - het claimen gebeurt in
        # de hoofdlus.
        if ($script:LockAan -and -not (Test-LockFree -SourcePath $bron -StaleMinutes $script:LockStale)) {
            return $null
        }

        # Past het? Er komt straks ook een encode-uitvoer in dezelfde map,
        # dus vragen om het dubbele plus wat lucht.
        try {
            $nodig = [double]$Job.SizeBytes * 2 + 2GB
            $vrij  = -1
            try {
                $di = New-Object System.IO.DriveInfo ([IO.Path]::GetPathRoot($st.WorkDir))
                if ($di.IsReady) { $vrij = [double]$di.AvailableFreeSpace }
            } catch { }
            if ($vrij -ge 0 -and $vrij -lt $nodig) {
                W ("Te weinig ruimte in de werkmap om {0} eerst lokaal te zetten; er wordt rechtstreeks gelezen." -f $naam) 'WAARS'
                return $null
            }
        }
        catch { }

        $dir = Join-Path $st.WorkDir ("x265_pre_" + [guid]::NewGuid().ToString('N'))
        try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        catch { W ("Kon geen map voor de lokale kopie maken: {0}" -f $_.Exception.Message) 'WAARS'; return $null }

        $doel = Join-Path $dir $naam

        # CopyToAsync doet het kopieerwerk op de threadpool, dus de lus
        # hieronder blijft gewoon draaien en de encode van het vorige
        # bestand loopt ondertussen door. Geen apart proces nodig, en de
        # positie van de doelstream geeft meteen de voortgang.
        $res = [pscustomobject]@{
            Job = $Job; Task = $null; In = $null; Out = $null
            Dir = $dir; Target = $doel; Bytes = [long]$Job.SizeBytes
        }

        try {
            # Delete MOET erbij. Zonder dat kan de ANDERE pc het origineel
            # niet weggooien zolang wij het aan het kopieren zijn - en dan
            # blijft daar 'x265 aangemaakt, origineel NIET verwijderd'
            # staan, blijft de bron liggen, en pakt de volgende ronde hem
            # gewoon opnieuw op. Met Delete erbij wacht Windows netjes tot
            # onze kopie klaar is en gooit het bestand dan alsnog weg.
            $res.In  = [System.IO.File]::Open($bron, [System.IO.FileMode]::Open,
                                              [System.IO.FileAccess]::Read,
                                              ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            $res.Out = [System.IO.File]::Create($doel)
            $res.Task = $res.In.CopyToAsync($res.Out, 1048576)
        }
        catch {
            try { if ($res.Out) { $res.Out.Dispose() } } catch { }
            try { if ($res.In)  { $res.In.Dispose() } }  catch { }
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            W ("Lokale kopie kon niet worden gestart: {0}" -f $_.Exception.Message) 'WAARS'
            return $null
        }

        W ("Lokale kopie gestart: {0}" -f $naam)
        return $res
    }

    function Stop-Prefetch {
        param($Pre)

        if ($Pre -eq $null) { return }

        # De streams sluiten breekt een lopende kopie af.
        try { if ($Pre.Out) { $Pre.Out.Dispose() } } catch { }
        try { if ($Pre.In)  { $Pre.In.Dispose() } }  catch { }
        $Pre.Out = $null
        $Pre.In  = $null

        if ($Pre.Dir) { Remove-Item -LiteralPath $Pre.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Wacht tot de kopie klaar is. Geeft het lokale pad terug, of een lege
    # string als het niet gelukt is - dan wordt er van de bron gelezen,
    # want dat werkte altijd al.
    function Complete-Prefetch {
        param($Pre)

        if ($Pre -eq $null) { return '' }
        if ($Pre.Task -eq $null) { Stop-Prefetch $Pre; return '' }

        while (-not $Pre.Task.IsCompleted) {
            if ($sync.Cancel) { Stop-Prefetch $Pre; return '' }
            $sync.CurPhase = 'Bron lokaal zetten'
            if ($Pre.Bytes -gt 0) {
                try {
                    $p = 100.0 * [double]$Pre.Out.Position / [double]$Pre.Bytes
                    if ($p -gt 100) { $p = 100 }
                    $sync.CurPhasePct = $p
                } catch { }
            }
            Update-Timers
            Start-Sleep -Milliseconds 250
        }

        $fout = ''
        if ($Pre.Task.IsFaulted) {
            $fout = 'onbekende fout'
            try { $fout = $Pre.Task.Exception.GetBaseException().Message } catch { }
        }
        elseif ($Pre.Task.IsCanceled) { $fout = 'afgebroken' }

        # eerst netjes afsluiten, anders staat niet alles op schijf
        try { if ($Pre.Out) { $Pre.Out.Flush(); $Pre.Out.Dispose(); $Pre.Out = $null } } catch { }
        try { if ($Pre.In)  { $Pre.In.Dispose();  $Pre.In  = $null } } catch { }

        if ($fout) {
            W ("Lokale kopie mislukt ({0}); er wordt rechtstreeks van de bron gelezen." -f $fout) 'WAARS'
            Stop-Prefetch $Pre
            return ''
        }

        if (-not (Test-Path -LiteralPath $Pre.Target)) {
            W 'Lokale kopie is er niet; er wordt rechtstreeks van de bron gelezen.' 'WAARS'
            Stop-Prefetch $Pre
            return ''
        }

        # Even groot als de bron? Zo niet, dan is de kopie niet te
        # vertrouwen en is rechtstreeks lezen beter dan een half bestand
        # encoderen.
        try {
            $kopLen = (Get-Item -LiteralPath $Pre.Target).Length
            if ($Pre.Bytes -gt 0 -and $kopLen -ne $Pre.Bytes) {
                W ("Lokale kopie is {0} bytes en de bron {1}; kopie verworpen." -f $kopLen, $Pre.Bytes) 'WAARS'
                Stop-Prefetch $Pre
                return ''
            }
        }
        catch { }

        $sync.CurPhasePct = 0
        return [string]$Pre.Target
    }

    # -----------------------------------------------------------------
    #  De wachtrij: altijd de bovenste pakken
    #
    #  Er is met opzet GEEN index. De bovenste regel wordt onder een lock
    #  van de lijst gehaald; daardoor kan de GUI de rest van de rij vrij
    #  herschikken, aanvullen of inkorten zonder dat er iets kan worden
    #  overgeslagen of dubbel gedaan. Het bestand dat onder handen is zit
    #  niet meer in de lijst maar in $sync.CurrentJob.
    # -----------------------------------------------------------------
    # Kijken wat er bovenaan ligt zonder het eraf te halen. Nodig om
    # alvast het volgende bestand te kunnen ophalen terwijl het huidige
    # nog draait. Dat de gebruiker daarna de rij nog kan omgooien is geen
    # probleem: bij het oppakken wordt gecontroleerd of de kopie ook echt
    # bij dat bestand hoort.
    function Peek-NextJob {
        $top = $null
        $q = $sync.Queue
        [System.Threading.Monitor]::Enter($q.SyncRoot)
        try { if ($q.Count -gt 0) { $top = $q[0] } }
        finally { [System.Threading.Monitor]::Exit($q.SyncRoot) }
        return $top
    }

    function Get-NextJob {
        $taken = $null
        $q = $sync.Queue
        [System.Threading.Monitor]::Enter($q.SyncRoot)
        try {
            if ($q.Count -gt 0) {
                $taken = $q[0]
                $q.RemoveAt(0)
            }
        }
        finally { [System.Threading.Monitor]::Exit($q.SyncRoot) }
        return $taken
    }

    # -----------------------------------------------------------------
    #  Ondertitels meenemen naar de nieuwe naam
    #
    #  Alleen bestanden waarvan de naam begint met exact de naam van de
    #  bronvideo EN waarvan de rest met een punt begint, horen erbij.
    #  Daardoor gaat 'Film x264.nl.srt' wel mee en 'Film x264b.srt' niet.
    #  Het tussenstuk ('.nl', '.en.forced') blijft staan; alleen het
    #  naamdeel wordt vervangen.
    # -----------------------------------------------------------------
    function Move-Subtitles {
        param(
            [string]$SourcePath,
            [string]$OutputPath,
            [bool]  $MoveThem
        )

        $done = 0
        $skipped = 0

        try {
            $dir     = [IO.Path]::GetDirectoryName($SourcePath)
            $srcName = [IO.Path]::GetFileName($SourcePath)
            $srcBase = [IO.Path]::GetFileNameWithoutExtension($SourcePath)
            $outBase = [IO.Path]::GetFileNameWithoutExtension($OutputPath)

            if ([string]::IsNullOrEmpty($srcBase) -or [string]::IsNullOrEmpty($outBase)) {
                return @{ Done = 0; Skipped = 0 }
            }

            $exts = @{}
            foreach ($e in @($st.SubExtensions)) {
                $x = ([string]$e).Trim().TrimStart('.').ToLower()
                if ($x) { $exts['.' + $x] = $true }
            }
            if ($exts.Count -eq 0) { return @{ Done = 0; Skipped = 0 } }

            $all = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)

            foreach ($c in $all) {

                if ($c.Name -eq $srcName) { continue }
                if ($c.Name.Length -le $srcBase.Length) { continue }
                if (-not $c.Name.Substring(0, $srcBase.Length).Equals($srcBase, [StringComparison]::OrdinalIgnoreCase)) { continue }
                if (-not $exts.ContainsKey($c.Extension.ToLower())) { continue }

                $suffix = $c.Name.Substring($srcBase.Length)
                if (-not $suffix.StartsWith('.')) { continue }

                $target = Join-Path $dir ($outBase + $suffix)
                if ($target -eq $c.FullName) { continue }

                if (Test-Path -LiteralPath $target) {
                    W ("Ondertitel overgeslagen, doelnaam bestaat al: {0}" -f ([IO.Path]::GetFileName($target))) 'WAARS'
                    $skipped = $skipped + 1
                    continue
                }

                try {
                    if ($MoveThem) {
                        Move-Item -LiteralPath $c.FullName -Destination $target -ErrorAction Stop
                        W ("Ondertitel omgenoemd : {0} -> {1}" -f $c.Name, ([IO.Path]::GetFileName($target)))
                    } else {
                        Copy-Item -LiteralPath $c.FullName -Destination $target -ErrorAction Stop
                        W ("Ondertitel gekopieerd: {0} -> {1}" -f $c.Name, ([IO.Path]::GetFileName($target)))
                    }
                    $done = $done + 1
                }
                catch {
                    W ("Ondertitel {0} mislukte: {1}" -f $c.Name, $_.Exception.Message) 'WAARS'
                    $skipped = $skipped + 1
                }
            }
        }
        catch {
            # Ondertitels mogen de conversie nooit laten mislukken en
            # nooit meetellen in de noodstop-teller.
            W ("Ondertitels overslaan wegens fout: {0}" -f $_.Exception.Message) 'WAARS'
        }

        return @{ Done = $done; Skipped = $skipped }
    }

    # -----------------------------------------------------------------
    #  Cumulatieve totalen bijwerken (de GUI schrijft ze weg)
    # -----------------------------------------------------------------
    function Add-Totals {
        param([long]$OrigBytes, [long]$NewBytes, [double]$EncodeSec, [double]$VideoSec)
        try {
            $t = $sync.Totals
            [System.Threading.Monitor]::Enter($t.SyncRoot)
            try {
                $t.Files     = [int]$t.Files + 1
                $t.OrigBytes = [long]$t.OrigBytes + $OrigBytes
                $t.NewBytes  = [long]$t.NewBytes  + $NewBytes
                $t.ActiveSec = [double]$t.ActiveSec + $EncodeSec
                $t.VideoSec  = [double]$t.VideoSec  + $VideoSec
                $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                if ([string]::IsNullOrEmpty([string]$t.FirstUsed)) { $t.FirstUsed = $stamp }
                $t.LastUsed = $stamp
            }
            finally { [System.Threading.Monitor]::Exit($t.SyncRoot) }
            $sync.TotalsDirty = $true
        }
        catch { }
    }

    # -----------------------------------------------------------------
    #  Noodstop-teller
    #
    #  Alles wat geen volledig succes is telt mee; alleen een geslaagde
    #  conversie zet de teller op nul.
    # -----------------------------------------------------------------
    function Register-Outcome {
        param([bool]$Ok, [string]$FileName, [string]$Reason, [bool]$CountsForStreak = $true)

        if ($Ok) {
            $sync.FailStreak = 0
            return $false
        }

        # Niet elke niet-geslaagde uitkomst hoort de run te stoppen. Een
        # VCP-bestand telt niet mee: dat is hernoemd en komt bij een volgende
        # ronde niet meer langs, dus er kan geen herhaling ontstaan. De run
        # afbreken zou alleen maar rekentijd kosten - en die is schaars op een
        # pc die niet continu kan draaien.
        if (-not $CountsForStreak) { return $false }

        $sync.FailStreak = [int]$sync.FailStreak + 1
        $sync.EmergencyFiles.Enqueue(("{0}  ->  {1}" -f $FileName, $Reason))

        W ("Fout {0} van {1} op rij." -f $sync.FailStreak, $st.MaxFailStreak) 'WAARS'

        if ([int]$sync.FailStreak -ge [int]$st.MaxFailStreak) {
            $sync.EmergencyStop = $true
            return $true
        }
        return $false
    }

    # =================================================================
    #  hoofdlus
    # =================================================================
    try {
        W '============================================================'
        W ("Conversie gestart met {0}" -f $st.AppStamp)
        W ("{0} in de wachtrij - encoder {1}, preset {2}, CRF/kwaliteit {3}" -f `
            $sync.Queue.Count, $st.Codec, $st.Preset, $st.Crf)
        W ("Geluid: {0}" -f (
            $(if (([string]$st.AudioMode) -eq 'copy') { 'kopieren (tijdstempels van het origineel)' }
              else { ([string]$st.AudioMode) + ' opnieuw encoderen, tijdstempels worden hersteld' })))
        W ("Werkmap: {0}" -f $st.WorkDir)
        W '============================================================'

        # $pre       : kopie die vooruit wordt gehaald voor het VOLGENDE bestand
        # $preHuidig : kopie die bij het bestand hoort dat nu wordt verwerkt
        $pre       = $null
        $preHuidig = $null

        # $lock         : het lock van het bestand dat nu onder handen is
        # $busySkips    : hoeveel bestanden onderweg bij een andere pc
        #                 in gebruik waren (voor het eindrapport)
        # $busyOpnieuw  : paden die al meteen achteraan de wachtrij zijn
        #                 gezet; daarna niet nog een keer, anders kan een
        #                 bestand dat de hele ronde bezet blijft de boel
        #                 voor onbepaalde tijd ophouden
        $lock        = $null
        $busySkips   = 0
        $busyOpnieuw = New-Object System.Collections.Generic.HashSet[string]
        $script:HuidigLock = $null

        $lockAan   = $true
        if ($st.ContainsKey('SharedLocks')) { $lockAan = [bool]$st.SharedLocks }
        $lockStale = 15.0
        if ($st.ContainsKey('LockStaleMinutes') -and $st.LockStaleMinutes) { $lockStale = [double]$st.LockStaleMinutes }
        $script:LockAan   = $lockAan
        $script:LockStale = $lockStale
        if ($lockAan) { W ("Gedeelde map: er wordt per bestand een lock geplaatst (verweesd na {0:N0} min)." -f $lockStale) }

        # Niet resetten als er al een lock is gezien tijdens de scan: die
        # waarneming telt net zo goed mee voor de ronde hierna.
        if (-not $lockAan) { $sync.LockGezien = $false }

        while ($true) {

            Update-Timers

            if ($sync.Cancel)           { break }
            if ($sync.StopAfterCurrent) { break }

            Wait-WhilePaused $null
            if ($sync.Cancel) { break }

            # Stop na huidige kan tijdens de pauze zijn aangevraagd, en
            # kan er ook weer af zijn gehaald; opnieuw kijken.
            if ($sync.StopAfterCurrent) { break }

            $job = Get-NextJob

            if ($job -eq $null) {
                break                            # wachtrij leeg: klaar
            }

            # ---- staat de bron er nog? ------------------------------
            #  Bij twee pc's op dezelfde map is de lijst een momentopname.
            #  De ander kan dit bestand inmiddels hebben omgezet, waarna
            #  het origineel is verdwenen.
            $bronErNog = $false
            try { $bronErNog = [System.IO.File]::Exists([string]$job.FullPath) } catch { }
            if (-not $bronErNog) {
                $job.Status     = 'Niet gevonden'
                $job.ResultText = 'De bron is er niet meer; mogelijk door een andere pc gedaan.'
                $job.Queued     = $false
                $job.QueueText  = ''
                W ("Overgeslagen, bron bestaat niet meer: {0}" -f $job.FullPath) 'WAARS'
                continue
            }

            # ---- is dit bestand al omgezet? -------------------------
            $alKlaar = Test-AlOmgezet -SourcePath ([string]$job.FullPath) -FixedOut ([string]$job.OutPath)
            if ($alKlaar) {
                $job.Status     = 'Al omgezet'
                $job.ResultText = 'Er staat al een HEVC-uitvoer naast de bron: ' + [IO.Path]::GetFileName($alKlaar)
                $job.Queued     = $false
                $job.QueueText  = ''
                W ("Overgeslagen, er staat al een omgezet bestand naast de bron: {0}" -f $alKlaar) 'WAARS'
                W 'Het origineel is blijkbaar niet opgeruimd na een eerdere omzetting. Verwijder het zelf, of hernoem de uitvoer als je het toch opnieuw wilt doen.' 'WAARS'
                continue
            }

            # ---- is een andere pc er al mee bezig? ------------------
            $lock = $null
            if ($lockAan) {
                $poging = Take-Lock -SourcePath ([string]$job.FullPath) `
                                    -StaleMinutes $lockStale -Stamp ([string]$st.AppStamp)
                if ($poging.Ok) {
                    $lock = $poging.Lock
                    # Ook in de scriptscope: de hartslag wordt geklopt vanuit
                    # de poll-lussen van encoderen, remuxen, opvullen en
                    # kopieren, en die zitten in aparte functies.
                    $script:HuidigLock = $lock
                }
                elseif ($poging.Busy) {
                    $sync.LockGezien = $true
                    # Hadden we dit bestand al vooruit staan halen, dan die
                    # kopie nu meteen afbreken. Niet alleen om de ruimte:
                    # zolang wij de bron open hebben staan, komt de andere
                    # pc er straks niet bij om hem weg te gooien.
                    if ($pre -ne $null -and $pre.Job -eq $job) {
                        Stop-Prefetch $pre
                        $pre = $null
                    }
                    $job.Status     = 'Andere pc bezig'
                    $job.ResultText = $(if ($poging.Owner) { "In gebruik door $($poging.Owner)" } else { 'In gebruik door een andere pc' })
                    $busySkips++

                    # Meteen achteraan de wachtrij, niet pas als de hele rij
                    # klaar is: als de andere pc net stopt of het net een
                    # hapering was, krijgt dit bestand zo een nieuwe kans
                    # zonder op de rest te hoeven wachten (voor eventueel
                    # foutherstel), en ondertussen kan de rest van de rij
                    # gewoon doorlopen. Per bestand hoogstens een keer
                    # opnieuw in deze ronde - anders houdt een bestand dat de
                    # hele ronde bezet blijft de boel voor onbepaalde tijd op.
                    $pad = [string]$job.FullPath
                    if ($busyOpnieuw.Contains($pad)) {
                        $job.Queued    = $false
                        $job.QueueText = ''
                        W ("Overgeslagen, {0}: {1}" -f $job.ResultText.ToLower(), $job.Name)
                        continue
                    }
                    [void]$busyOpnieuw.Add($pad)
                    W ("Overgeslagen, {0}: {1} - meteen achteraan de wachtrij gezet." -f $job.ResultText.ToLower(), $job.Name)
                    $job.Queued    = $true
                    $job.QueueText = ''
                    $q = $sync.Queue
                    [System.Threading.Monitor]::Enter($q.SyncRoot)
                    try { [void]$q.Add($job) }
                    finally { [System.Threading.Monitor]::Exit($q.SyncRoot) }
                    continue
                }
                else {
                    # Lock kon niet worden aangemaakt - map alleen-lezen of
                    # iets dergelijks. Niet blijven hangen: doorgaan zonder
                    # lock is beter dan niets doen, en als de map echt niet
                    # beschrijfbaar is loopt de conversie zo dadelijk toch
                    # vast en pakt de noodstop het op.
                    W ("Er kon geen lock worden geplaatst naast {0}; er wordt zonder lock doorgewerkt." -f $job.Name) 'WAARS'
                }
            }

            $sync.CurrentJob = $job
            $preHuidig       = $null

            # ---- voorbereiden ---------------------------------------
            $activeBefore        = $swActive.Elapsed.TotalSeconds
            $sync.CurFile        = $job.Name
            $sync.CurDurationSec = $job.DurationSec
            $sync.CurVideoSec    = 0
            $sync.CurPhase       = 'Encoderen'
            $sync.CurPhasePct    = 0
            $sync.CurSpeed       = ''
            $sync.CurFps         = ''
            $sync.CurTempSize    = 0
            $job.QueueText       = ''
            $job.Status          = 'Encoderen'
            $job.ResultText      = ''

            W ''
            W ("[{0}] {1}   (nog {2} in de wachtrij)" -f ($sync.JobsDone + 1), $job.FullPath, $sync.Queue.Count)

            # ---- bron lokaal: klaarstaande kopie of nu ophalen -------
            $readPath = [string]$job.FullPath

            if ($pre -ne $null) {
                if ($pre.Job -eq $job) {
                    $klaar = Complete-Prefetch $pre
                    if ($klaar) {
                        $readPath = $klaar
                        $preHuidig = $pre
                        W ("Bron staat lokaal klaar: {0}" -f $readPath)
                    }
                    else { Stop-Prefetch $pre }
                    $pre = $null
                }
                else {
                    # de wachtrij is omgegooid: deze kopie hoort bij een
                    # ander bestand en kan weg
                    W 'De wachtrij is gewijzigd; de vooruit gehaalde kopie hoort niet bij dit bestand en wordt opgeruimd.' 'WAARS'
                    Stop-Prefetch $pre
                    $pre = $null
                }
            }

            if ($preHuidig -eq $null) {
                $eigen = Start-Prefetch $job
                if ($eigen -ne $null) {
                    $klaar = Complete-Prefetch $eigen
                    if ($klaar) { $readPath = $klaar; $preHuidig = $eigen }
                    else { Stop-Prefetch $eigen }
                }
            }

            if ($sync.Cancel) {
                Stop-Prefetch $preHuidig
                $preHuidig = $null
                Release-Lock $lock
                $lock = $null
                $script:HuidigLock = $null
                $job.Status = 'Afgebroken'
                $job.Queued = $false
                $sync.CurrentJob = $null
                break
            }

            # ---- alvast het volgende ophalen -------------------------
            #  Dit loopt mee met de encode hieronder, dus er staat hooguit
            #  een bestand vooruit klaar.
            if ($pre -eq $null -and -not $sync.StopAfterCurrent) {
                $volgende = Peek-NextJob
                if ($volgende -ne $null) { $pre = Start-Prefetch $volgende }
            }

            # ---- duur alsnog bepalen als die onbekend is -------------
            #
            #  Zonder totale speelduur is er geen percentage te berekenen
            #  en blijft de voortgangsbalk dood op nul staan, terwijl er
            #  wel degelijk wordt gewerkt. De scan kan hem missen: niet
            #  elke container heeft de duur in de kop, en over een trage
            #  share geeft ffprobe soms op. Hier is het een tweede kans
            #  waard - en als de bron inmiddels lokaal staat is het zelfs
            #  gratis, want dan hoeft er niets meer over het netwerk.
            if ([double]$job.DurationSec -le 0) {
                $alsnog = Get-DurationSec $readPath
                if ($alsnog -gt 0) {
                    $job.DurationSec     = $alsnog
                    $job.DurationText    = Format-Clock $alsnog
                    $sync.CurDurationSec = $alsnog
                    W ("Speelduur was onbekend; alsnog bepaald op {0}." -f (Format-Clock $alsnog))
                }
                else {
                    W 'De speelduur van dit bestand is niet te bepalen; de voortgangsbalk kan geen percentage tonen.' 'WAARS'
                }
            }

            $origLastWrite = $null
            try { $origLastWrite = (Get-Item -LiteralPath $readPath).LastWriteTime } catch { }

            $guid = [guid]::NewGuid().ToString('N')
            $temp = Join-Path $st.WorkDir ("x265_$guid.tmp.mkv")
            $prog = Join-Path $st.WorkDir ("x265_$guid.progress.txt")

            # Kanaalaantal bepaalt de audiobitrate en of er moet worden
            # gedownmixt. Alleen opvragen als er ook echt geencodeerd
            # wordt; bij kopieren doet het niet mee.
            $audioCh = 2
            if (([string]$st.AudioMode) -ne 'copy') {
                $audioCh = Get-AudioChannels $readPath
                W ("Geluid: {0}, bron heeft {1} kanaal(en)." -f ([string]$st.AudioMode), $audioCh)
            }

            # ---- ijkpunt: hoe zit het geluid in de BRON? ----
            #
            #  Zonder dit heeft de nacontrole geen referentie. Een tekort
            #  van een paar seconden aan het eind is doodnormaal: in een
            #  steekproef van 136 gewone bestanden had 18% er een, tot 4,9
            #  seconden toe. Pas als de UITVOER het duidelijk slechter doet
            #  dan de bron is er iets misgegaan bij het omzetten.
            $srcShort = 0.0
            $srcKnown = $false
            if ($st.CheckAudioTail) {
                $sync.CurPhase = 'Bron nakijken'
                $sTail = Test-AudioTail -FilePath $readPath -ToleranceSec ([double]$st.AudioTailTolerance)
                if ($sTail.Checked) {
                    $srcShort = [double]$sTail.ShortSec
                    $srcKnown = $true
                    if ($srcShort -gt $st.AudioTailTolerance) {
                        W ("Let op de bron: het geluid houdt daar al {0:N1} s voor het einde op." -f $srcShort)
                    }
                }
            }

            # sporen uitzoeken: wat kan er mee naar mkv, en hoe
            $plan = Get-StreamPlan $readPath
            if ($plan.Ok) {
                foreach ($n in $plan.Notes) { W ("Sporen: {0}" -f $n) 'WAARS' }
            }
            else {
                W 'Sporen konden niet worden uitgelezen; alles behalve datastromen wordt meegenomen.' 'WAARS'
            }

            $variants = @('full')
            if ($st.SmartRetry) { $variants += 'safe' }

            $encodeOk = $false
            $lastErr  = ''

            foreach ($variant in $variants) {

                if ($sync.Cancel) { break }

                # De fase moet hier terug op 'Encoderen'. De controles voor en
                # na de encode zetten hem op iets anders, en zonder deze regel
                # bleef 'Bron nakijken' de hele encode in de voortgangsbalk
                # staan.
                $sync.CurPhase    = 'Encoderen'
                $sync.CurPhasePct = 0
                $job.Status       = 'Encoderen'

                if ($variant -eq 'safe') {
                    W 'Eerste poging mislukt - herpoging met alleen beeld en geluid, zonder ondertitels en bijlagen.' 'WAARS'
                    $job.Status       = 'Herpoging'
                    $sync.CurVideoSec = 0
                    $sync.CurPhasePct = 0
                }

                $res = Invoke-Encode -SourcePath $readPath -TempPath $temp `
                                     -ProgressPath $prog `
                                     -EncodeArgs (Get-EncodeArgs -Variant $variant -Channels $audioCh -Plan $plan)

                $tempOk = $false
                if (Test-Path -LiteralPath $temp) {
                    try { $tempOk = ((Get-Item -LiteralPath $temp).Length -gt 0) } catch { }
                }

                if ($res.Code -eq 0 -and $tempOk) {
                    [void](Write-FfmpegWarnings $res.Err)
                    $encodeOk = $true
                    break
                }

                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue

                if ($sync.Cancel) { break }

                # foutmelding uitfilteren: x265 en libx265 schrijven ook
                # gewone informatie naar stderr
                $lastErr = ''
                if ($res.Err) {
                    $lines = @($res.Err -split "`r?`n" |
                               Where-Object { $_.Trim().Length -gt 0 } |
                               Where-Object { $_ -notmatch '^\s*(x265|x264|\[libx26)' } |
                               Where-Object { $_ -notmatch '^\s*(encoded|frame [IPB]:|consecutive)' })
                    if ($lines.Count -gt 0) { $lastErr = $lines[-1].Trim() }
                }
                if (-not $lastErr) { $lastErr = "ffmpeg exitcode $($res.Code)" }

                W "ffmpeg fout: $lastErr" 'FOUT'

                # bij een duidelijk invoerprobleem heeft een herpoging geen zin
                # Let op: 'Invalid argument' stond hier ook in, en dat was fout.
                # Die tekst komt namelijk ook voorbij bij "Could not write
                # header (incorrect codec parameters ?): Invalid argument" -
                # een probleem met de UITVOER, niet met de invoer. Daardoor
                # werd juist de herpoging overgeslagen die het bestand had
                # kunnen redden. Alleen meldingen die echt over het
                # invoerbestand gaan horen hier thuis.
                if ($lastErr -match '(?i)(Error opening input|Invalid data found|No such file|Permission denied|moov atom not found|End of file)') {
                    W 'Invoerbestand zelf is het probleem - geen herpoging.' 'WAARS'
                    break
                }
            }

            Remove-Item -LiteralPath $prog -Force -ErrorAction SilentlyContinue

            # ---- afgebroken -----------------------------------------
            if ($sync.Cancel) {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath (Join-Path $st.WorkDir ("x265_$guid.mux.mkv")) -Force -ErrorAction SilentlyContinue
                $job.Status      = 'Afgebroken'
                $job.ResultText  = 'Gestopt door gebruiker'
                $job.Queued      = $false
                $sync.CurrentJob = $null
                W 'Conversie afgebroken; tijdelijk bestand opgeruimd.' 'WAARS'
                break
            }

            $jobDone   = $false      # verwerkt (geslaagd of definitief mislukt)
            $jobOk     = $false      # volledig geslaagd
            $jobReason = ''

            # Per bestand terugzetten. Zonder dit houdt $vcp de waarde van het
            # VORIGE bestand vast als de encode nu mislukt, en dan zou die
            # mislukking ten onrechte niet meetellen voor de noodstop.
            $vcp       = $false
            $lockKwijt = $false

            # ---- mislukt --------------------------------------------
            if (-not $encodeOk) {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                $job.Status        = 'Mislukt'
                $job.ResultText    = $lastErr
                $sync.Failed       = $sync.Failed + 1
                $sync.DoneVideoSec = $sync.DoneVideoSec + $job.DurationSec
                $job.EncodeSec     = $swActive.Elapsed.TotalSeconds - $activeBefore
                $jobDone           = $true
                $jobReason         = $lastErr
                W 'MISLUKT - origineel blijft ongewijzigd.' 'FOUT'
            }
            else {
                # ---- interleaving nameten, en alleen remuxen als het nodig is ----
                #
                #  De encode zet zelf al '-max_interleave_delta 0', dus de
                #  container hoort meteen goed te zijn en een remux hoort
                #  overbodig te zijn. 'Hoort' is hier het sleutelwoord: dat
                #  is niet te bewijzen zonder de storing te kunnen namaken,
                #  en die liet zich alleen op de echte bestanden zien.
                #  Daarom: meten in plaats van aannemen. Klopt het, dan
                #  gebeurt er niets extra's. Klopt het niet, dan volgt de
                #  remux die aantoonbaar wel werkt.
                $doRemux = [bool]$st.FinalRemux
                $ilNote  = ''

                if (-not $doRemux -and $st.RemuxIfNeeded) {
                    $sync.CurPhase = 'Container nameten'
                    $il = Test-Interleave -FilePath $temp -DurationSec ([double]$job.DurationSec)
                    if (-not $il.Checked) {
                        if ($il.Note) { W ("Interleaving niet gemeten: {0}." -f $il.Note) }
                    }
                    elseif ($il.Ok) {
                        W ("Container in orde: geluid ligt op alle {0} meetpunten bij het beeld. Geen remux nodig." -f $il.Punten)
                    }
                    else {
                        $ilNote  = $il.Note
                        $doRemux = $true
                        W ("Container niet in orde: {0}. Er volgt een remux." -f $il.Note) 'WAARS'
                    }
                }

                if ($doRemux) {
                    $sync.CurPhase    = 'Container opbouwen'
                    $sync.CurPhasePct = 0
                    $job.Status       = 'Remuxen'
                    $temp2 = Join-Path $st.WorkDir ("x265_$guid.mux.mkv")
                    W 'Container opnieuw opbouwen zodat beeld, geluid en ondertitels netjes door elkaar staan...'

                    $rx = Invoke-Remux -InPath $temp -OutPath $temp2
                    if ($rx.Ok) {
                        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                        $temp = $temp2
                        W 'Remux gelukt.'

                        # nog een keer meten: een remux die het niet oplost is
                        # een reden om het bestand niet zomaar goed te keuren
                        if ($ilNote -ne '') {
                            $il2 = Test-Interleave -FilePath $temp -DurationSec ([double]$job.DurationSec)
                            if ($il2.Checked -and -not $il2.Ok) {
                                W ("LET OP: ook na de remux ligt het geluid niet overal bij het beeld ({0}). Bewaar dit bestand en meld het." -f $il2.Note) 'WAARS'
                            }
                            elseif ($il2.Checked) {
                                W 'Na de remux ligt het geluid op alle meetpunten bij het beeld.'
                            }
                        }
                    }
                    else {
                        Remove-Item -LiteralPath $temp2 -Force -ErrorAction SilentlyContinue
                        if (-not $sync.Cancel) {
                            # geen reden om het hele bestand weg te gooien: het
                            # encoderesultaat is goed, alleen de extra stap niet
                            W ("Remux mislukt, het bestand van de encode wordt gebruikt: {0}" -f $rx.Err) 'WAARS'
                        }
                    }
                }

                # ---- nacontrole: staat het geluid er nog zoals in de bron? ----
                #
                #  Vergeleken met de BRON, en de reactie staat in verhouding
                #  tot de omvang van het verlies. Dat laatste is een correctie
                #  op de eerste opzet: die keurde af zodra er meer dan een
                #  paar seconden weg was, en gooide daarmee een conversie van
                #  drie kwartier weg voor het staartje van de aftiteling. In
                #  de praktijk bleek 25% van de bestanden zo te sneuvelen, met
                #  verliezen van 2,2 tot 5,4 seconden - geen enkel geval van
                #  echt ontbrekende inhoud.
                #
                #    verlies tot AudioTailMargin      -> niets aan de hand
                #    tot AudioLossLimit               -> staart opvullen, houden
                #    daarboven                        -> VCP, bestand weg
                $vcp     = $false
                $vcpNote = ''
                $padded  = $false
                $lossTxt = ''

                if ($st.CheckAudioTail) {
                    $sync.CurPhase = 'Geluid nakijken'
                    $tail = Test-AudioTail -FilePath $temp -ToleranceSec ([double]$st.AudioTailTolerance)

                    if (-not $tail.Checked) {
                        if ($tail.Note) { W ("Geluidscontrole overgeslagen: {0}." -f $tail.Note) }
                    }
                    else {
                        $outShort = [double]$tail.ShortSec
                        $extra    = 0.0
                        if ($srcKnown) { $extra = $outShort - $srcShort }
                        $verlies  = ($srcKnown -and $extra -gt [double]$st.AudioTailMargin)

                        if ($verlies -and $extra -gt [double]$st.AudioLossLimit) {
                            $vcp     = $true
                            $vcpNote = ('geluid stopt {0:N1} s eerder dan in de bron (bron {1:N1} s, uitvoer {2:N1} s voor het einde)' -f `
                                            $extra, $srcShort, $outShort)
                            W ("GELUID VERLOREN: {0}." -f $vcpNote) 'FOUT'
                            W ("Dat is meer dan de grens van {0:N0} s, dus dit bestand wordt niet gebruikt." -f $st.AudioLossLimit) 'FOUT'
                        }
                        else {
                            if ($verlies) {
                                $lossTxt = ('{0:N1} s geluid verloren' -f $extra)
                                W ("Er is {0:N1} s geluid verloren aan het eind (bron {1:N1} s, uitvoer {2:N1} s voor het einde). Onder de grens van {3:N0} s, dus het bestand wordt gebruikt." -f `
                                        $extra, $srcShort, $outShort, $st.AudioLossLimit) 'WAARS'
                            }

                            if ($outShort -gt [double]$st.AudioTailTolerance) {
                                if ($st.PadShortAudio) {
                                    if (-not $verlies) {
                                        W ("Het geluid houdt {0:N1} s voor het einde op, net als in de bron. Staart wordt met stilte opgevuld." -f $outShort)
                                    }
                                    else {
                                        W 'Staart wordt met stilte opgevuld tot het einde van het beeld.'
                                    }
                                    $sync.CurPhase = 'Staart opvullen'
                                    $job.Status    = 'Geluid opvullen'
                                    $temp3 = Join-Path $st.WorkDir ("x265_$guid.pad.mkv")
                                    $pd = Invoke-PadAudio -InPath $temp -OutPath $temp3 `
                                                          -DurationSec ([double]$job.DurationSec) -Channels $audioCh
                                    if ($pd.Ok) {
                                        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                                        $temp   = $temp3
                                        $padded = $true
                                        W 'Staart opgevuld tot het einde van het beeld.'
                                    }
                                    else {
                                        Remove-Item -LiteralPath $temp3 -Force -ErrorAction SilentlyContinue
                                        if (-not $sync.Cancel) { W ("Opvullen mislukt, het bestand blijft zoals het was: {0}" -f $pd.Err) 'WAARS' }
                                    }
                                }
                                elseif (-not $verlies) {
                                    W ("Het geluid houdt {0:N1} s voor het einde op, net als in de bron. Niets aan te doen bij het omzetten." -f $outShort)
                                }
                            }
                        }

                        if (-not $verlies -and -not $vcp -and $outShort -le [double]$st.AudioTailTolerance) {
                            W ("Geluid loopt tot het einde (tekort {0:N1} s, bron {1:N1} s)." -f $outShort, $srcShort)
                        }
                    }
                }

                # ---- geluid verloren gegaan: VCP ------------------
                #
                #  De omzetting heeft geluid laten vallen dat in de bron wel
                #  zat. Het resultaat is dan niets waard, dus dat gaat weg.
                #  De bron blijft staan en krijgt VCP in de naam; de scanner
                #  slaat die over, zodat een volgende ronde over dezelfde map
                #  er geen uren meer in steekt. Dat is ook de reden dat dit
                #  NIET meetelt voor de noodstop: het bestand komt toch niet
                #  meer terug, en een run afbreken kost alleen maar tijd.
                if ($vcp) {
                    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue

                    $mark = Set-VcpName -FilePath $job.FullPath -Marker ([string]$st.VcpMarker)
                    if ($mark.Ok) {
                        if ($mark.Note) { W ("Bron: {0}." -f $mark.Note) }
                        else            { W ("Bron hernoemd naar: {0}" -f [IO.Path]::GetFileName($mark.Path)) }
                        $job.FullPath = $mark.Path
                        $job.Name     = [IO.Path]::GetFileName($mark.Path)
                    }
                    else {
                        W ("Bron kon niet worden hernoemd: {0}" -f $mark.Note) 'WAARS'
                    }

                    $job.Status        = 'VCP'
                    $job.ResultText    = $vcpNote
                    $sync.Warned       = $sync.Warned + 1
                    $sync.DoneVideoSec = $sync.DoneVideoSec + $job.DurationSec
                    $job.EncodeSec     = $swActive.Elapsed.TotalSeconds - $activeBefore
                    $jobDone           = $true
                    W 'Het omgezette bestand is weggegooid, het origineel blijft ongewijzigd staan.' 'WAARS'
                }
                elseif (-not (Test-LockOwned $lock)) {
                    # ---- het lock is onderweg afgepakt ------------------
                    #
                    #  Kan gebeuren als deze pc lang stil is geweest - in
                    #  slaapstand, of het netwerk was een kwartier weg. De
                    #  andere pc heeft het bestand dan overgenomen en is er
                    #  misschien al mee klaar. Ons resultaat gaat NIET over
                    #  dat van hem heen; dat zou twee halve bestanden of
                    #  een verdwenen origineel kunnen opleveren.
                    $lockKwijt = $true
                    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue

                    $eig = ''
                    try { $eig = [string](Read-LockInfo (Get-LockPath $job.FullPath)).Pc } catch { }

                    $job.Status     = 'Lock kwijt'
                    $job.ResultText = $(if ($eig) { "Overgenomen door $eig; resultaat weggegooid" }
                                        else      { 'Door een andere pc overgenomen; resultaat weggegooid' })
                    $sync.Warned       = $sync.Warned + 1
                    $sync.DoneVideoSec = $sync.DoneVideoSec + $job.DurationSec
                    $job.EncodeSec     = $swActive.Elapsed.TotalSeconds - $activeBefore
                    $jobDone           = $true
                    W ("Het lock op {0} is onderweg overgenomen door een andere pc." -f $job.Name) 'FOUT'
                    W 'Het omgezette bestand is weggegooid en het origineel blijft ongemoeid. Deze pc is waarschijnlijk een tijd stil geweest (slaapstand of netwerk weg).' 'FOUT'
                }
                else {
                    # ---- verplaatsen ------------------------------------
                    $newLen = [long]0
                    try { $newLen = (Get-Item -LiteralPath $temp).Length } catch { }

                    $outPath = New-OutputPath -SourcePath $job.FullPath -Fixed ([string]$job.OutPath)

                    $sync.CurPhase    = 'Verplaatsen'
                    $sync.CurPhasePct = 0
                    $job.Status       = 'Verplaatsen'
                    W ("Verplaatsen naar bronmap: {0}  ({1})" -f $outPath, (Format-Size $newLen))

                    $sync.LastMoveError = ''
                    $moved = Move-WithProgress $temp $outPath

                    if (-not $moved) {
                        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                        $job.Status        = 'Mislukt'
                        $job.ResultText    = 'Verplaatsen mislukt: ' + $sync.LastMoveError
                        $sync.Failed       = $sync.Failed + 1
                        $sync.DoneVideoSec = $sync.DoneVideoSec + $job.DurationSec
                        $job.EncodeSec     = $swActive.Elapsed.TotalSeconds - $activeBefore
                        $jobDone           = $true
                        $jobReason         = 'verplaatsen mislukt: ' + $sync.LastMoveError
                        W 'Eindbestand kon niet worden verplaatst - origineel blijft behouden.' 'FOUT'
                    }
                    else {
                        if ($st.KeepDate -and $origLastWrite -ne $null) {
                            try { (Get-Item -LiteralPath $outPath).LastWriteTime = $origLastWrite } catch { }
                        }

                        $job.NewBytes    = $newLen
                        $job.NewSizeText = Format-Size $newLen

                        # ---- origineel verwijderen ----------------------
                        #  De geluidscontrole speelt hier geen rol meer: die
                        #  beslist eerder, door de uitvoer met de BRON te
                        #  vergelijken. Was de uitvoer echt slechter, dan is dit
                        #  punt niet eens bereikt - dan is het een VCP-bestand
                        #  en is het resultaat al weggegooid.
                        $delOk = $true
                        if ($st.DeleteOriginal) {
                            $sync.CurPhase    = 'Origineel verwijderen'
                            $sync.CurPhasePct = 100
                            $job.Status       = 'Origineel wissen'
                            $delOk = Remove-WithRetry $job.FullPath $st.DeleteAttempts $st.DeleteWait
                        }

                        # ---- ondertitels meenemen ----------------------
                        #  Omnoemen alleen als het origineel echt weg is;
                        #  staat het er nog, dan kopiëren, zodat het origineel
                        #  zijn eigen ondertitels houdt.
                        if ($st.HandleSubs) {
                            $sync.CurPhase = 'Ondertitels'
                            # kopieren zodra het origineel blijft staan
                            $subMove = ($st.DeleteOriginal -and $delOk)
                            $subRes  = Move-Subtitles -SourcePath $job.FullPath -OutputPath $outPath -MoveThem $subMove
                            if ($subRes.Done -gt 0 -or $subRes.Skipped -gt 0) {
                                W ("Ondertitels: {0} verwerkt, {1} overgeslagen." -f $subRes.Done, $subRes.Skipped)
                            }
                        }

                        $saved = $job.SizeBytes - $newLen
                        $pct   = 0.0
                        if ($job.SizeBytes -gt 0) { $pct = 100.0 * $saved / $job.SizeBytes }

                        $sync.OrigBytes    = $sync.OrigBytes + $job.SizeBytes
                        $sync.NewBytes     = $sync.NewBytes  + $newLen
                        $sync.DoneVideoSec = $sync.DoneVideoSec + $job.DurationSec
                        $job.EncodeSec     = $swActive.Elapsed.TotalSeconds - $activeBefore
                        $jobDone           = $true

                        if ($delOk) {
                            $job.Status     = 'Geslaagd'
                            $job.ResultText = ('{0} kleiner ({1:N1} %)' -f (Format-Size $saved), $pct)
                            if ($lossTxt) { $job.ResultText = $job.ResultText + '  -  ' + $lossTxt }
                            elseif ($padded) { $job.ResultText = $job.ResultText + '  -  staart opgevuld' }
                            $sync.Success   = $sync.Success + 1
                            $jobOk          = $true
                            Add-Totals -OrigBytes ([long]$job.SizeBytes) -NewBytes $newLen `
                                       -EncodeSec ([double]$job.EncodeSec) -VideoSec ([double]$job.DurationSec)
                            W ("GESLAAGD in {0} - {1} -> {2} ({3:N1} % kleiner)" -f `
                                (Format-Span $job.EncodeSec), (Format-Size $job.SizeBytes), (Format-Size $newLen), $pct)
                        }
                        else {
                            $job.Status     = 'Let op'
                            $job.ResultText = 'x265 aangemaakt, origineel NIET verwijderd'
                            $sync.Warned    = $sync.Warned + 1
                            $jobReason      = 'origineel kon niet worden verwijderd'
                            W 'LET OP: het x265-bestand staat er, maar het origineel kon niet worden verwijderd. Beide bestanden bestaan nu.' 'WAARS'
                        }
                    }
                }
            }

            # ---- lokale kopie opruimen ------------------------------
            #  Ongeacht de afloop. Een achtergebleven kopie van een paar GB
            #  is erger dan een kopie die opnieuw moet.
            if ($preHuidig -ne $null) {
                Stop-Prefetch $preHuidig
                $preHuidig = $null
            }

            # ---- afronden per bestand -------------------------------
            # Het lock hoort los ZODRA dit bestand klaar is, en niet pas aan
            # het eind van de rit: de andere pc mag er direct weer bij.
            Release-Lock $lock
            $lock = $null
            $script:HuidigLock = $null

            if ($jobDone) {
                $sync.JobsDone = $sync.JobsDone + 1
                $job.Queued    = $false
            }
            $sync.CurrentJob  = $null
            $sync.CurFile     = ''
            $sync.CurPhase    = ''
            $sync.CurPhasePct = 0
            $sync.CurVideoSec = 0
            $sync.CurDurationSec = 0

            # ---- noodstop na drie fouten op rij ---------------------
            if (Register-Outcome -Ok $jobOk -FileName $job.Name -Reason $jobReason `
                                 -CountsForStreak (-not $vcp -and -not $lockKwijt)) {
                W '' 'FOUT'
                W ("NOODSTOP: {0} keer op rij fout. Er is vermoedelijk iets structureel mis (bijvoorbeeld een read-only share of een volle schijf)." -f $st.MaxFailStreak) 'FOUT'
                W 'De rest van de wachtrij blijft staan; los de oorzaak op en druk opnieuw op Start.' 'FOUT'
                break
            }
        }

        Update-Timers

        # Kopieen die nog klaarstonden of halverwege waren: weg ermee. De
        # lus kan op tien plekken zijn uitgestapt, dus dit hoort hier en
        # niet bij een van die uitgangen.
        Stop-Prefetch $preHuidig
        Stop-Prefetch $pre
        $preHuidig = $null
        $pre       = $null
        Release-Lock $lock
        $lock = $null
        $script:HuidigLock = $null

        if ($busySkips -gt 0) {
            W ("{0} keer overgeslagen omdat een andere pc er al mee bezig was." -f $busySkips)
        }

        # ---- eindrapport --------------------------------------------
        $savedTotal = $sync.OrigBytes - $sync.NewBytes
        $savedPct   = 0.0
        if ($sync.OrigBytes -gt 0) { $savedPct = 100.0 * $savedTotal / $sync.OrigBytes }

        W ''
        W '============================================================'
        if ($sync.EmergencyStop)        { W 'GESTOPT - drie keer op rij fout' }
        elseif ($sync.Cancel)           { W 'GESTOPT (direct)' }
        elseif ($sync.StopAfterCurrent) { W 'GESTOPT (na huidige conversie)' }
        else                            { W 'KLAAR' }
        W '============================================================'
        W ("Verwerkt        : {0}" -f $sync.JobsDone)
        W ("Nog in wachtrij : {0}" -f $sync.Queue.Count)
        W ("Geslaagd        : {0}" -f $sync.Success)
        W ("Aandacht nodig  : {0}" -f $sync.Warned)
        W ("Mislukt         : {0}" -f $sync.Failed)
        W ("Rekentijd       : {0}" -f (Format-Span $sync.ActiveSec))
        W ("Wandkloktijd    : {0}  (gepauzeerd {1})" -f (Format-Span $sync.WallSec), (Format-Span $sync.PausedSec))
        W ("Origineel totaal: {0}" -f (Format-Size $sync.OrigBytes))
        W ("Na omzetting    : {0}" -f (Format-Size $sync.NewBytes))
        W ("Besparing       : {0}  ({1:N1} %)" -f (Format-Size $savedTotal), $savedPct)
        W '============================================================'
    }
    catch {
        $sync.WorkerError = $_.Exception.Message
        W "Onverwachte fout: $($_.Exception.Message)" 'FOUT'
        W ($_.ScriptStackTrace) 'FOUT'
    }
    finally {
        # Laatste vangnet voor de lokale kopieen: als er hierboven iets
        # onverwachts is misgegaan, mag er nog steeds niets van een paar GB
        # in de werkmap achterblijven.
        try { Stop-Prefetch $preHuidig } catch { }
        try { Stop-Prefetch $pre }       catch { }

        # En hetzelfde vangnet voor het lock: blijft dat staan, dan denkt de
        # andere pc nog een kwartier dat wij ermee bezig zijn.
        try { Release-Lock $script:HuidigLock } catch { }
        $script:HuidigLock = $null

        $swWall.Stop(); $swActive.Stop()
        $sync.CurrentJob  = $null
        $sync.CurFile     = ''
        $sync.CurPhase    = ''
        $sync.CurPhasePct = 0
        $sync.IsPaused    = $false
        $sync.ConvBusy    = $false
    }
}
