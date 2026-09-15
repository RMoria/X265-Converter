# ---------------------------------------------------------------------
#  Bijwerken.ps1  -  haalt de nieuwste uitgebrachte versie op
#
#  Wordt door X265-Converter.cmd aangeroepen vlak voor het starten. Doet
#  niets als er al een gelijke of nieuwere versie staat, en niets als er
#  al een instantie draait.
#
#  Er wordt alleen gekeken naar TAGS (v1.4, v1.5). Een losse commit op
#  main wordt genegeerd: een tag is het bewuste "dit mag eruit"-moment.
#
#  Twee wegen naar dezelfde uitkomst:
#    1. git  - staat het erop, dan wordt het gebruikt. Zo niet, dan wordt
#       geprobeerd het via winget te installeren.
#    2. rechtstreeks downloaden - werkt zonder installatie en dus ook op
#       een machine waar je niets mag installeren. Dit is het vangnet en
#       daarmee de weg die altijd werkt.
#
#  Gebruik:
#      .\Bijwerken.ps1                  normaal
#      .\Bijwerken.ps1 -AlleenKijken    kijken en melden, niets vervangen
#      .\Bijwerken.ps1 -Nu              ook ophalen als de versie gelijk is
# ---------------------------------------------------------------------
param(
    [string]$Map          = '',
    [string]$Eigenaar     = 'RMoria',
    [string]$RepoNaam     = 'X265-Converter',
    [switch]$Stil,
    [switch]$Nu,
    [switch]$AlleenKijken,
    [switch]$GeenGit
)

$ErrorActionPreference = 'Continue'

if (-not $Map) {
    $Map = $PSScriptRoot
    if (-not $Map) { $Map = Split-Path -Parent $MyInvocation.MyCommand.Definition }
}

# Windows PowerShell 5.1 praat zonder dit soms nog TLS 1.0, en dat weigert
# GitHub al jaren. Zonder deze regel mislukt elke download met een
# nietszeggende foutmelding over de onderliggende verbinding.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# Zit er een bedrijfsproxy tussen, dan moet die de aanmelding van de
# ingelogde gebruiker meekrijgen. Zonder dit komt er een 407 terug en
# lijkt het alsof GitHub onbereikbaar is.
try {
    $pr = [System.Net.WebRequest]::GetSystemWebProxy()
    $pr.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    [System.Net.WebRequest]::DefaultWebProxy = $pr
} catch { }

# Welke bestanden meegaan. De .cmd staat er bewust apart in: die wordt
# nooit rechtstreeks overschreven (zie Plaats-Nieuw).
$script:Bestanden = @('X265-Converter.ps1', 'LEESMIJ-X265-Converter.md', 'Bijwerken.ps1')
$script:CmdNaam   = 'X265-Converter.cmd'

# ---------------------------------------------------------------------
#  Alles ook naar een logboek
#
#  Dit is geen luxe. De updater draait vanuit de starter, in een venster
#  dat binnen een seconde dichtklapt. Zonder logboek is er geen enkel
#  verschil te zien tussen "niets te doen", "kon er niet bij" en "is
#  helemaal niet gedraaid" - en dan is er ook niets aan te repareren.
# ---------------------------------------------------------------------
$script:LogPad = ''
try {
    $script:LogPad = Join-Path $Map 'X265-Bijwerken.log'
    # Past er niets in de programmamap, dan naar de profielmap.
    $probe = Join-Path $Map ('.upd_' + [guid]::NewGuid().ToString('N') + '.tmp')
    Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
}
catch {
    try {
        $alt = Join-Path $env:LOCALAPPDATA 'X265-Converter'
        if (-not (Test-Path -LiteralPath $alt)) { New-Item -ItemType Directory -Path $alt -Force | Out-Null }
        $script:LogPad = Join-Path $alt 'X265-Bijwerken.log'
    }
    catch { $script:LogPad = '' }
}

function Schrijf {
    param([string]$Tekst, [string]$Kleur = 'Gray')

    if (-not $Stil) { Write-Host $Tekst -ForegroundColor $Kleur }

    if ($script:LogPad) {
        try {
            # Niet laten aangroeien tot in het oneindige.
            if (Test-Path -LiteralPath $script:LogPad) {
                $g = (Get-Item -LiteralPath $script:LogPad).Length
                if ($g -gt 200000) {
                    $houd = @(Get-Content -LiteralPath $script:LogPad -Tail 300)
                    Set-Content -LiteralPath $script:LogPad -Value $houd -Encoding UTF8
                }
            }
            Add-Content -LiteralPath $script:LogPad -Encoding UTF8 `
                -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Tekst)
        }
        catch { }
    }
}

# ---------------------------------------------------------------------
#  Versies
# ---------------------------------------------------------------------
function Get-VersieUitScript {
    param([string]$Pad)

    if (-not (Test-Path -LiteralPath $Pad)) { return $null }
    try {
        # Alleen de kop lezen; het bestand is 300 kB en het versienummer
        # staat in de eerste regels.
        $kop = (Get-Content -LiteralPath $Pad -TotalCount 120 -ErrorAction Stop) -join "`n"
    }
    catch { return $null }

    if ($kop -match "(?m)^\s*\`$AppVersion\s*=\s*'([^']+)'") {
        try { return [version]$Matches[1] } catch { return $null }
    }
    return $null
}

function ConvertTo-Versie {
    param([string]$Tag)
    if ([string]::IsNullOrWhiteSpace($Tag)) { return $null }
    $t = $Tag.Trim()
    if ($t.StartsWith('refs/tags/')) { $t = $t.Substring(10) }
    $t = $t.TrimEnd('^{}')
    if ($t -match '^[vV](.+)$') { $t = $Matches[1] }
    if ($t -notmatch '^\d+(\.\d+){0,3}$') { return $null }
    try { return [version]$t } catch { return $null }
}

function Get-HoogsteTag {
    param([string[]]$Tags)
    $beste = $null
    $besteTekst = ''
    foreach ($t in $Tags) {
        $v = ConvertTo-Versie $t
        if ($v -eq $null) { continue }
        if ($beste -eq $null -or $v -gt $beste) { $beste = $v; $besteTekst = $t.Trim() }
    }
    if ($beste -eq $null) { return $null }
    if ($besteTekst -match '^refs/tags/(.+?)(\^\{\})?$') { $besteTekst = $Matches[1] }
    return [pscustomobject]@{ Versie = $beste; Tag = $besteTekst }
}

# ---------------------------------------------------------------------
#  Draait er al een instantie?
#
#  Zo ja: afblijven. Het draaiende programma kan zichzelf herstarten
#  (bijvoorbeeld bij een tweede aanroep met -In), en dan zou het halverwege
#  op een ander script uitkomen dan waarmee het begon.
# ---------------------------------------------------------------------
function Test-DraaitAl {
    try {
        $m = $null
        if ([System.Threading.Mutex]::TryOpenExisting('Local\X265Converter.SingleInstance', [ref]$m)) {
            if ($m) { $m.Dispose() }
            return $true
        }
        return $false
    }
    catch { return $false }
}

# ---------------------------------------------------------------------
#  git opzoeken en zo nodig installeren
# ---------------------------------------------------------------------
function Get-GitPad {

    $c = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }

    # Op de gebruikelijke plekken kijken. Elke basis apart nakijken: op een
    # machine zonder ProgramFiles(x86) is die omgevingsvariabele leeg, en
    # Join-Path met een lege basis gooit een fout die anders de hele
    # updater zou omvergooien.
    foreach ($basis in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ([string]::IsNullOrWhiteSpace($basis)) { continue }
        foreach ($staart in @('Git\cmd\git.exe', 'Programs\Git\cmd\git.exe')) {
            try {
                $p = Join-Path $basis $staart
                if (Test-Path -LiteralPath $p) { return $p }
            }
            catch { }
        }
    }
    return ''
}

function Install-Git {
    $w = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $w) {
        Schrijf 'git en winget ontbreken allebei; er wordt rechtstreeks gedownload.' 'DarkGray'
        return ''
    }

    Schrijf 'git ontbreekt; eenmalig installeren via winget…' 'Yellow'
    # Eerst voor deze gebruiker: dat vraagt geen beheerdersrechten. Lukt dat
    # niet, dan de gewone installatie - die kan wel om toestemming vragen.
    foreach ($extra in @(@('--scope','user'), @())) {
        $args = @('install','--id','Git.Git','-e','--source','winget','--silent',
                  '--accept-package-agreements','--accept-source-agreements') + $extra
        try { & $w.Source @args 2>&1 | Out-Null } catch { }
        $g = Get-GitPad
        if ($g) { Schrijf "git geïnstalleerd: $g" 'Green'; return $g }
    }
    Schrijf 'Installeren van git is niet gelukt; er wordt rechtstreeks gedownload.' 'DarkGray'
    return ''
}

# ---------------------------------------------------------------------
#  Welke tags zijn er?
# ---------------------------------------------------------------------
function Get-TagsViaGit {
    param([string]$Git, [string]$Url)
    try {
        $uit = & $Git ls-remote --tags $Url 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        $tags = @()
        foreach ($regel in @($uit)) {
            $d = ([string]$regel) -split "`t"
            if ($d.Count -ge 2) { $tags += $d[1] }
        }
        return $tags
    }
    catch { return @() }
}

function Get-TagsViaWeb {
    param([string]$Eigenaar, [string]$RepoNaam)
    try {
        $u = "https://api.github.com/repos/$Eigenaar/$RepoNaam/tags"
        $r = Invoke-RestMethod -Uri $u -Headers @{ 'User-Agent' = 'X265-Converter' } `
                               -TimeoutSec 20 -ErrorAction Stop
        return @($r | ForEach-Object { [string]$_.name })
    }
    catch { return @() }
}

function Test-TagBestaat {
    param([string]$Eigenaar, [string]$RepoNaam, [string]$Tag)
    # Bestaat de tag, dan bestaat het bestand; bestaat hij niet, dan geeft
    # raw.githubusercontent een 404. Klein bestand, dus goedkoop.
    try {
        $u = "https://raw.githubusercontent.com/$Eigenaar/$RepoNaam/$Tag/README.md"
        [void](Invoke-WebRequest -Uri $u -Method Head -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop)
        return $true
    }
    catch { return $false }
}

function Get-TagViaAftellen {
    param([string]$Eigenaar, [string]$RepoNaam, [version]$Vanaf)

    # Laatste redmiddel, als git ontbreekt EN de GitHub-API onbereikbaar is
    # (een bedrijfsproxy die alleen raw.githubusercontent doorlaat, bijv.).
    # Dan vragen we niet WELKE tags er zijn, maar of een bepaalde tag
    # bestaat - en dat kan wel over raw. Van de huidige versie af omhoog
    # tellen, hoogstens een handvol keer.
    if ($Vanaf -eq $null) { return $null }

    $beste = $null
    $besteTag = ''
    $minor = $Vanaf.Minor
    for ($n = 1; $n -le 5; $n++) {
        $kandidaat = 'v{0}.{1}' -f $Vanaf.Major, ($minor + $n)
        if (Test-TagBestaat -Eigenaar $Eigenaar -RepoNaam $RepoNaam -Tag $kandidaat) {
            $beste = ConvertTo-Versie $kandidaat
            $besteTag = $kandidaat
            $minor = $minor + $n
            $n = 0          # doorzoeken vanaf de nieuwe stand
        }
    }
    $volgendeMajor = 'v{0}.0' -f ($Vanaf.Major + 1)
    if (Test-TagBestaat -Eigenaar $Eigenaar -RepoNaam $RepoNaam -Tag $volgendeMajor) {
        $beste = ConvertTo-Versie $volgendeMajor
        $besteTag = $volgendeMajor
    }

    if ($beste -eq $null) { return $null }
    return [pscustomobject]@{ Versie = $beste; Tag = $besteTag }
}

# ---------------------------------------------------------------------
#  Bestanden ophalen naar een tijdelijke map
# ---------------------------------------------------------------------
function Get-ViaGit {
    param([string]$Git, [string]$Url, [string]$Tag, [string]$Tijdelijk)
    try {
        $uit = & $Git clone --depth 1 --branch $Tag --quiet $Url $Tijdelijk 2>&1
        if ($LASTEXITCODE -ne 0) {
            Schrijf ("git clone mislukte: {0}" -f (($uit | Select-Object -First 3) -join ' ')) 'DarkGray'
            return $false
        }
        return $true
    }
    catch { return $false }
}

function Get-ViaWeb {
    param([string]$Eigenaar, [string]$RepoNaam, [string]$Tag, [string]$Tijdelijk)
    try { New-Item -ItemType Directory -Path $Tijdelijk -Force -ErrorAction Stop | Out-Null }
    catch { return $false }

    # Alleen het hoofdscript is verplicht. De rest is meegenomen: een
    # bijbestand dat in die versie nog niet bestond (of er inmiddels uit
    # is) mag het bijwerken niet tegenhouden. Wat er niet is, wordt
    # gewoon niet vervangen - Plaats-Nieuw slaat ontbrekende bestanden
    # over.
    $hoofdOk = $false
    foreach ($b in ($script:Bestanden + $script:CmdNaam)) {
        $u = "https://raw.githubusercontent.com/$Eigenaar/$RepoNaam/$Tag/$b"
        $d = Join-Path $Tijdelijk $b
        try {
            Invoke-WebRequest -Uri $u -OutFile $d -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
            if ($b -eq 'X265-Converter.ps1') { $hoofdOk = $true }
        }
        catch {
            if ($b -eq 'X265-Converter.ps1') {
                Schrijf ("Downloaden van {0} mislukte: {1}" -f $b, $_.Exception.Message) 'Yellow'
            }
            else {
                Schrijf ("{0} zit niet in deze versie; overgeslagen." -f $b) 'DarkGray'
            }
            try { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Force } } catch { }
        }
    }
    return $hoofdOk
}

# ---------------------------------------------------------------------
#  Is wat er binnenkwam bruikbaar?
#
#  Dit is de belangrijkste controle van het hele script. Een half
#  binnengekomen download die over een werkende versie heen wordt gezet
#  is erger dan helemaal niet bijwerken.
# ---------------------------------------------------------------------
function Test-Binnengekomen {
    param([string]$Tijdelijk, [version]$Verwacht)

    $hoofd = Join-Path $Tijdelijk 'X265-Converter.ps1'
    if (-not (Test-Path -LiteralPath $hoofd)) { return 'X265-Converter.ps1 ontbreekt' }

    $lengte = 0
    try { $lengte = (Get-Item -LiteralPath $hoofd).Length } catch { }
    if ($lengte -lt 100000) { return "X265-Converter.ps1 is maar $lengte bytes; dat kan niet kloppen" }

    $v = Get-VersieUitScript $hoofd
    if ($v -eq $null) { return 'in het opgehaalde script staat geen versienummer' }
    if ($Verwacht -ne $null -and $v -ne $Verwacht) {
        return "het opgehaalde script zegt $v maar de tag beloofde $Verwacht"
    }

    # Parseren. Vangt een afgekapte download die toch groot genoeg is.
    try {
        $fouten = $null
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($hoofd, [ref]$tokens, [ref]$fouten)
        if ($fouten -and $fouten.Count -gt 0) {
            return ("het opgehaalde script bevat {0} syntaxfout(en)" -f $fouten.Count)
        }
    }
    catch { return "het opgehaalde script kon niet worden gecontroleerd: $($_.Exception.Message)" }

    return ''
}

# ---------------------------------------------------------------------
#  Op zijn plek zetten
#
#  De .cmd wordt NOOIT rechtstreeks overschreven. cmd.exe leest een
#  batchbestand niet in een keer in maar onthoudt een bytepositie en leest
#  na elke regel verder. Vervang je het tijdens het draaien, dan gaat cmd
#  op die oude positie verder in de NIEUWE inhoud en voert half afgekapte
#  regels uit. De nieuwe versie wordt daarom als .nieuw klaargezet; de
#  starter wisselt hem bij de volgende start om, voordat hij iets anders
#  doet.
# ---------------------------------------------------------------------
function Plaats-Nieuw {
    param([string]$Tijdelijk, [string]$Doel, [version]$Versie)

    $backup = Join-Path $Doel ('vorige-versie')
    try { New-Item -ItemType Directory -Path $backup -Force -ErrorAction Stop | Out-Null }
    catch { return "kon geen map voor de vorige versie maken: $($_.Exception.Message)" }

    $gezet = @()
    foreach ($b in $script:Bestanden) {
        $bron = Join-Path $Tijdelijk $b
        if (-not (Test-Path -LiteralPath $bron)) { continue }
        $doelPad = Join-Path $Doel $b
        try {
            if (Test-Path -LiteralPath $doelPad) {
                Copy-Item -LiteralPath $doelPad -Destination (Join-Path $backup $b) -Force -ErrorAction Stop
            }
            Copy-Item -LiteralPath $bron -Destination $doelPad -Force -ErrorAction Stop
            $gezet += $b
        }
        catch {
            # Terugrollen wat er al stond, anders blijft er een mengsel van
            # twee versies achter.
            foreach ($g in $gezet) {
                $terug = Join-Path $backup $g
                if (Test-Path -LiteralPath $terug) {
                    try { Copy-Item -LiteralPath $terug -Destination (Join-Path $Doel $g) -Force } catch { }
                }
            }
            return "vervangen van $b mislukte: $($_.Exception.Message); de vorige versie is teruggezet"
        }
    }

    # De starter apart: alleen klaarzetten als hij echt anders is.
    $cmdBron = Join-Path $Tijdelijk $script:CmdNaam
    $cmdDoel = Join-Path $Doel $script:CmdNaam
    if (Test-Path -LiteralPath $cmdBron) {
        $anders = $true
        try {
            if (Test-Path -LiteralPath $cmdDoel) {
                $a = (Get-FileHash -LiteralPath $cmdBron -Algorithm SHA256).Hash
                $b2 = (Get-FileHash -LiteralPath $cmdDoel -Algorithm SHA256).Hash
                $anders = ($a -ne $b2)
            }
        } catch { }
        if ($anders) {
            try {
                Copy-Item -LiteralPath $cmdBron -Destination ($cmdDoel + '.nieuw') -Force -ErrorAction Stop
                Schrijf 'De starter is vernieuwd; die wordt bij de volgende start omgewisseld.' 'Yellow'
            } catch { }
        }
    }

    Schrijf ("Bijgewerkt naar versie {0}: {1}" -f $Versie, ($gezet -join ', ')) 'Green'
    return ''
}

# ---------------------------------------------------------------------
#  Hoofdlijn
# ---------------------------------------------------------------------
function Invoke-Bijwerken {

    Schrijf ('--- bijwerken gestart in {0} ---' -f $Map) 'DarkGray'

    $hoofdPad = Join-Path $Map 'X265-Converter.ps1'
    $lokaal   = Get-VersieUitScript $hoofdPad
    if ($lokaal -eq $null) {
        Schrijf 'Geen lokale versie gevonden; bijwerken wordt overgeslagen.' 'DarkGray'
        return $false
    }

    if (-not $AlleenKijken -and (Test-DraaitAl)) {
        Schrijf 'Er draait al een instantie; bijwerken wordt overgeslagen.' 'DarkGray'
        return $false
    }

    $url = "https://github.com/$Eigenaar/$RepoNaam.git"

    $git = ''
    if (-not $GeenGit) {
        $git = Get-GitPad
        if (-not $git) { $git = Install-Git }
    }

    $tags = @()
    if ($git) { $tags = Get-TagsViaGit -Git $git -Url $url }
    if ($tags.Count -lt 1) { $tags = Get-TagsViaWeb -Eigenaar $Eigenaar -RepoNaam $RepoNaam }

    $nieuwste = $null
    if ($tags.Count -gt 0) { $nieuwste = Get-HoogsteTag $tags }

    if ($nieuwste -eq $null) {
        # Geen tagoverzicht te krijgen. Dan maar omhoog tellen vanaf wat we
        # nu hebben en per kandidaat vragen of hij bestaat.
        $nieuwste = Get-TagViaAftellen -Eigenaar $Eigenaar -RepoNaam $RepoNaam -Vanaf $lokaal
    }

    if ($nieuwste -eq $null) {
        Schrijf ("Geen nieuwere versie gevonden; versie {0} blijft staan." -f $lokaal) 'DarkGray'
        return $false
    }

    if (-not $Nu -and $nieuwste.Versie -le $lokaal) {
        Schrijf ("Versie {0} is de nieuwste." -f $lokaal) 'DarkGray'
        return $false
    }

    Schrijf ("Versie {0} beschikbaar (nu {1})." -f $nieuwste.Versie, $lokaal) 'Cyan'
    if ($AlleenKijken) { return $true }

    $tijdelijk = Join-Path ([IO.Path]::GetTempPath()) ('x265upd_' + [guid]::NewGuid().ToString('N'))
    try {
        $gelukt = $false
        if ($git) { $gelukt = Get-ViaGit -Git $git -Url $url -Tag $nieuwste.Tag -Tijdelijk $tijdelijk }
        if (-not $gelukt) {
            if (Test-Path -LiteralPath $tijdelijk) { Remove-Item -LiteralPath $tijdelijk -Recurse -Force -ErrorAction SilentlyContinue }
            $gelukt = Get-ViaWeb -Eigenaar $Eigenaar -RepoNaam $RepoNaam -Tag $nieuwste.Tag -Tijdelijk $tijdelijk
        }
        if (-not $gelukt) {
            Schrijf 'Ophalen is niet gelukt; er wordt gestart met wat er staat.' 'Yellow'
            return $false
        }

        $klacht = Test-Binnengekomen -Tijdelijk $tijdelijk -Verwacht $nieuwste.Versie
        if ($klacht) {
            Schrijf ("Niet bijgewerkt: {0}. De huidige versie blijft staan." -f $klacht) 'Red'
            return $false
        }

        $klacht = Plaats-Nieuw -Tijdelijk $tijdelijk -Doel $Map -Versie $nieuwste.Versie
        if ($klacht) { Schrijf $klacht 'Red'; return $false }
        return $true
    }
    finally {
        if (Test-Path -LiteralPath $tijdelijk) {
            Remove-Item -LiteralPath $tijdelijk -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Niet uitvoeren als dit bestand alleen wordt ingeladen om de functies te
# kunnen testen.
if (-not $env:X265_BIJWERKEN_ALLEEN_LADEN) {
    try {
        $veranderd = Invoke-Bijwerken
        if ($veranderd) { Schrijf 'Klaar: er is bijgewerkt.' 'Green' }
        else            { Schrijf 'Klaar: er is niets veranderd.' 'DarkGray' }
    }
    catch {
        # Bijwerken mag NOOIT het starten in de weg zitten. Wat hier ook
        # misgaat, het wordt opgeschreven en daarna gaat het programma
        # gewoon door met de versie die er staat.
        Schrijf ("Bijwerken liep vast: {0}" -f $_.Exception.Message) 'Red'
        try { Schrijf ($_.ScriptStackTrace) 'DarkGray' } catch { }
    }
}
