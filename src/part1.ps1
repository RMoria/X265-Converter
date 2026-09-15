<#
=====================================================================
  VIDEO  ->  H.265 / HEVC  BATCH CONVERTER   (PowerShell + WPF GUI)
=====================================================================

  Opvolger van convert.bat - één PowerShell-script met een grafische
  interface, meerdere bronmappen (incl. UNC), een herschikbare
  wachtrij, pauze/hervat, stop (direct of na huidige), live
  statistieken, cumulatieve totalen en een tijdsindicatie.

  Werkwijze per bestand:
    1. ffprobe: is het een videobestand, welke codec, hoe lang
    2. ffmpeg : encode naar de werkmap (standaard %TEMP%)
    3. verplaats het eindbestand naar de bronmap
    4. ondertitels meenemen naar de nieuwe naam
    5. pas na een geslaagde verplaatsing: origineel verwijderen

  Dubbelklikken: X265-Converter.cmd (de enige starter).

  Auteur : gegenereerd voor Rob Moria / 4-Rest
=====================================================================
#>

[CmdletBinding()]
param(
    # Bronmappen die bij het opstarten moeten worden toegevoegd.
    [string[]]$Path,

    # Wordt door X265-Converter.cmd meegegeven. Betekent: dit proces
    # heeft een consolevenster geërfd, dus meteen opnieuw starten als
    # proces ZONDER console en deze instantie afsluiten.
    [switch]$FromLauncher,

    # Aanroep vanuit een ander script of programma: één bestand omzetten.
    # -In is het volledige pad van de bron.
    [string]$In,

    # Het volledige pad van het resultaat. Dit wordt LETTERLIJK gebruikt:
    # er wordt geen '.x265' achter geplakt en er komt geen '(2)' bij als
    # het al bestaat. Wie het pad zelf opgeeft, krijgt precies dat pad.
    # Weggelaten? Dan gaat het resultaat als <naam>.x265.mkv naast de bron.
    #
    # Draait er al een instantie, dan wordt de opdracht daaraan doorgegeven
    # (achteraan de wachtrij) en sluit deze aanroep zichzelf meteen af.
    [string]$Out,

    # Bijwerken naar de nieuwste uitgebrachte versie op GitHub en daarna
    # meteen stoppen. Wordt door X265-Converter.cmd aangeroepen vlak voor
    # het echte starten. Er komt hierbij geen venster in beeld.
    [switch]$Bijwerken,

    # Bij -Bijwerken: wel kijken en vertellen, maar niets vervangen.
    [switch]$AlleenKijken,

    # Bij -Bijwerken: ophalen ook als je al op dezelfde versie zit.
    [switch]$Opnieuw,

    # Bij -Bijwerken: niets op het scherm, alleen in het logboek.
    [switch]$Stil,

    # Bij -Bijwerken: git overslaan en meteen rechtstreeks downloaden.
    [switch]$GeenGit
)

# ---------------------------------------------------------------------
#  Versie
#
#  Staat hier bovenaan zodat het vangnet hieronder hem ook in het
#  foutenlogboek kan zetten: bij een melding is het eerste wat je wilt
#  weten welke versie er draaide.
#
#  Ophogen bij elke oplevering. Tweede cijfer erbij voor nieuw gedrag,
#  derde cijfer voor een reparatie. De wijzigingen per versie staan in
#  LEESMIJ-X265-Converter.md.
# ---------------------------------------------------------------------
$AppName    = 'X265 Converter'
$AppVersion = '1.8'
$AppDate    = '2026-09-15'
$AppTitle   = 'Video naar H.265 / HEVC'
$AppStamp   = ('{0} {1} ({2})' -f $AppName, $AppVersion, $AppDate)


# ---------------------------------------------------------------------
# ==== BIJWERKEN BEGIN ====
#
#     Zichzelf bijwerken vanaf de laatste release-tag op GitHub. Dit zat
#     eerder in een los Bijwerken.ps1, maar dat bleek precies de valkuil:
#     bij het handmatig overzetten naar een tweede pc ging dat bestand
#     niet mee, en dan werkt er niets bij zonder dat iemand dat merkt.
#     Alles in EEN bestand houden is hier geen schoonheidsideaal maar een
#     voorwaarde om het betrouwbaar te krijgen.
#
#     Draait als aparte aanroep vanuit X265-Converter.cmd:
#         X265-Converter.ps1 -Bijwerken
#     en keert daarna meteen terug - er komt hier dus geen venster, geen
#     Add-Type en geen WPF aan te pas.
# ---------------------------------------------------------------------

$UpdEigenaar = 'RMoria'
$UpdRepoNaam = 'X265-Converter'

$UpdMap = $PSScriptRoot
if ([string]::IsNullOrEmpty($UpdMap)) { $UpdMap = Split-Path -Parent $MyInvocation.MyCommand.Definition }

$script:Bestanden = @('X265-Converter.ps1', 'LEESMIJ-X265-Converter.md')
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
    $script:LogPad = Join-Path $UpdMap 'X265-Bijwerken.log'
    # Past er niets in de programmamap, dan naar de profielmap.
    $probe = Join-Path $UpdMap ('.upd_' + [guid]::NewGuid().ToString('N') + '.tmp')
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

    Schrijf ('--- bijwerken gestart in {0} ---' -f $UpdMap) 'DarkGray'

    $hoofdPad = Join-Path $UpdMap 'X265-Converter.ps1'
    $lokaal   = Get-VersieUitScript $hoofdPad
    if ($lokaal -eq $null) {
        Schrijf 'Geen lokale versie gevonden; bijwerken wordt overgeslagen.' 'DarkGray'
        return $false
    }

    if (-not $AlleenKijken -and (Test-DraaitAl)) {
        Schrijf 'Er draait al een instantie; bijwerken wordt overgeslagen.' 'DarkGray'
        return $false
    }

    $url = "https://github.com/$UpdEigenaar/$UpdRepoNaam.git"

    $git = ''
    if (-not $GeenGit) {
        $git = Get-GitPad
        if (-not $git) { $git = Install-Git }
    }

    $tags = @()
    if ($git) { $tags = Get-TagsViaGit -Git $git -Url $url }
    if ($tags.Count -lt 1) { $tags = Get-TagsViaWeb -Eigenaar $UpdEigenaar -RepoNaam $UpdRepoNaam }

    $nieuwste = $null
    if ($tags.Count -gt 0) { $nieuwste = Get-HoogsteTag $tags }

    if ($nieuwste -eq $null) {
        # Geen tagoverzicht te krijgen. Dan maar omhoog tellen vanaf wat we
        # nu hebben en per kandidaat vragen of hij bestaat.
        $nieuwste = Get-TagViaAftellen -Eigenaar $UpdEigenaar -RepoNaam $UpdRepoNaam -Vanaf $lokaal
    }

    if ($nieuwste -eq $null) {
        Schrijf ("Geen nieuwere versie gevonden; versie {0} blijft staan." -f $lokaal) 'DarkGray'
        return $false
    }

    if (-not $Opnieuw -and $nieuwste.Versie -le $lokaal) {
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
            $gelukt = Get-ViaWeb -Eigenaar $UpdEigenaar -RepoNaam $UpdRepoNaam -Tag $nieuwste.Tag -Tijdelijk $tijdelijk
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

        $klacht = Plaats-Nieuw -Tijdelijk $tijdelijk -Doel $UpdMap -Versie $nieuwste.Versie
        if ($klacht) { Schrijf $klacht 'Red'; return $false }
        return $true
    }
    finally {
        if (Test-Path -LiteralPath $tijdelijk) {
            Remove-Item -LiteralPath $tijdelijk -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


if ($Bijwerken) {

    # Windows PowerShell 5.1 praat zonder dit soms nog TLS 1.0, en dat
    # weigert GitHub al jaren. Zonder deze regel mislukt elke download met
    # een nietszeggende foutmelding over de onderliggende verbinding.
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
    return
}
# ==== BIJWERKEN EIND ====

# ---------------------------------------------------------------------
# 0a. Opnieuw starten zonder consolevenster
#
#     Dit is de oplossing voor het venster dat bleef staan. Eerder werd
#     het venster achteraf verborgen (-WindowStyle Hidden en ShowWindow),
#     maar dat werkt niet wanneer Windows Terminal de standaard terminal
#     is: dat venster is niet van conhost en trekt zich van ShowWindow
#     niets aan. Daarom wordt er nu voor het proces dat blijft leven
#     helemaal GEEN console meer aangemaakt: CreateNoWindow op een verse
#     ProcessStartInfo. De zichtbare instantie doet niets anders dan die
#     hidden instantie starten en zichzelf beëindigen.
#
#     Dit blok staat opzettelijk vóór alle Add-Type-aanroepen, zodat de
#     zichtbare instantie zo kort mogelijk leeft.
# ---------------------------------------------------------------------

function Get-RelaunchArguments {
    param([string]$ScriptPath, [string[]]$Folders, [string]$InFile = '', [string]$OutFile = '')

    $cmd = "& '" + ($ScriptPath -replace "'", "''") + "'"
    if ($Folders) {
        $q = @()
        foreach ($f in $Folders) { $q += ("'" + ($f -replace "'", "''") + "'") }
        if ($q.Count -gt 0) { $cmd = $cmd + ' -Path ' + ($q -join ',') }
    }

    # -In en -Out moeten mee naar de instantie die blijft leven, anders
    # gaat de opdracht van een aanroepend programma verloren op het moment
    # dat het script zichzelf zonder console herstart.
    if (-not [string]::IsNullOrWhiteSpace($InFile)) {
        $cmd = $cmd + " -In '" + ($InFile -replace "'", "''") + "'"
        if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
            $cmd = $cmd + " -Out '" + ($OutFile -replace "'", "''") + "'"
        }
    }
    return ('-NoProfile -ExecutionPolicy Bypass -STA -Command "' + $cmd + '"')
}

if ($FromLauncher) {

    $self = $PSCommandPath
    if ([string]::IsNullOrEmpty($self)) { $self = $MyInvocation.MyCommand.Definition }

    $hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $hostExe)) { $hostExe = 'powershell.exe' }

    # Argumenten opbouwen. Geef GEEN -FromLauncher mee, anders blijft het
    # zichzelf herstarten.
    #
    # Let op: met -File kan een array niet worden doorgegeven; een tweede
    # -Path geeft dan "parameter specified more than once". Daarom -Command
    # met PowerShell-notatie, waarin enkele aanhalingstekens verdubbeld
    # worden.
    $argLine = Get-RelaunchArguments -ScriptPath $self -Folders $Path -InFile $In -OutFile $Out

    $relaunched = $false
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = $hostExe
        $psi.Arguments       = $argLine
        $psi.UseShellExecute = $false     # vereist voor CreateNoWindow
        $psi.CreateNoWindow  = $true      # <- hierdoor komt er geen console
        try { $psi.WorkingDirectory = (Split-Path -Parent $self) } catch { }

        [void][System.Diagnostics.Process]::Start($psi)
        $relaunched = $true
    }
    catch {
        Write-Host "Kon de verborgen instantie niet starten: $($_.Exception.Message)"
        Write-Host 'Het programma gaat verder in dit venster.'
        Start-Sleep -Seconds 2
    }

    if ($relaunched) { return }
    # anders: gewoon doorgaan in deze (zichtbare) instantie
}

# ---------------------------------------------------------------------
# 0b. STA-controle  (WPF vereist een Single Threaded Apartment)
#
#     Windows PowerShell 5.1 start standaard al in STA en de starter
#     geeft -STA expliciet mee; dit is het vangnet voor het geval het
#     script vanuit een MTA-host wordt aangeroepen.
# ---------------------------------------------------------------------

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {

    $self = $PSCommandPath
    if ([string]::IsNullOrEmpty($self)) { $self = $MyInvocation.MyCommand.Definition }

    $hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $hostExe)) { $hostExe = 'powershell.exe' }

    $argLine = Get-RelaunchArguments -ScriptPath $self -Folders $Path -InFile $In -OutFile $Out

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = $hostExe
        $psi.Arguments       = $argLine
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        [void][System.Diagnostics.Process]::Start($psi)
    }
    catch {
        # Niet stil weglopen: zonder venster en zonder melding zou het
        # programma gewoon lijken te verdwijnen.
        $detail = "Opnieuw starten in STA is mislukt: $($_.Exception.Message)"
        $lg = Get-ErrorLogPath
        if ($lg) { try { Add-Content -LiteralPath $lg -Value ((Get-Date -Format 's') + '  ' + $AppStamp + '  ' + $detail) -Encoding UTF8 } catch { } }
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            [void][System.Windows.Forms.MessageBox]::Show($detail, 'X265 Converter')
        } catch { Write-Host $detail }
    }

    return
}

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------
# 1.  Assemblies
# ---------------------------------------------------------------------

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------
#  Waar kan het foutenlogboek heen?
#
#  Naast het script, maar op een beheerde machine is die map vaak
#  alleen-lezen. Dan wijken we uit naar de profielmap. Dit staat hier
#  omdat het vangnet hieronder al moet werken voordat de rest van het
#  script is ingelezen.
# ---------------------------------------------------------------------
function Get-ErrorLogPath {
    $kandidaten = @()
    if (-not [string]::IsNullOrEmpty($PSScriptRoot)) { $kandidaten += $PSScriptRoot }
    if ($env:LOCALAPPDATA) { $kandidaten += (Join-Path $env:LOCALAPPDATA 'X265-Converter') }
    if ($env:TEMP)         { $kandidaten += (Join-Path $env:TEMP 'X265-Converter') }
    $kandidaten += $env:TEMP

    foreach ($d in $kandidaten) {
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $d -PathType Container -ErrorAction Stop)) {
                New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
            }
            $f = Join-Path $d 'X265-Converter.error.log'
            Add-Content -LiteralPath $f -Value '' -ErrorAction Stop
            return $f
        }
        catch { continue }
    }
    return $null
}

# ---------------------------------------------------------------------
# 1b. Vangnet: onverwachte fouten zichtbaar maken
#     (de console is verborgen, dus zonder dit zou het venster
#      geruisloos verdwijnen)
# ---------------------------------------------------------------------

trap {
    $detail = "$($_.Exception.GetType().Name): $($_.Exception.Message)`r`n`r`n$($_.InvocationInfo.PositionMessage)`r`n`r`n$($_.ScriptStackTrace)"
    $lg = Get-ErrorLogPath
    $kop = ('{0}   {1}' -f $AppStamp, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    if ($lg) { try { Set-Content -LiteralPath $lg -Value ($kop + "`r`n`r`n" + $detail) -Encoding UTF8 -Force } catch { } }
    try {
        [System.Windows.MessageBox]::Show(
            ("Er is een onverwachte fout opgetreden. Het venster wordt gesloten." +
             $(if ($lg) { "`r`nLogboek: $lg" } else { '' }) + "`r`n`r`n$detail"),
            'X265 Converter - fout', 'OK', 'Error') | Out-Null
    } catch { }
    break
}

# ---------------------------------------------------------------------
# 2.  Hulptypes  (C#)
# ---------------------------------------------------------------------

if (-not ('X265.NativeProc' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace X265
{
    public static class NativeProc
    {
        [DllImport("ntdll.dll", SetLastError = true)]
        private static extern uint NtSuspendProcess(IntPtr processHandle);

        [DllImport("ntdll.dll", SetLastError = true)]
        private static extern uint NtResumeProcess(IntPtr processHandle);

        public static bool Suspend(IntPtr h)
        {
            try { return NtSuspendProcess(h) == 0; } catch { return false; }
        }

        public static bool Resume(IntPtr h)
        {
            try { return NtResumeProcess(h) == 0; } catch { return false; }
        }

    }
}
'@
}


# ---------------------------------------------------------------------
# 2b. Moderne mapkiezer (Explorer-dialoog met adresbalk, UNC en
#     meervoudige selectie).  Valt terug op de oude dialoog als de
#     COM-interop om welke reden dan ook faalt.
# ---------------------------------------------------------------------

if (-not ('X265.FolderPicker' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace X265
{
    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [ComImport, Guid("B63EA76D-1F85-456F-A19C-48159EFA858B"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItemArray
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppvOut);
        void GetPropertyStore(int flags, ref Guid riid, out IntPtr ppv);
        void GetPropertyDescriptionList(IntPtr keyType, ref Guid riid, out IntPtr ppv);
        void GetAttributes(int dwAttribFlags, uint sfgaoMask, out uint psfgaoAttribs);
        void GetCount(out uint pdwNumItems);
        void GetItemAt(uint dwIndex, out IShellItem ppsi);
        void EnumItems(out IntPtr ppenumShellItems);
    }

    // BELANGRIJK: de COM-interoplaag neemt de methoden van een basis-
    // interface NIET mee in de vtable. Alle methoden van IModalWindow en
    // IFileDialog moeten daarom hier letterlijk herhaald worden, in
    // precies dezelfde volgorde, voordat GetResults/GetSelectedItems
    // op de juiste slots terechtkomen.
    [ComImport, Guid("D57C7288-D4AD-4768-BE02-9D969532D960"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFileOpenDialog
    {
        // --- IModalWindow ---
        [PreserveSig] int Show(IntPtr hwndOwner);
        // --- IFileDialog ---
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, int fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);
        // --- IFileOpenDialog ---
        void GetResults(out IShellItemArray ppenum);
        void GetSelectedItems(out IShellItemArray ppsai);
    }

    [ComImport, ClassInterface(ClassInterfaceType.None),
     Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    internal class FileOpenDialogRcw { }

    public static class FolderPicker
    {
        private const uint FOS_PICKFOLDERS      = 0x00000020;
        private const uint FOS_FORCEFILESYSTEM  = 0x00000040;
        private const uint FOS_ALLOWMULTISELECT = 0x00000200;
        private const uint FOS_PATHMUSTEXIST    = 0x00000800;
        private const uint SIGDN_FILESYSPATH    = 0x80058000;

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(
            [MarshalAs(UnmanagedType.LPWStr)] string pszPath,
            IntPtr pbc,
            ref Guid riid,
            [MarshalAs(UnmanagedType.Interface)] out object ppv);

        private static string PathOf(IShellItem item)
        {
            IntPtr p = IntPtr.Zero;
            try
            {
                item.GetDisplayName(SIGDN_FILESYSPATH, out p);
                if (p == IntPtr.Zero) { return null; }
                return Marshal.PtrToStringUni(p);
            }
            finally
            {
                if (p != IntPtr.Zero) { Marshal.FreeCoTaskMem(p); }
            }
        }

        /// <summary>
        /// Opent de Explorer-mapkiezer. Geeft de gekozen paden terug,
        /// of een lege reeks wanneer de gebruiker annuleert.
        /// </summary>
        public static string[] Pick(IntPtr owner, string title, string initialPath, bool multiSelect)
        {
            List<string> result = new List<string>();
            IFileOpenDialog dlg = (IFileOpenDialog)(new FileOpenDialogRcw());

            uint options;
            dlg.GetOptions(out options);
            options = options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
            if (multiSelect) { options = options | FOS_ALLOWMULTISELECT; }
            dlg.SetOptions(options);

            if (!string.IsNullOrEmpty(title)) { dlg.SetTitle(title); }
            dlg.SetOkButtonLabel("Deze map gebruiken");

            if (!string.IsNullOrEmpty(initialPath))
            {
                try
                {
                    Guid iid = typeof(IShellItem).GUID;
                    object item;
                    SHCreateItemFromParsingName(initialPath, IntPtr.Zero, ref iid, out item);
                    if (item != null) { dlg.SetFolder((IShellItem)item); }
                }
                catch { }
            }

            int hr = dlg.Show(owner);
            if (hr != 0) { return result.ToArray(); }   // 0x800704C7 = geannuleerd

            IShellItemArray items;
            dlg.GetResults(out items);
            uint count;
            items.GetCount(out count);
            for (uint i = 0; i < count; i++)
            {
                IShellItem si;
                items.GetItemAt(i, out si);
                string p = PathOf(si);
                if (!string.IsNullOrEmpty(p)) { result.Add(p); }
            }
            return result.ToArray();
        }
    }
}
'@
}

# ---------------------------------------------------------------------
# 2c. Regel in de bestandslijst
# ---------------------------------------------------------------------

if (-not ('X265.FileJob' -as [type])) {
$wpfBase = [System.Windows.Threading.Dispatcher].Assembly.Location
Add-Type -ReferencedAssemblies @($wpfBase) -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Windows.Threading;

namespace X265
{
    public class FileJob : INotifyPropertyChanged
    {
        private Dispatcher _disp;

        public FileJob() { }
        public FileJob(Dispatcher d) { _disp = d; }

        public event PropertyChangedEventHandler PropertyChanged;

        private void Raise(string name)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h == null) return;
            PropertyChangedEventArgs a = new PropertyChangedEventArgs(name);
            if (_disp != null && !_disp.CheckAccess())
                _disp.BeginInvoke((Action)(() => h(this, a)));
            else
                h(this, a);
        }

        // ---- gebonden aan de DataGrid -----------------------------
        // Al-HEVC-regels mogen niet worden aangevinkt. De setter weigert
        // dat hard, zodat geen enkele weg eromheen leidt.
        private bool _include = true;
        public bool Include
        {
            get { return _include; }
            set
            {
                bool v = value;
                if (v && _isHevc) { v = false; }
                if (_include == v) { return; }
                _include = v;
                Raise("Include");
            }
        }

        private string _name = "";
        public string Name { get { return _name; } set { _name = value; Raise("Name"); } }

        private string _folder = "";
        public string Folder { get { return _folder; } set { _folder = value; Raise("Folder"); } }

        private string _codec = "";
        public string Codec { get { return _codec; } set { _codec = value; Raise("Codec"); } }

        private string _sizeText = "";
        public string SizeText { get { return _sizeText; } set { _sizeText = value; Raise("SizeText"); } }

        private string _durationText = "";
        public string DurationText { get { return _durationText; } set { _durationText = value; Raise("DurationText"); } }

        private string _status = "In wachtrij";
        public string Status { get { return _status; } set { _status = value; Raise("Status"); } }

        private string _resultText = "";
        public string ResultText { get { return _resultText; } set { _resultText = value; Raise("ResultText"); } }

        private string _newSizeText = "";
        public string NewSizeText { get { return _newSizeText; } set { _newSizeText = value; Raise("NewSizeText"); } }

        // Positie in de wachtrij, als drie cijfers met voorloopnullen.
        // Leeg wanneer de regel niet in de wachtrij staat.
        private string _queueText = "";
        public string QueueText { get { return _queueText; } set { _queueText = value; Raise("QueueText"); } }

        // Al HEVC? Dan is aanvinken uitgesloten en is het vinkje grijs.
        private bool _isHevc = false;
        public bool IsHevc
        {
            get { return _isHevc; }
            set
            {
                if (_isHevc == value) { return; }
                _isHevc = value;
                if (_isHevc && _include) { _include = false; Raise("Include"); }
                Raise("IsHevc");
                Raise("CanInclude");
            }
        }

        /// <summary>Onwaar voor al-HEVC-regels; hieraan hangt IsEnabled van het vinkje.</summary>
        public bool CanInclude { get { return !_isHevc; } }

        // ---- niet gebonden, alleen data ---------------------------
        public string FullPath   { get; set; }
        public long   SizeBytes  { get; set; }
        public long   NewBytes   { get; set; }
        public double DurationSec{ get; set; }
        public bool   Queued     { get; set; }
        public int    QueuePos   { get; set; }
        public double EncodeSec  { get; set; }
        public string RawCodec   { get; set; }

        // Vast uitvoerpad, meegegeven met -Out op de opdrachtregel. Leeg
        // betekent: zelf een naam afleiden (<naam>.x265.mkv).
        public string OutPath    { get; set; }
    }
}
'@
}
