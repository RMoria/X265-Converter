
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

# ---------------------------------------------------------------------
# 7b. Naamregels: bestanden eenduidig hernoemen
#
#     Overgenomen uit Rename-Media.ps1. Video's worden
#         Serienaam.SxxExx(.Titel).ext   of   Serienaam.NN.ext
#     films worden CamelCaseNaam.ext of CamelCaseNaam.2.Titel.ext, en
#     ondertitels volgen de naam van hun video (met de taal erachter).
#
#     De lijsten waar de regels op draaien (rommel-tokens, extensies,
#     uitgesloten paden, algemene mapnamen, lidwoorden, taaltags) staan
#     hier als standaard. Wie andere regels wil zet in het
#     instellingenbestand onder "RenameRules" alleen de VERSCHILLEN:
#     <Lijst>Add en <Lijst>Remove. Zie New-RnRules.
#
#     Deze functies gaan ook mee naar de werk-threads (zie $HelperText):
#     ze lezen de regels uit $sync.RenameRules, en bouwen die zelf met
#     de standaard als er nog niets staat.
# ---------------------------------------------------------------------

function New-RnRules {
    param($Delta, [string]$VcpMarker = 'VCP')

    $lijsten = [ordered]@{
        VideoExtensions   = @('.mkv', '.mp4', '.avi', '.m4v')
        SubExtensions     = @('.srt', '.sub', '.idx', '.ass', '.ssa')
        ExcludePath       = @('*\3d\*')
        Junk              = @(
            '\d{3,4}[pi]', '[248]k', 'uhd', 'x26[45]', 'h26[45]', 'hevc', 'avc', 'xvid', 'divx', '\d{1,2}bit',
            'web', 'webdl', 'webrip', 'bluray', 'bdrip', 'brrip', 'hdtv', 'hdrip', 'dvdrip', 'remux',
            'repack', 'proper', 'extended', 'internal', 'limited',
            'amzn', 'nf', 'dsnp', 'hmax', 'atvp', 'hulu', 'pcok', 'multi',
            'hdr\d*', 'dv', 'av1', 'vp9', 'ddp?\d*', 'aac\d*', 'ac3', 'dts', 'truehd', 'atmos', '\dch',
            'jp', 'korean', 'japanese', 'eng', 'engsub', 'sub', 'subs', 'nlsub', 'nlsubs')
        JunkCaseSensitive = @('END')
        GenericDirs       = @('serie', 'series', 'tv', 'film', 'films', 'movies', 'anime', 'marvel', 'dc', '[a-z]:')
        FilmDirs          = @('film', 'films', 'movies')
        Articles          = @('the', 'a', 'an', 'de', 'het')
        LangTags          = @('nl', 'nld', 'dut', 'dutch', 'nederlands', 'en', 'eng', 'english', 'forced', 'sdh', 'hi')
    }
    # Lijsten waarvan de regels reguliere expressies zijn
    $regexLijsten = @('Junk', 'JunkCaseSensitive', 'GenericDirs', 'FilmDirs', 'LangTags')

    $waarsch = New-Object System.Collections.ArrayList

    function Get-DeltaLijst($naam) {
        if ($Delta -eq $null) { return @() }
        $w = $null
        if ($Delta -is [System.Collections.IDictionary]) {
            if ($Delta.Contains($naam)) { $w = $Delta[$naam] }
        }
        else {
            $p = $Delta.PSObject.Properties[$naam]
            if ($p) { $w = $p.Value }
        }
        if ($w -eq $null) { return @() }
        return @(@($w) | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_.Trim() })
    }

    $uit = @{}
    foreach ($naam in $lijsten.Keys) {
        $l = New-Object System.Collections.ArrayList
        foreach ($x in $lijsten[$naam]) { [void]$l.Add([string]$x) }

        foreach ($x in (Get-DeltaLijst ($naam + 'Remove'))) {
            $weg = @($l | Where-Object { $_ -ieq $x.Trim() })
            if ($weg.Count -eq 0) { [void]$waarsch.Add("RenameRules.$($naam)Remove: '$x' staat niet in de standaardlijst") }
            foreach ($y in $weg) { [void]$l.Remove($y) }
        }
        foreach ($x in (Get-DeltaLijst ($naam + 'Add'))) {
            $x = $x.Trim()
            if ($regexLijsten -contains $naam) {
                try { [void][regex]::new('^(?:' + $x + ')$') }
                catch { [void]$waarsch.Add("RenameRules.$($naam)Add: '$x' is geen geldige reguliere expressie en wordt genegeerd"); continue }
            }
            if (-not (@($l) | Where-Object { $_ -ieq $x })) { [void]$l.Add($x) }
        }

        if ($naam -like '*Extensions') {
            $n = New-Object System.Collections.ArrayList
            foreach ($x in $l) {
                $e = $x.Trim().ToLower()
                if (-not $e.StartsWith('.')) { $e = '.' + $e }
                if (-not ($n -contains $e)) { [void]$n.Add($e) }
            }
            $l = $n
        }
        $uit[$naam] = [string[]]@($l)
    }

    function Samen([string[]]$d) {
        if ($d.Count -eq 0) { return '(?!)' }      # lege lijst: past nergens op
        return ($d -join '|')
    }

    $uit.JunkRegex         = '^(?i)(?:' + (Samen $uit.Junk) + ')(?:[-.].*)?$'
    $uit.JunkCsRegex       = '^(?:' + (Samen $uit.JunkCaseSensitive) + ')$'
    $uit.GenericDirRegex   = '^(?i)(?:' + (Samen $uit.GenericDirs) + ')$'
    $uit.SeasonDirRegex    = '^(?i)(s\d{1,2}|season[ ._]?\d{1,2}|seizoen[ ._]?\d{1,2})$'
    $uit.FilmDirRegex      = '(?i)[\\/](?:' + (Samen $uit.FilmDirs) + ')[\\/]'
    $uit.LangRegex         = '(?i)((?:[._ ](?:' + (Samen $uit.LangTags) + '))+)$'
    $uit.YearRegex         = '^(19|20)\d{2}$'
    # Het VCP-kenmerk zet het programma zelf (<naam>.VCP.mkv); dat moet
    # bij het hernoemen blijven staan.
    $uit.VcpMarker         = $(if ([string]::IsNullOrWhiteSpace($VcpMarker)) { 'VCP' } else { $VcpMarker.Trim() })
    $uit.Warnings          = [string[]]@($waarsch)
    return $uit
}

# Een leeg sjabloon voor in het instellingenbestand: alle sleutels die
# een delta kunnen dragen, zodat je ziet wat er kan.
function New-RnDeltaTemplate {
    $o = [ordered]@{}
    foreach ($n in @('VideoExtensions','SubExtensions','ExcludePath','Junk','JunkCaseSensitive',
                     'GenericDirs','FilmDirs','Articles','LangTags')) {
        $o[$n + 'Add']    = @()
        $o[$n + 'Remove'] = @()
    }
    return [pscustomobject]$o
}

function Get-RnRules {
    $r = $sync.RenameRules
    if ($r -eq $null) { $r = New-RnRules $null; $sync.RenameRules = $r }
    return $r
}

function Test-RnJunk([string]$tok) {
    $R = Get-RnRules
    return ($tok -match $R.JunkRegex) -or ($tok -cmatch $R.JunkCsRegex)
}

function Remove-RnBrackets([string]$s) {
    # [..] is in de praktijk altijd rommel (hash, groep, [1080p], [EZTVx.to])
    $s = [regex]::Replace($s, '\[[^\]]*\]', ' ')
    # (1080p) / (A1B2C3D4) weg, andere haakjes "uitpakken": Armageddon (1) -> Armageddon 1
    $s = [regex]::Replace($s, '\((?:\d{3,4}[pi]|[0-9A-Fa-f]{8})\)', ' ')
    $s = $s -replace '[()]', ' '
    return $s
}

function Get-RnCleanWord([string]$w) {
    return [regex]::Replace($w, '[^\p{L}\p{N}]', '')
}

function Get-RnNameTokens([string]$s) {
    $s = $s -replace '&', ' and '
    $out = @()
    foreach ($t in ($s -split '[\s._\-,;:+]+')) {
        $c = Get-RnCleanWord $t
        if ($c) { $out += $c }
    }
    return ,$out
}

function Get-RnStopAtJunk([string[]]$tokens) {
    $out = @()
    foreach ($t in $tokens) {
        if (Test-RnJunk $t) { break }
        $out += $t
    }
    return ,$out
}

function Get-RnRawTokensUntilJunk([string]$s) {
    # Koppeltekens binnen een token blijven heel, zodat "WEB-DL",
    # "x265-MeGusta" en "DTS-HD" als geheel herkend worden.
    $out = @()
    foreach ($t in ($s -split '[\s._,;]+')) {
        if (-not $t) { continue }
        if (Test-RnJunk $t) { break }
        $out += $t
    }
    return ,$out
}

function Test-RnAllCaps([string[]]$tokens) {
    $letters = (-join $tokens) -replace '[^\p{L}]', ''
    return ($letters.Length -ge 3) -and ($letters -cmatch '^\p{Lu}+$')
}

function ConvertTo-RnCamel([string[]]$tokens) {
    $allCaps = Test-RnAllCaps $tokens
    $sb = ''
    foreach ($t in $tokens) {
        if ($allCaps) { $t = $t.ToLower() }
        $sb += $t.Substring(0, 1).ToUpper() + $t.Substring(1)
    }
    return $sb
}

function Format-RnTitle([string]$s) {
    $s = $s -replace '&', ' and '
    $raw = Get-RnRawTokensUntilJunk $s
    $words = @()
    foreach ($t in $raw) {
        $c = [regex]::Replace($t, '[^\p{L}\p{N}\-]', '').Trim('-')
        if ($c) { $words += $c }
    }
    if ($words.Count -eq 0) { return '' }
    if (Test-RnAllCaps $words) {
        $words = @($words | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1).ToLower() })
    }
    return ($words -join '.')
}

function Get-RnShowDirHint([string]$fullPath) {
    $R = Get-RnRules
    $dirs = ($fullPath -split '[\\/]')
    if ($dirs.Count -lt 2) { return $null }
    $dirs = $dirs[0..($dirs.Count - 2)]
    for ($i = $dirs.Count - 1; $i -ge 0; $i--) {
        $d = $dirs[$i].Trim()
        if (-not $d) { continue }
        if ($d -match $R.GenericDirRegex -or $d -match $R.SeasonDirRegex) { continue }
        # "Supernatural.S01" -> "Supernatural"
        $d = $d -replace '(?i)[ ._\-]+(s\d{1,2}|season[ ._]?\d{1,2}|seizoen[ ._]?\d{1,2})$', ''
        return $d
    }
    return $null
}

function Remove-RnPrefixByDir([string[]]$tokens, [string]$dirHint) {
    $R = Get-RnRules
    if (-not $dirHint -or $tokens.Count -lt 2) { return ,$tokens }
    $dirTokens = Get-RnNameTokens $dirHint
    if ($dirTokens.Count -eq 0) { return ,$tokens }
    $first = $dirTokens[0].ToLower()
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        if ($tokens[$i].ToLower() -eq $first) {
            if ($i -eq 0) { return ,$tokens }
            $start = $i
            # Lidwoord direct ervoor mag blijven ("marvels.the.punisher" -> "ThePunisher")
            if ($R.Articles -contains $tokens[$i - 1].ToLower()) { $start = $i - 1 }
            return ,@($tokens[$start..($tokens.Count - 1)])
        }
    }
    return ,$tokens
}

function Get-RnShowName([string]$rawShow, [string]$dirHint, [ref]$seasonOut) {
    $R = Get-RnRules
    $rawShow = Remove-RnBrackets $rawShow
    $tokens = Get-RnNameTokens $rawShow
    $tokens = Get-RnStopAtJunk $tokens
    if ($tokens.Count -gt 1 -and $tokens[-1] -match '^(?i)s(\d{1,2})$') {
        if ($seasonOut) { $seasonOut.Value = [int]$Matches[1] }
        $tokens = @($tokens[0..($tokens.Count - 2)])
    }
    while ($tokens.Count -gt 1 -and $tokens[-1] -match $R.YearRegex) {
        $tokens = @($tokens[0..($tokens.Count - 2)])
    }
    $tokens = Remove-RnPrefixByDir $tokens $dirHint
    if ($tokens.Count -eq 0) { return $null }
    return (ConvertTo-RnCamel $tokens)
}

function Format-RnEp([string]$num) {
    $n = $num.TrimStart('0')
    if (-not $n) { $n = '0' }
    # minimaal 2 cijfers; langere nummers (One Piece 0001) houden hun breedte
    $width = [Math]::Max(2, $num.Length)
    return $n.PadLeft($width, '0')
}

function Split-RnPath([string]$p) {
    $i = $p.LastIndexOfAny([char[]]@('\', '/'))
    if ($i -lt 0) { return @('', $p, '') }
    return @($p.Substring(0, $i), $p.Substring($i + 1), $p.Substring($i, 1))
}

function Join-RnParts($show, $ep, $title, $ext, $dirHint) {
    if (-not $show -and $dirHint) { $show = ConvertTo-RnCamel (Get-RnNameTokens $dirHint) }
    if (-not $show) { return $null }
    $n = "$show.$ep"
    if ($title) { $n += ".$title" }
    return "$n$ext"
}

# Nieuwe BESTANDSNAAM (zonder map) volgens de naamregels, of $null als de
# naam niet te herkennen is.
function Get-RnNewName([string]$fullPath) {
    $R = Get-RnRules
    $parts0   = Split-RnPath $fullPath
    $fileName = $parts0[1]
    $ext      = [IO.Path]::GetExtension($fileName).ToLower()
    $base     = [IO.Path]::GetFileNameWithoutExtension($fileName)

    # <naam>.VCP.mkv: de rest opschonen en het kenmerk er weer achter zetten
    $vcp = '.' + [string]$R.VcpMarker
    if ($R.VcpMarker -and $base.Length -gt $vcp.Length -and $base.EndsWith($vcp, [StringComparison]::OrdinalIgnoreCase)) {
        $zonder = $base.Substring(0, $base.Length - $vcp.Length)
        $sep = $parts0[2]; if (-not $sep) { $sep = '\' }
        $n = Get-RnNewName ($parts0[0] + $sep + $zonder + $ext)
        if (-not $n) { return $null }
        return [IO.Path]::GetFileNameWithoutExtension($n) + $vcp + $ext
    }
    $dirHint  = Get-RnShowDirHint $fullPath
    $isFilm   = $fullPath -match $R.FilmDirRegex

    # "[CameEsp] Dungeon Meshi - 01" -> groep vooraan eraf
    $work = $base -replace '^\s*\[[^\]]*\]\s*', ''

    # 1) SxxExx (ook s01e01, S01E01-E02)
    $m = [regex]::Match($work, '(?i)(?<![A-Za-z0-9])S(\d{1,2})[ ._]?E(\d{1,4})(?:-?E(\d{1,4}))?(?![0-9])')
    if ($m.Success) {
        $season = [int]$m.Groups[1].Value
        $ep = 'S{0:D2}E{1}' -f $season, (Format-RnEp $m.Groups[2].Value)
        if ($m.Groups[3].Success) { $ep += '-E' + (Format-RnEp $m.Groups[3].Value) }
        $show  = Get-RnShowName $work.Substring(0, $m.Index) $dirHint ([ref]$null)
        $title = Format-RnTitle (Remove-RnBrackets $work.Substring($m.Index + $m.Length))
        return (Join-RnParts $show $ep $title $ext $dirHint)
    }

    # 1b) 1x09 (ook 01x09): seizoen x aflevering
    $m = [regex]::Match($work, '(?i)(?<![A-Za-z0-9])(\d{1,2})x(\d{2,3})(?![0-9])')
    if ($m.Success) {
        $ep    = 'S{0:D2}E{1}' -f [int]$m.Groups[1].Value, (Format-RnEp $m.Groups[2].Value)
        $show  = Get-RnShowName $work.Substring(0, $m.Index) $dirHint ([ref]$null)
        $title = Format-RnTitle (Remove-RnBrackets $work.Substring($m.Index + $m.Length))
        return (Join-RnParts $show $ep $title $ext $dirHint)
    }

    # 2) Anime: "Naam - 12", "Naam S2 - 12v2", "One Piece - 0001"
    $clean = Remove-RnBrackets $work
    $m = [regex]::Match($clean, '^(?<show>.+)[\s._]-\s*(?<ep>\d{1,4})(?:v\d+)?(?=[\s._]|$)')
    if ($m.Success -and -not $isFilm) {
        $season = $null
        $show = Get-RnShowName $m.Groups['show'].Value $dirHint ([ref]$season)
        if ($null -ne $season) { $ep = 'S{0:D2}E{1}' -f $season, (Format-RnEp $m.Groups['ep'].Value) }
        else                   { $ep = Format-RnEp $m.Groups['ep'].Value }
        return (Join-RnParts $show $ep '' $ext $dirHint)
    }

    # 3) Alleen een nummer: "Death.Note.01.Rebirth" -> DeathNote.01.Rebirth,
    #    "Boku no Hero Academia 171" -> BokuNoHeroAcademia.171. Het nummer
    #    blijft een nummer: zonder SxxExx of 1x09 wordt er geen seizoen
    #    verzonnen. Een jaartal telt niet als nummer.
    $m = [regex]::Match($clean, '^(?<show>.+?)[\s._](?<ep>(?!(?:19|20)\d{2}(?:[\s._]|$))\d{2,4})(?:[\s._](?<rest>.*))?$')
    if ($m.Success -and -not $isFilm) {
        $show  = Get-RnShowName $m.Groups['show'].Value $dirHint ([ref]$null)
        $ep    = Format-RnEp $m.Groups['ep'].Value
        $title = Format-RnTitle $m.Groups['rest'].Value
        return (Join-RnParts $show $ep $title $ext $dirHint)
    }

    # 4) Film: Naam  of  Naam.Nummer.Titel  (jaartal verdwijnt)
    $tokens = Get-RnStopAtJunk (Get-RnNameTokens $clean)
    for ($i = $tokens.Count - 1; $i -ge 1; $i--) {
        if ($tokens[$i] -match $R.YearRegex) { $tokens = @($tokens[0..($i - 1)]); break }
    }
    $tokens = Remove-RnPrefixByDir $tokens $dirHint
    if ($tokens.Count -eq 0) { return $null }

    for ($i = 1; $i -lt $tokens.Count; $i++) {
        if ($tokens[$i] -match '^\d{1,2}$') {
            $name = ConvertTo-RnCamel @($tokens[0..($i - 1)])
            $n    = [int]$tokens[$i]
            $rest = @()
            if ($i + 1 -lt $tokens.Count) { $rest = @($tokens[($i + 1)..($tokens.Count - 1)]) }
            $title = Format-RnTitle ($rest -join ' ')
            $out = "$name.$n"
            if ($title) { $out += ".$title" }
            return "$out$ext"
        }
    }
    return (ConvertTo-RnCamel $tokens) + $ext
}

# Kwaliteit voor het kiezen tussen dubbelen: bron (BluRay > WEB > HDTV),
# dan resolutie.
function Get-RnQuality([string]$name) {
    $src = 0
    if     ($name -match '(?i)blu-?ray|bdrip|brrip|bdremux|remux') { $src = 3 }
    elseif ($name -match '(?i)web')                               { $src = 2 }
    elseif ($name -match '(?i)hdtv')                              { $src = 1 }
    $res = 0
    if     ($name -match '(?i)2160p|\b4k\b|uhd') { $res = 2160 }
    elseif ($name -match '(?i)1080[pi]')         { $res = 1080 }
    elseif ($name -match '(?i)720p')             { $res = 720 }
    elseif ($name -match '(?i)480p|576p')        { $res = 480 }
    return ($src * 10000 + $res)
}

function Get-RnLangSuffix([string]$rest) {
    # ".nl" -> ".nl", "." -> "", " Dutch.dut" -> ".Dutch.dut"
    $parts = @($rest -split '[\s._]+' | Where-Object { $_ })
    if ($parts.Count -eq 0) { return '' }
    return '.' + ($parts -join '.')
}

function Test-RnExcluded([string]$fullPath) {
    $R = Get-RnRules
    $p = $fullPath -replace '/', '\'
    foreach ($pat in $R.ExcludePath) { if ($p -like $pat) { return $true } }
    return $false
}

# -----------------------------------------------------------------
#  Het plan voor een hele verzameling bestanden
#
#  $Files  : volledige paden (video's en ondertitels door elkaar)
#  $Frozen : paden die NIET mogen veranderen (bijvoorbeeld omdat een
#            andere pc er een lock op heeft). Ze doen wel mee als
#            'OVERGESLAGEN (in gebruik)', zodat hun ondertitels ze nog
#            herkennen en niet een eigen kant op gaan.
# -----------------------------------------------------------------
function Get-RnPlan {
    param([string[]]$Files, [string[]]$Frozen = @())

    $R = Get-RnRules
    $frozenSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($Frozen)) { if ($f) { [void]$frozenSet.Add($f) } }

    $all = @($Files | Where-Object { $_ -and -not (Test-RnExcluded $_) })
    $videoFiles = @($all | Where-Object { $R.VideoExtensions -contains [IO.Path]::GetExtension($_).ToLower() })
    $subFiles   = @($all | Where-Object { $R.SubExtensions   -contains [IO.Path]::GetExtension($_).ToLower() })

    $videos = New-Object System.Collections.Generic.List[object]
    foreach ($f in $videoFiles) {
        $parts = Split-RnPath $f
        $sep   = if ($parts[2]) { $parts[2] } else { [IO.Path]::DirectorySeparatorChar }
        $new   = $null
        $status = 'OK'
        if ($frozenSet.Contains($f)) {
            $status = 'OVERGESLAGEN (in gebruik)'; $new = $parts[1]
        }
        else {
            try { $new = Get-RnNewName $f } catch { $new = $null }
            if (-not $new) { $status = 'OVERGESLAGEN (niet herkend)'; $new = $parts[1] }
        }
        $videos.Add([pscustomobject]@{
            Type = 'video'; Status = $status; Map = $parts[0]; Sep = $sep
            Oud = $parts[1]; Nieuw = $new; OldPath = $f; NewPath = ($parts[0] + $sep + $new)
            OldBase = [IO.Path]::GetFileNameWithoutExtension($parts[1])
            NewBase = [IO.Path]::GetFileNameWithoutExtension($new)
            Quality = (Get-RnQuality $parts[1]); KeptAs = ''
        })
    }

    # Dubbelen: zelfde nieuwe naam in dezelfde map. De beste blijft.
    foreach ($grp in ($videos | Where-Object { $_.Status -eq 'OK' } | Group-Object { $_.NewPath.ToLower() })) {
        if ($grp.Count -lt 2) { continue }
        # Hoogste kwaliteit; bij gelijke kwaliteit de eerste in de lijst
        $best = $null
        foreach ($v in $grp.Group) { if ($best -eq $null -or $v.Quality -gt $best.Quality) { $best = $v } }
        foreach ($v in $grp.Group) {
            if ($v -ne $best) { $v.Status = 'VERWIJDEREN (dubbel)'; $v.KeptAs = $best.Oud }
        }
    }
    foreach ($v in $videos) { if ($v.Status -eq 'OK' -and $v.Nieuw -ceq $v.Oud) { $v.Status = 'AL GOED' } }

    $byDir = @{}
    foreach ($v in $videos) {
        $k = $v.Map.ToLower()
        if (-not $byDir.ContainsKey($k)) { $byDir[$k] = New-Object System.Collections.Generic.List[object] }
        $byDir[$k].Add($v)
    }

    $subs = New-Object System.Collections.Generic.List[object]
    foreach ($f in $subFiles) {
        $parts = Split-RnPath $f
        $sep   = if ($parts[2]) { $parts[2] } else { [IO.Path]::DirectorySeparatorChar }
        $ext   = [IO.Path]::GetExtension($parts[1]).ToLower()
        $base  = [IO.Path]::GetFileNameWithoutExtension($parts[1])
        $bl    = $base.ToLower()

        # 1) video in dezelfde map waarvan de naam het begin is (langste wint)
        $match = $null
        if ($byDir.ContainsKey($parts[0].ToLower())) {
            foreach ($v in $byDir[$parts[0].ToLower()]) {
                $vb = $v.OldBase.ToLower()
                if ($bl -eq $vb -or ($bl.StartsWith($vb) -and $bl.Length -gt $vb.Length -and ('. _-'.IndexOf($bl[$vb.Length]) -ge 0))) {
                    if (-not $match -or $v.OldBase.Length -gt $match.OldBase.Length) { $match = $v }
                }
            }
        }

        $status = 'OK'; $new = $null; $note = ''
        if ($frozenSet.Contains($f)) {
            $status = 'OVERGESLAGEN (in gebruik)'; $new = $parts[1]
        }
        elseif ($match -and $match.Status -eq 'OVERGESLAGEN (in gebruik)') {
            # De video is bij een andere pc onder handen; die neemt de
            # ondertitels straks zelf mee. Afblijven.
            $status = 'OVERGESLAGEN (video in gebruik)'; $new = $parts[1]; $note = "video: $($match.Oud)"
        }
        elseif ($match) {
            $lang = Get-RnLangSuffix $base.Substring($match.OldBase.Length)
            $new  = $match.NewBase + $lang + $ext
            if ($match.Status -like 'VERWIJDEREN*') { $status = 'VERWIJDEREN (hoort bij dubbel)' }
            $note = "video: $($match.Oud)"
        }
        else {
            # 2) geen video: de ondertitel zelf opschonen (taalcode blijft)
            $lang = ''; $core = $base
            $lm = [regex]::Match($base, $R.LangRegex)
            if ($lm.Success) { $lang = Get-RnLangSuffix $lm.Groups[1].Value; $core = $base.Substring(0, $lm.Index) }
            $tmpPath = $parts[0] + $sep + $core + $ext
            $n = $null
            try { $n = Get-RnNewName $tmpPath } catch { $n = $null }
            if ($n) {
                $new = [IO.Path]::GetFileNameWithoutExtension($n) + $lang + $ext
                $status = 'OK (geen video gevonden)'
                $key = ([IO.Path]::GetFileNameWithoutExtension($n) -split '\.')[0..1] -join '.'
                if ($byDir.ContainsKey($parts[0].ToLower())) {
                    $cand = @($byDir[$parts[0].ToLower()] | Where-Object {
                        $_.Status -notlike 'VERWIJDEREN*' -and (($_.NewBase -split '\.')[0..1] -join '.') -eq $key })
                    if ($cand.Count -eq 1) { $new = $cand[0].NewBase + $lang + $ext; $status = 'OK'; $note = "video: $($cand[0].Oud)" }
                }
            }
            else {
                $status = 'OVERGESLAGEN (niet herkend)'; $new = $parts[1]
            }
        }
        if ($status -like 'OK*' -and $new -ceq $parts[1]) { $status = 'AL GOED' }
        $subs.Add([pscustomobject]@{
            Type = 'ondertitel'; Status = $status; Map = $parts[0]; Sep = $sep
            Oud = $parts[1]; Nieuw = $new; OldPath = $f; NewPath = ($parts[0] + $sep + $new)
            OldBase = $base; NewBase = [IO.Path]::GetFileNameWithoutExtension($new)
            Quality = 0; KeptAs = $note
        })
    }

    # Botsingen: twee bestanden met dezelfde doelnaam -> de eerste wint.
    # Een bestand dat blijft staan (al goed, overgeslagen) bezet zijn naam.
    $taken = @{}
    $rijen = [object[]]$videos.ToArray() + [object[]]$subs.ToArray()
    foreach ($r in $rijen) {
        if ($r.Status -like 'VERWIJDEREN*') { continue }
        # Blijft staan (of verandert alleen van hoofdletters): die plek is bezet
        if ($r.Status -like 'OVERGESLAGEN*' -or $r.Status -eq 'AL GOED' -or
            $r.NewPath.ToLower() -eq $r.OldPath.ToLower()) { $taken[$r.OldPath.ToLower()] = $r.Oud }
    }
    foreach ($r in $rijen) {
        if ($r.Status -like 'VERWIJDEREN*' -or $r.Status -like 'OVERGESLAGEN*' -or $r.Status -eq 'AL GOED') { continue }
        $k = $r.NewPath.ToLower()
        if ($taken.ContainsKey($k) -and $k -ne $r.OldPath.ToLower()) {
            $r.Status = 'CONFLICT (zelfde naam)'; $r.KeptAs = "botst met: $($taken[$k])"
        }
        else { $taken[$k] = $r.Oud }
    }

    return ,$rijen
}

function Remove-RnToRecycle([string]$Path) {
    $recycle = $false
    if ($env:OS -eq 'Windows_NT') {
        try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; $recycle = $true } catch { }
    }
    if ($recycle) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
    else {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $Path) { throw 'bestand staat er nog' }
}

# Staat er (op een hoofdlettergevoelig bestandssysteem) al een ANDER
# bestand met precies de doelnaam? Alleen nodig als de namen alleen in
# hoofdletters verschillen; op Windows is dat nooit zo.
function Test-RnOtherExists([string]$OldPath, [string]$NewPath) {
    $n = [IO.Path]::GetFileName($NewPath)
    $o = [IO.Path]::GetFileName($OldPath)
    if ($n -ceq $o) { return $false }
    try {
        foreach ($x in [IO.Directory]::GetFiles([IO.Path]::GetDirectoryName($NewPath))) {
            if ([IO.Path]::GetFileName($x) -ceq $n) { return $true }
        }
    } catch { }
    return $false
}

# Een hernoeming, ook als alleen de hoofdletters verschillen (dan moet het
# via een tijdelijke naam, anders doet Windows niets).
function Rename-RnFile([string]$OldPath, [string]$NewPath) {
    $newName = [IO.Path]::GetFileName($NewPath)
    if ($OldPath.ToLower() -eq $NewPath.ToLower()) {
        $tmp = $newName + '.tmp_rename'
        Rename-Item -LiteralPath $OldPath -NewName $tmp -ErrorAction Stop
        Rename-Item -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($OldPath)) $tmp) -NewName $newName -ErrorAction Stop
    }
    else {
        Rename-Item -LiteralPath $OldPath -NewName $newName -ErrorAction Stop
    }
}

function Add-RnUndo([string]$UndoFile, [object[]]$Rows) {
    if ([string]::IsNullOrWhiteSpace($UndoFile) -or $Rows.Count -eq 0) { return }
    try {
        $rows2 = @($Rows | ForEach-Object { [pscustomobject]@{ OldPath = $_.OldPath; NewPath = $_.NewPath } })
        if (Test-Path -LiteralPath $UndoFile) {
            $rows2 | Export-Csv -LiteralPath $UndoFile -NoTypeInformation -Encoding UTF8 -Append
        } else {
            $rows2 | Export-Csv -LiteralPath $UndoFile -NoTypeInformation -Encoding UTF8
        }
    }
    catch { W ("Het undo-bestand kon niet worden bijgewerkt: {0}" -f $_.Exception.Message) 'WAARS' }
}

# -----------------------------------------------------------------
#  Een plan uitvoeren: eerst de dubbelen naar de Prullenbak, dan
#  hernoemen. $StillFree is een scriptblock dat per pad zegt of het nog
#  mag (bijvoorbeeld: is er intussen geen lock op gekomen?).
# -----------------------------------------------------------------
function Invoke-RnPlan {
    param([object[]]$Plan, [string]$UndoFile, [scriptblock]$StillFree = $null)

    $done    = New-Object System.Collections.Generic.List[object]
    $deleted = New-Object System.Collections.Generic.List[string]
    $failed  = 0

    foreach ($r in @($Plan | Where-Object { $_.Status -like 'VERWIJDEREN*' })) {
        if ($sync.ScanCancel) { break }
        if (-not (Test-Path -LiteralPath $r.OldPath)) { continue }
        if ($StillFree -and -not (& $StillFree $r.OldPath)) { W ("Overgeslagen, inmiddels in gebruik: {0}" -f $r.OldPath) 'WAARS'; continue }
        try {
            Remove-RnToRecycle $r.OldPath
            $deleted.Add($r.OldPath)
            W ("Dubbel naar de Prullenbak: {0}  (blijft: {1})" -f $r.OldPath, $r.KeptAs)
        }
        catch { $failed++; W ("Verwijderen mislukt: {0}: {1}" -f $r.OldPath, $_.Exception.Message) 'WAARS' }
    }

    foreach ($r in @($Plan | Where-Object { $_.Status -like 'OK*' })) {
        if ($sync.ScanCancel) { break }
        if (-not (Test-Path -LiteralPath $r.OldPath)) { continue }
        $caseOnly = $r.OldPath.ToLower() -eq $r.NewPath.ToLower()
        if ((Test-Path -LiteralPath $r.NewPath) -and (-not $caseOnly -or (Test-RnOtherExists $r.OldPath $r.NewPath))) {
            W ("Doel bestaat al, overgeslagen: {0}" -f $r.NewPath) 'WAARS'; continue
        }
        if ($StillFree -and -not (& $StillFree $r.OldPath)) { W ("Overgeslagen, inmiddels in gebruik: {0}" -f $r.OldPath) 'WAARS'; continue }
        try {
            Rename-RnFile $r.OldPath $r.NewPath
            $done.Add($r)
            W ("Hernoemd: {0}  ->  {1}" -f $r.Oud, $r.Nieuw)
        }
        catch { $failed++; W ("Hernoemen mislukt: {0}: {1}" -f $r.OldPath, $_.Exception.Message) 'WAARS' }
    }

    Add-RnUndo $UndoFile ([object[]]$done.ToArray())
    return [pscustomobject]@{
        Renamed = [object[]]$done.ToArray()
        Deleted = [string[]]$deleted.ToArray()
        Failed  = $failed
    }
}

# -----------------------------------------------------------------
#  Eén net omgezet bestand hernoemen, met zijn ondertitels
#
#  Geen dubbelen-afhandeling: er wordt nooit iets verwijderd. Bestaat de
#  doelnaam al, dan blijft alles zoals het is.
#  Geeft het (eventueel nieuwe) pad van de video terug.
# -----------------------------------------------------------------
function Invoke-RnSingle {
    param([string]$VideoPath, [string]$UndoFile)

    $R = Get-RnRules
    if (Test-RnExcluded $VideoPath) { return $VideoPath }

    $dir = [IO.Path]::GetDirectoryName($VideoPath)
    $new = $null
    try { $new = Get-RnNewName $VideoPath } catch { $new = $null }
    if (-not $new) { W ("Hernoemen: naam niet herkend, blijft staan: {0}" -f ([IO.Path]::GetFileName($VideoPath))) 'WAARS'; return $VideoPath }

    $newPath = Join-Path $dir $new
    if ($newPath -ceq $VideoPath) { return $VideoPath }                  # al goed
    $caseOnly = $newPath.ToLower() -eq $VideoPath.ToLower()
    if ((Test-Path -LiteralPath $newPath) -and (-not $caseOnly -or (Test-RnOtherExists $VideoPath $newPath))) {
        W ("Hernoemen overgeslagen (CONFLICT), {0} bestaat al." -f $new) 'WAARS'
        return $VideoPath
    }

    # Ondertitels die bij DEZE video horen: de langste passende videonaam
    # in de map wint, zodat 'Naam 2.nl.srt' niet bij 'Naam.mkv' belandt.
    $oldBase = [IO.Path]::GetFileNameWithoutExtension($VideoPath)
    $newBase = [IO.Path]::GetFileNameWithoutExtension($new)
    $inMap = @()
    try { $inMap = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop) } catch { }
    $videoBases = @($inMap | Where-Object { $R.VideoExtensions -contains $_.Extension.ToLower() } |
                    ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) })
    $subPlan = New-Object System.Collections.Generic.List[object]
    foreach ($c in @($inMap | Where-Object { $R.SubExtensions -contains $_.Extension.ToLower() })) {
        $b  = [IO.Path]::GetFileNameWithoutExtension($c.Name)
        $bl = $b.ToLower()
        $best = $null
        foreach ($vb in $videoBases) {
            $v = $vb.ToLower()
            if ($bl -eq $v -or ($bl.StartsWith($v) -and $bl.Length -gt $v.Length -and ('. _-'.IndexOf($bl[$v.Length]) -ge 0))) {
                if (-not $best -or $vb.Length -gt $best.Length) { $best = $vb }
            }
        }
        if ($best -eq $null -or $best.ToLower() -ne $oldBase.ToLower()) { continue }
        $subNew = $newBase + (Get-RnLangSuffix $b.Substring($oldBase.Length)) + $c.Extension.ToLower()
        $subPlan.Add([pscustomobject]@{ OldPath = $c.FullName; NewPath = (Join-Path $dir $subNew); Oud = $c.Name; Nieuw = $subNew })
    }

    $done = New-Object System.Collections.Generic.List[object]
    try {
        Rename-RnFile $VideoPath $newPath
        $done.Add([pscustomobject]@{ OldPath = $VideoPath; NewPath = $newPath })
        W ("Hernoemd volgens de naamregels: {0}  ->  {1}" -f ([IO.Path]::GetFileName($VideoPath)), $new)
    }
    catch {
        W ("Hernoemen mislukt: {0}" -f $_.Exception.Message) 'WAARS'
        return $VideoPath
    }
    foreach ($s in $subPlan) {
        if ($s.OldPath -ceq $s.NewPath) { continue }
        if ((Test-Path -LiteralPath $s.NewPath) -and (($s.OldPath.ToLower() -ne $s.NewPath.ToLower()) -or (Test-RnOtherExists $s.OldPath $s.NewPath))) {
            W ("Ondertitel niet hernoemd, {0} bestaat al." -f $s.Nieuw) 'WAARS'; continue
        }
        try {
            Rename-RnFile $s.OldPath $s.NewPath
            $done.Add([pscustomobject]@{ OldPath = $s.OldPath; NewPath = $s.NewPath })
            W ("Ondertitel hernoemd: {0}  ->  {1}" -f $s.Oud, $s.Nieuw)
        }
        catch { W ("Ondertitel {0} niet hernoemd: {1}" -f $s.Oud, $_.Exception.Message) 'WAARS' }
    }
    Add-RnUndo $UndoFile ([object[]]$done.ToArray())
    return $newPath
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
function New-RnRules {
$(${function:New-RnRules})
}
function New-RnDeltaTemplate {
$(${function:New-RnDeltaTemplate})
}
function Get-RnRules {
$(${function:Get-RnRules})
}
function Test-RnJunk {
$(${function:Test-RnJunk})
}
function Remove-RnBrackets {
$(${function:Remove-RnBrackets})
}
function Get-RnCleanWord {
$(${function:Get-RnCleanWord})
}
function Get-RnNameTokens {
$(${function:Get-RnNameTokens})
}
function Get-RnStopAtJunk {
$(${function:Get-RnStopAtJunk})
}
function Get-RnRawTokensUntilJunk {
$(${function:Get-RnRawTokensUntilJunk})
}
function Test-RnAllCaps {
$(${function:Test-RnAllCaps})
}
function ConvertTo-RnCamel {
$(${function:ConvertTo-RnCamel})
}
function Format-RnTitle {
$(${function:Format-RnTitle})
}
function Get-RnShowDirHint {
$(${function:Get-RnShowDirHint})
}
function Remove-RnPrefixByDir {
$(${function:Remove-RnPrefixByDir})
}
function Get-RnShowName {
$(${function:Get-RnShowName})
}
function Format-RnEp {
$(${function:Format-RnEp})
}
function Split-RnPath {
$(${function:Split-RnPath})
}
function Join-RnParts {
$(${function:Join-RnParts})
}
function Get-RnNewName {
$(${function:Get-RnNewName})
}
function Get-RnQuality {
$(${function:Get-RnQuality})
}
function Get-RnLangSuffix {
$(${function:Get-RnLangSuffix})
}
function Test-RnExcluded {
$(${function:Test-RnExcluded})
}
function Get-RnPlan {
$(${function:Get-RnPlan})
}
function Remove-RnToRecycle {
$(${function:Remove-RnToRecycle})
}
function Test-RnOtherExists {
$(${function:Test-RnOtherExists})
}
function Rename-RnFile {
$(${function:Rename-RnFile})
}
function Add-RnUndo {
$(${function:Add-RnUndo})
}
function Invoke-RnPlan {
$(${function:Invoke-RnPlan})
}
function Invoke-RnSingle {
$(${function:Invoke-RnSingle})
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
