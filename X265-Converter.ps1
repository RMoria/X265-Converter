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
    # Weggelaten? Dan gaat het resultaat als <naam>.mkv naast de bron (zie
    # New-OutputPath voor wat er gebeurt als dat precies de bron is).
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
    [switch]$GeenGit,

    # Een hernoemronde terugdraaien: het undo-bestand (CSV met OldPath en
    # NewPath) dat bij het hernoemen is weggeschreven. Zonder -Uitvoeren
    # wordt alleen getoond wat er zou gebeuren.
    [string]$HernoemTerug,
    [switch]$Uitvoeren
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
$AppVersion = '1.11'
$AppDate    = '2026-09-24'
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

    # De vorige versie gaat alleen TIJDELIJK opzij, in de ophaalmap (die
    # na afloop hoe dan ook wordt opgeruimd): nodig om terug te rollen als
    # het vervangen halverwege mislukt, daarna niet meer. Er blijft dus geen
    # map met een oude versie naast het programma staan.
    $backup = Join-Path $Tijdelijk '_vorige-versie'
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

    # Een 'vorige-versie'-map van voor v1.11 (toen de oude versie ernaast
    # bleef staan) mag nu weg.
    $oud = Join-Path $Doel 'vorige-versie'
    if (Test-Path -LiteralPath $oud) {
        try { Remove-Item -LiteralPath $oud -Recurse -Force -ErrorAction Stop; Schrijf 'Oude map vorige-versie opgeruimd.' 'DarkGray' }
        catch { Schrijf ("Oude map vorige-versie kon niet weg: {0}" -f $_.Exception.Message) 'DarkGray' }
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
# 0.  Hernoemen terugdraaien (-HernoemTerug <undo.csv> [-Uitvoeren])
#
#     Achterstevoren, zodat een reeks hernoemingen netjes terugloopt.
#     Verwijderde dubbelen komen hiermee niet terug; die staan in de
#     Prullenbak (op een netwerkschijf: weg).
# ---------------------------------------------------------------------
if ($HernoemTerug) {
    if (-not (Test-Path -LiteralPath $HernoemTerug)) { Write-Host "Undo-bestand niet gevonden: $HernoemTerug"; return }
    $rijen = @(Import-Csv -LiteralPath $HernoemTerug)
    [array]::Reverse($rijen)
    $n = 0
    foreach ($r in $rijen) {
        $oudNaam = [IO.Path]::GetFileName([string]$r.OldPath)
        if (-not (Test-Path -LiteralPath $r.NewPath)) { Write-Warning "Niet gevonden: $($r.NewPath)"; continue }
        if (-not $Uitvoeren) { Write-Host "[voorbeeld] terug: $($r.NewPath) -> $oudNaam"; $n++; continue }
        try {
            if (([string]$r.OldPath).ToLower() -eq ([string]$r.NewPath).ToLower()) {
                $tmp = $oudNaam + '.tmp_rename'
                Rename-Item -LiteralPath $r.NewPath -NewName $tmp -ErrorAction Stop
                Rename-Item -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName([string]$r.NewPath)) $tmp) -NewName $oudNaam -ErrorAction Stop
            }
            elseif (Test-Path -LiteralPath $r.OldPath) { Write-Warning "Staat al: $($r.OldPath) - overgeslagen"; continue }
            else { Rename-Item -LiteralPath $r.NewPath -NewName $oudNaam -ErrorAction Stop }
            Write-Host "terug: $($r.NewPath) -> $oudNaam"
            $n++
        }
        catch { Write-Warning "Mislukt: $($r.NewPath): $($_.Exception.Message)" }
    }
    if ($Uitvoeren) { Write-Host "$n bestand(en) teruggezet." }
    else { Write-Host "`n$n bestand(en) zouden worden teruggezet. Voeg -Uitvoeren toe om het echt te doen." -ForegroundColor Yellow }
    return
}

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
        // betekent: zelf een naam afleiden (<naam>.mkv).
        public string OutPath    { get; set; }
    }
}
'@
}

# ---------------------------------------------------------------------
# 3.  Paden en standaardinstellingen
# ---------------------------------------------------------------------

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptDir)) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

$FfmpegDir  = Join-Path $ScriptDir 'ffmpeg'
$FfmpegExe  = Join-Path $FfmpegDir 'bin\ffmpeg.exe'
$FfprobeExe = Join-Path $FfmpegDir 'bin\ffprobe.exe'

# ---------------------------------------------------------------------
#  Paden veilig behandelen
#
#  Op een dichtgezette machine gooit Windows bij een map waar je niet bij
#  mag "Toegang geweigerd" in plaats van netjes $false terug te geven. Een
#  kale Test-Path laat het programma dan omvallen op een knopdruk. Deze
#  twee hulpjes geven altijd gewoon $true of $false terug.
# ---------------------------------------------------------------------
function Test-PathSafe {
    param([string]$Path, [switch]$Container)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        if ($Container) { return [bool](Test-Path -LiteralPath $Path -PathType Container -ErrorAction Stop) }
        return [bool](Test-Path -LiteralPath $Path -ErrorAction Stop)
    }
    catch { return $false }
}

# Bestaat niet alleen, maar kan er ook echt geschreven worden. Dat is een
# ander verhaal: een map kan prima bestaan en toch op slot zitten.
function Test-DirWritable {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        if (-not (Test-PathSafe $Path -Container)) {
            New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        $probe = Join-Path $Path ('.x265probe_' + [guid]::NewGuid().ToString('N') + '.tmp')
        Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch { return $false }
}

# ---------------------------------------------------------------------
#  Waar instellingen en logboek heen gaan
#
#  Naast het script, tenzij daar niet geschreven mag worden. Op een
#  beheerde laptop is C:\Tools vaak alleen-lezen voor gewone gebruikers,
#  en dan is starten als administrator niet de oplossing maar het
#  probleem. In dat geval wijken we uit naar de profielmap van de
#  gebruiker, waar altijd geschreven mag worden.
# ---------------------------------------------------------------------
$DataDir = $ScriptDir
if (-not (Test-DirWritable $DataDir)) {
    $alt = Join-Path $env:LOCALAPPDATA 'X265-Converter'
    if (Test-DirWritable $alt) { $DataDir = $alt }
    else {
        $alt2 = Join-Path $env:TEMP 'X265-Converter'
        if (Test-DirWritable $alt2) { $DataDir = $alt2 }
    }
}

# ---------------------------------------------------------------------
#  Eén instantie, en een postbus voor opdrachten
#
#  Wordt het script nog een keer aangeroepen terwijl het al draait - met
#  -In/-Out vanuit een ander programma, of gewoon door nog eens te
#  dubbelklikken - dan hoort er geen tweede venster te komen. De nieuwe
#  opdracht gaat naar de postbus van de draaiende instantie en die zet hem
#  achteraan de wachtrij.
#
#  Een named mutex is hier het juiste gereedschap: hij verdwijnt vanzelf
#  als het proces stopt, ook bij een crash. Een lock-bestand zou na een
#  harde afsluiting blijven staan en het programma onstartbaar maken.
#  'Local\' en niet 'Global\': per aangemelde gebruiker is genoeg, en
#  Global vraagt rechten die op een beheerde machine ontbreken.
# ---------------------------------------------------------------------
$InboxDir  = Join-Path $DataDir 'opdrachten'
$MutexNaam = 'Local\X265Converter.SingleInstance'

$script:AppMutex  = $null
$script:IsPrimair = $true
try {
    $nieuw = $false
    $script:AppMutex  = New-Object System.Threading.Mutex($true, $MutexNaam, [ref]$nieuw)
    $script:IsPrimair = $nieuw
}
catch {
    # Bij twijfel gewoon starten: een programma dat niet opstart is erger
    # dan twee vensters.
    $script:IsPrimair = $true
}

function Write-Opdracht {
    param([string]$InPad, [string]$UitPad)

    try {
        if (-not (Test-Path -LiteralPath $InboxDir)) {
            New-Item -ItemType Directory -Path $InboxDir -Force -ErrorAction Stop | Out-Null
        }
        $naam = 'opdracht_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' +
                ([guid]::NewGuid().ToString('N').Substring(0,8)) + '.json'
        $pad  = Join-Path $InboxDir $naam

        # eerst als .tmp wegschrijven en dan hernoemen, anders kan de
        # andere instantie een half geschreven bestand oppakken
        $tmp = $pad + '.tmp'
        ([pscustomobject]@{
            In   = $InPad
            Out  = $UitPad
            Tijd = (Get-Date).ToString('s')
        } | ConvertTo-Json) | Set-Content -LiteralPath $tmp -Encoding UTF8 -Force
        Move-Item -LiteralPath $tmp -Destination $pad -Force
        return $true
    }
    catch {
        Write-Host ("Kon de opdracht niet doorgeven: {0}" -f $_.Exception.Message)
        return $false
    }
}

# Draait er al een instantie? Dan opdracht doorgeven en klaar.
if (-not $script:IsPrimair) {
    if (-not [string]::IsNullOrWhiteSpace($In)) {
        if (Write-Opdracht -InPad $In -UitPad $Out) {
            Write-Host ("X265 Converter draait al; {0} is achteraan de wachtrij gezet." -f $In)
        }
    }
    else {
        Write-Host 'X265 Converter draait al.'
    }
    try { if ($script:AppMutex) { $script:AppMutex.Dispose() } } catch { }
    return
}

$SettingsFile = Join-Path $DataDir 'X265-Converter.settings.json'
$ErrorLogFile = Join-Path $DataDir 'X265-Converter.error.log'

# Stond er al een instellingenbestand naast het script en zijn we uitgeweken,
# dan dat eenmalig meenemen - anders begint het programma daar met een lege
# wachtrij en verdwijnen de totalen.
if ($DataDir -ne $ScriptDir) {
    $oud = Join-Path $ScriptDir 'X265-Converter.settings.json'
    if ((Test-PathSafe $oud) -and -not (Test-PathSafe $SettingsFile)) {
        try { Copy-Item -LiteralPath $oud -Destination $SettingsFile -Force -ErrorAction Stop } catch { }
    }
}

# Extensies die als ondertitel bij een video worden beschouwd. Staat
# bewust niet in de GUI (te veel knoppen), maar wel in het instellingen-
# bestand, zodat het met de hand aan te passen is.
$script:SubExtensions = @('srt','sub','idx','ssa','ass','vtt','sup','txt','smi','sbv')

# Zoveel fouten op rij en de run stopt zichzelf (punt: noodstop).
$script:MaxFailStreak = 3

# Drie instellingen die altijd aan stonden en waar nooit iets aan werd
# veranderd. Die zijn uit de GUI gehaald - minder vinkjes, hetzelfde gedrag.
# Ze staan nog wel in het instellingenbestand, dus met de hand aanpassen kan.
$script:Recursive  = $true   # submappen meenemen
$script:KeepDate   = $true   # wijzigingsdatum van het origineel overnemen
$script:SmartRetry = $true   # herpoging met alleen beeld en geluid als het misgaat

# Naam van het named event waarmee een draaiend KeepAwake-script wordt
# gestopt. Zodra de conversie klaar is, mag de pc weer gaan slapen; dat
# signaal gaat af voordat het programma zichzelf eventueel afsluit.
# Leeg maken zet het uit.
$script:KeepAwakeSignal = 'KeepAwakeStopSignal'

# Bron eerst naar de werkmap kopieren voordat er wordt geencodeerd.
# ffmpeg leest een bestand niet in een ruk maar de hele encode lang; staat
# de bron op een share, dan is dat een half uur netwerkverkeer en
# schijfactiviteit op de andere machine. Eenmaal overhalen is rustiger.
# Het kopieren van het volgende bestand loopt mee met de huidige encode,
# dus er staat hooguit een bestand vooruit klaar.
$script:PrefetchToWorkDir  = $true

# Alleen doen voor bronnen op een netwerkpad. Een lokale bron kopieren
# levert niets op en kost alleen schijfruimte.
$script:PrefetchOnlyNetwork = $true

# ---------------------------------------------------------------------
#  Twee computers op dezelfde map
#
#  Draaien er twee pc's op dezelfde (net)werkmap, dan moeten ze niet
#  allebei aan hetzelfde bestand beginnen. Voordat er aan een bestand
#  wordt begonnen legt de pc er een klein tekstbestandje naast:
#
#      aflevering 12.mkv.x265lock
#
#  Dat bestandje wordt aangemaakt met 'alleen als het nog niet bestaat'.
#  Dat is aan de serverkant EEN handeling die of lukt of faalt - er zit
#  geen moment tussen waarin de tweede pc ertussen kan komen. Een gedeeld
#  lijstje in een txt-bestand kan dat niet: twee pc's lezen dat lijstje,
#  vullen het allebei aan en schrijven het allebei terug, en dan is een
#  van de twee regels weg.
#
#  Zet dit op $false als er maar een pc aan het werk is. Het scheelt per
#  bestand twee kleine handelingen op de share; verder niets.
$script:SharedLocks = $true

# Hoe lang mag een lock stil zijn voordat hij als verweesd geldt? De
# eigenaar werkt zijn lock elke minuut bij. Blijft dat een kwartier uit,
# dan is die pc afgesloten, gecrasht of van het netwerk gevallen en mag
# een ander het bestand overnemen.
#
# Op Windows is dit alleen het vangnet: zolang de eigenaar leeft houdt
# hij het lock-bestand ook echt geopend, en dan kan geen andere pc hem
# afpakken - ook niet als de klokken van de twee machines uiteenlopen.
$script:LockStaleMinutes = 15.0

# Hoe lang de wachtrij leeg moet zijn voordat er uit zichzelf opnieuw naar
# de bronmappen wordt gekeken. Alleen van belang als het vinkje 'opnieuw
# kijken' aanstaat; het aantal uur staat ernaast in de GUI (1-168, standaard
# 24) en wordt hier intern in minuten bewaard.
$script:WatchMinutes = 1440.0

function Set-WatchHoursText {
    # Zet de tekst uit het uur-invoerveld om naar minuten (intern gebruikt)
    # en klemt die binnen 1-168 uur. Geeft het geklemde aantal uur terug
    # zodat de aanroeper het veld zelf weer netjes kan tonen.
    param([string]$Tekst)
    $u  = 0.0
    $ok = [double]::TryParse($Tekst, [Globalization.NumberStyles]::Float,
                              [Globalization.CultureInfo]::InvariantCulture, [ref]$u)
    if (-not $ok -or $u -le 0) { $u = 24.0 }
    $u = [Math]::Round($u)
    if ($u -lt 1)   { $u = 1 }
    if ($u -gt 168) { $u = 168 }
    $script:WatchMinutes = $u * 60.0
    return [int]$u
}

# Wachtrij bewaren over een herstart heen. Staat UIT: bij het opstarten
# begint de lijst leeg, zodat een nieuwe scan niet bij de resten van de
# vorige keer komt te staan. Met deze instelling uit wordt de wachtrij ook
# niet meer naar het instellingenbestand geschreven - dat scheelt een
# bestand van honderden kilobytes.
#
# Op $true doet het weer wat het eerder deed: lijst en volgorde komen terug
# en worden bij het opstarten in de achtergrond nagelopen (staan de
# bestanden er nog, en wat zijn nu de grootte, duur en codec).
$script:RestoreQueue = $false

# Naamregels voor het hernoemen (na de conversie en met de knop
# 'Bronmappen hernoemen'). Hier staat alleen de DELTA op de ingebouwde
# standaard, zoals die uit het instellingenbestand komt (sleutel
# "RenameRules"); zie New-RnRules. $null = alleen de standaard.
$script:RenameRulesDelta = $null

# Nacontrole op het geluid van het nieuwe bestand: haalt de audiotrack het
# einde van de film? Zo niet, dan status 'Let op' en het origineel blijft
# staan. Staat niet in de GUI (te veel knoppen) maar wel in het
# instellingenbestand, dus met de hand aan te passen.
# FinalRemux: ALTIJD een remux na de encode. Staat uit. De encode zet zelf
# '-max_interleave_delta 0', dus de container hoort meteen goed te zijn en
# een extra ronde hoort overbodig te zijn.
$script:FinalRemux = $false

# RemuxIfNeeded: na de encode nameten of het geluid op een aantal punten in
# het bestand echt bij het beeld ligt, en alleen remuxen als dat niet zo is.
# Dit is het vangnet onder de aanname hierboven. De meting kost seeks, geen
# leesronde - een fractie van een seconde op een net geschreven bestand.
$script:RemuxIfNeeded = $true

$script:CheckAudioTail     = $true

# Vanaf welk tekort de staart de moeite van het opvullen waard is. Een tekort
# van een paar seconden is doodnormaal: in een steekproef van 136 gewone
# bestanden had 18% er een, tot 4,9 seconden toe.
$script:AudioTailTolerance = 2.0

# Hoeveel de UITVOER op de BRON mag achterblijven voordat het verlies heet.
# Dit is de maat die telt; de absolute waarde hierboven zegt niets over de
# kwaliteit van de omzetting.
$script:AudioTailMargin    = 2.0

# Vanaf hoeveel verlies het bestand wordt afgekeurd (VCP). Daaronder wordt de
# staart opgevuld en het bestand gewoon gebruikt, met het verlies in de log en
# in de resultaatkolom.
#
# Waarom er twee grenzen zijn: met alleen AudioTailMargin sneuvelde 25% van de
# bestanden op verliezen van 2 tot 5 seconden - het staartje van de aftiteling.
# Een conversie van drie kwartier weggooien voor een paar seconden staat niet
# in verhouding. Pas als er echt inhoud ontbreekt is het bestand niets waard.
$script:AudioLossLimit     = 30.0

# Staart van een te kort geluidsspoor met stilte opvullen tot het einde van
# het beeld. Er komt geen geluid bij dat er niet was.
$script:PadShortAudio      = $true

# Wat er achter de naam van de bron komt als de omzetting geluid heeft laten
# vallen. De scanner slaat bestanden met deze markering over.
$script:VcpMarker          = 'VCP'

# ---------------------------------------------------------------------
#  Geluid
#
#  '-c:a copy' sluist het geluid ongewijzigd door, inclusief de tijd-
#  stempels uit het origineel. Zit daar een gat of een sprong in - niet
#  ongebruikelijk bij rips - dan neemt de MKV die over en laten veel
#  spelers de audiotrack op dat punt vallen. Beeld gaat wel goed door,
#  want dat wordt volledig opnieuw opgebouwd.
#
#  Opnieuw encoderen met 'aresample=async=1' maakt de tijdstempels
#  opnieuw aan: een gat wordt met stilte opgevuld, een overlap wordt
#  weggeknipt. Dat kost verwaarloosbaar veel rekentijd naast x265.
# ---------------------------------------------------------------------
$AudioModeList = @(
    'Kopieren (snelst, geluid ongewijzigd)'
    'AAC opnieuw encoderen (aanbevolen)'
    'AC3 opnieuw encoderen (TV / receiver)'
    'FLAC opnieuw encoderen (verliesvrij, groter)'
)
$AudioModeMap = @{
    'Kopieren (snelst, geluid ongewijzigd)'        = 'copy'
    'AAC opnieuw encoderen (aanbevolen)'           = 'aac'
    'AC3 opnieuw encoderen (TV / receiver)'        = 'ac3'
    'FLAC opnieuw encoderen (verliesvrij, groter)' = 'flac'
}
$script:DefaultAudioMode = 'aac'

$DefaultExtensions = 'mkv,mp4,avi,mov,wmv,flv,ts,m2ts,mts,m4v,mpg,mpeg,vob,webm,3gp,asf,ogv,rm,rmvb,divx,f4v,mxf,m2v,mpv,dv,y4m'

$PresetMap = @{
    'libx265 (CPU / x265)'      = @('ultrafast','superfast','veryfast','faster','fast','medium','slow','slower','veryslow','placebo')
    'hevc_nvenc (NVIDIA GPU)'   = @('p1','p2','p3','p4','p5','p6','p7')
    'hevc_qsv (Intel QuickSync)'= @('veryfast','faster','fast','medium','slow','slower','veryslow')
    'hevc_amf (AMD GPU)'        = @('speed','balanced','quality')
}
$CodecMap = @{
    'libx265 (CPU / x265)'      = 'libx265'
    'hevc_nvenc (NVIDIA GPU)'   = 'hevc_nvenc'
    'hevc_qsv (Intel QuickSync)'= 'hevc_qsv'
    'hevc_amf (AMD GPU)'        = 'hevc_amf'
}

# ---------------------------------------------------------------------
# 4.  Kleine hulpfuncties
# ---------------------------------------------------------------------

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -eq $null) { return '-' }
    $neg = $Bytes -lt 0
    $b = [Math]::Abs([double]$Bytes)
    $u = @('B','KB','MB','GB','TB','PB')
    $i = 0
    while ($b -ge 1024 -and $i -lt ($u.Count - 1)) { $b = $b / 1024; $i++ }
    $txt = if ($i -le 1) { '{0:N0} {1}' -f $b, $u[$i] } else { '{0:N2} {1}' -f $b, $u[$i] }
    if ($neg) { return '-' + $txt } else { return $txt }
}

function Format-Span {
    param([double]$Seconds)
    if ($Seconds -lt 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) { return '--:--' }
    $t = [TimeSpan]::FromSeconds([Math]::Round($Seconds))
    if ($t.TotalDays -ge 1) { return ('{0}d {1:00}u {2:00}m' -f [int]$t.TotalDays, $t.Hours, $t.Minutes) }
    if ($t.TotalHours -ge 1) { return ('{0}u {1:00}m {2:00}s' -f [int]$t.TotalHours, $t.Minutes, $t.Seconds) }
    return ('{0}m {1:00}s' -f [int]$t.TotalMinutes, $t.Seconds)
}

function Format-Clock {
    param([double]$Seconds)
    if ($Seconds -lt 0) { return '--:--:--' }
    $t = [TimeSpan]::FromSeconds([Math]::Round($Seconds))
    return ('{0:00}:{1:00}:{2:00}' -f [int]$t.TotalHours, $t.Minutes, $t.Seconds)
}

# ---------------------------------------------------------------------
# 5.  Gedeelde status tussen GUI en werk-thread
# ---------------------------------------------------------------------

$sync = [hashtable]::Synchronized(@{})

# --- scannen / controleren (kan gelijktijdig met een conversie lopen) -
$sync.ScanBusy          = $false
$sync.ScanCancel        = $false
$sync.ScanSettings      = @{}
$sync.ScanMode          = 'scan'    # scan | verify | opdracht

# Is er tijdens deze ronde ergens een lock van een andere pc gezien? Zo ja,
# dan is er aan het eind nog een keer rondkijken de moeite waard: die pc
# kan bestanden hebben laten liggen die hier nooit in de lijst kwamen.
$sync.LockGezien        = $false

# --- converteren ----------------------------------------------------
$sync.ConvBusy          = $false
$sync.Cancel            = $false      # stop direct
$sync.StopAfterCurrent  = $false      # stop na huidige conversie
$sync.PauseRequested    = $false
$sync.IsPaused          = $false
$sync.CurrentProcess    = $null
$sync.CurrentJob        = $null
$sync.WorkerError       = $null

$sync.Ffmpeg            = $FfmpegExe
$sync.Ffprobe           = $FfprobeExe

$sync.NewJobs           = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$sync.LogQueue          = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$sync.VerifyResults     = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'

# DE WACHTRIJ.
# Een gesynchroniseerde lijst met alleen de regels die nog moeten
# worden gedaan, in de volgorde waarin ze gedaan worden. De werk-thread
# haalt telkens element 0 eraf (onder een lock op SyncRoot) en werkt dat
# af; het bestand dat onder handen is zit dus NIET meer in de lijst maar
# in $sync.CurrentJob. Daardoor mag de GUI de rest van de rij vrij
# herschikken zonder dat er iets kan worden overgeslagen of dubbel
# gedaan, en is er geen vaste index in het spel.
$sync.Queue             = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

# --- voortgang en statistiek ----------------------------------------
$sync.ScanTotal         = 0
$sync.ScanChecked       = 0
$sync.ScanFound         = 0
$sync.ScanSkippedHevc   = 0
$sync.ScanSkippedVcp    = 0
$sync.ScanSkippedNoVid  = 0
$sync.ScanStatus        = ''

$sync.JobsDone          = 0           # afgehandeld in deze run
$sync.Success           = 0
$sync.Failed            = 0
$sync.Warned            = 0

$sync.OrigBytes         = [long]0
$sync.NewBytes          = [long]0

# Speelduur: DoneVideoSec is wat af is, CurVideoSec/CurDurationSec is het
# bestand dat bezig is, en QueueVideoSec wordt door de GUI bijgehouden uit
# de wachtrij. "Resterend" volgt daaruit rechtstreeks, dus elke wijziging
# van de wachtrij werkt binnen één slag door.
$sync.DoneVideoSec      = 0.0
$sync.CurVideoSec       = 0.0
$sync.CurDurationSec    = 0.0
$sync.QueueVideoSec     = 0.0

$sync.CurFile           = ''
$sync.CurPhase          = ''
$sync.CurPhasePct       = 0.0
$sync.CurSpeed          = ''
$sync.CurFps            = ''
$sync.CurBitrate        = ''
$sync.CurTempSize       = [long]0

$sync.ActiveSec         = 0.0          # rekentijd zonder pauzes
$sync.WallSec           = 0.0          # verstreken wandkloktijd
$sync.PausedSec         = 0.0

# --- noodstop na drie fouten op rij ---------------------------------
$sync.FailStreak        = 0
$sync.EmergencyStop     = $false
$sync.EmergencyFiles    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'

# --- cumulatieve totalen (blijven over sessies heen doorlopen) -------
# De werk-thread werkt deze bij en zet TotalsDirty; de GUI schrijft ze
# weg. Eén schrijver op het JSON-bestand voorkomt beschadiging.
$sync.Totals            = [hashtable]::Synchronized(@{
    Files      = 0
    OrigBytes  = [long]0
    NewBytes   = [long]0
    ActiveSec  = 0.0
    VideoSec   = 0.0
    FirstUsed  = ''
    LastUsed   = ''
})
$sync.TotalsDirty       = $false

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] {1,-5} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $sync.LogQueue.Enqueue($line)
}

# ---------------------------------------------------------------------
# 6.  XAML  (gebruikersinterface)
# ---------------------------------------------------------------------

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Video naar H.265 / HEVC - Batch Converter"
        Width="1200" Height="900" MinWidth="980" MinHeight="780"
        WindowStartupLocation="CenterScreen"
        Background="#FF1B1D21"
        UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display">

  <Window.TaskbarItemInfo>
    <TaskbarItemInfo x:Name="taskbar"/>
  </Window.TaskbarItemInfo>

  <Window.Resources>

    <SolidColorBrush x:Key="Bg"      Color="#FF1B1D21"/>
    <SolidColorBrush x:Key="Panel"   Color="#FF25282E"/>
    <SolidColorBrush x:Key="Panel2"  Color="#FF2E323A"/>
    <SolidColorBrush x:Key="Line"    Color="#FF3A3F49"/>
    <SolidColorBrush x:Key="Fg"      Color="#FFE8EAED"/>
    <SolidColorBrush x:Key="Dim"     Color="#FF9AA3B0"/>
    <SolidColorBrush x:Key="Accent"  Color="#FF4C9AFF"/>
    <SolidColorBrush x:Key="Ok"      Color="#FF4CC38A"/>
    <SolidColorBrush x:Key="Warn"    Color="#FFE3B341"/>
    <SolidColorBrush x:Key="Err"     Color="#FFE5534B"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize"   Value="12"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize"   Value="11"/>
      <Setter Property="Margin"     Value="0,0,0,2"/>
    </Style>

    <Style x:Key="StatValue" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize"   Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style TargetType="GroupBox">
      <Setter Property="Foreground"  Value="{StaticResource Dim}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontFamily"  Value="Segoe UI"/>
      <Setter Property="FontSize"    Value="11"/>
      <Setter Property="Padding"     Value="8"/>
      <Setter Property="Margin"      Value="0"/>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Background" Value="{StaticResource Panel2}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="4"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#FF3A3F49"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#FF474D59"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#FF23262B"/>
                <Setter Property="Foreground" Value="#FF666C78"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#FF2C5FA8"/>
      <Setter Property="BorderBrush" Value="#FF3C74C4"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Background" Value="#FF15171A"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="5,4"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="CaretBrush" Value="{StaticResource Fg}"/>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,3,0,3"/>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="#FF101215"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="4,3"/>
    </Style>

    <Style TargetType="ListBox">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Background" Value="#FF15171A"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="18"/>
      <Setter Property="Background" Value="#FF15171A"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
    </Style>

    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="bd" Background="Transparent" BorderThickness="0,0,0,2" BorderBrush="Transparent" Padding="{TemplateBinding Padding}">
              <ContentPresenter ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter Property="Foreground" Value="{StaticResource Fg}"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{StaticResource Fg}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="#FF15171A"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#FF2A2E35"/>
      <Setter Property="RowBackground" Value="#FF15171A"/>
      <Setter Property="AlternatingRowBackground" Value="#FF191C20"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserDeleteRows" Value="False"/>
      <Setter Property="SelectionMode" Value="Extended"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="RowHeight" Value="24"/>
      <Setter Property="EnableRowVirtualization" Value="True"/>
    </Style>

    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#FF25282E"/>
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
    </Style>

    <Style TargetType="DataGridCell">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="6,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#FF2C3E5A"/>
        </Trigger>
      </Style.Triggers>
    </Style>

  </Window.Resources>

  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- ================= KOP ================= -->
    <Grid Grid.Row="0" Margin="0,0,0,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0">
        <TextBlock Text="VIDEO  -  H.265 / HEVC" FontSize="19" FontWeight="Light"/>
        <TextBlock x:Name="txtSubTitle" Text="Batch converter" Foreground="{StaticResource Dim}" FontSize="11"/>
      </StackPanel>
      <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock x:Name="txtFfmpegState" Text="ffmpeg: controleren…" Foreground="{StaticResource Dim}" FontSize="11" Margin="0,0,10,0"/>
      </StackPanel>
    </Grid>

    <!-- ================= MAPPEN + INSTELLINGEN ================= -->
    <Grid Grid.Row="1" Margin="0,0,0,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="12"/>
        <ColumnDefinition Width="430"/>
      </Grid.ColumnDefinitions>

      <GroupBox Grid.Column="0" Header="  BRONMAPPEN  (lokale paden en UNC, sleep mappen hierheen)  ">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <ListBox x:Name="lstFolders" Grid.Row="0" Height="128"
                   SelectionMode="Extended" AllowDrop="True"
                   ScrollViewer.HorizontalScrollBarVisibility="Auto"/>

          <Grid Grid.Row="1" Margin="0,6,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="txtPath" Grid.Column="0" Margin="0,0,6,0"
                     ToolTip="Typ of plak een pad, bv.  \\10.0.0.242\e\serie\Anime\Dorohedoro"/>
            <Button x:Name="btnAddPath" Grid.Column="1" Content="Pad toevoegen" Margin="0"/>
          </Grid>

          <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,6,0,0">
            <Button x:Name="btnBrowse" Content="Map kiezen…"/>
            <Button x:Name="btnRemoveFolder" Content="Selectie verwijderen"/>
            <Button x:Name="btnClearFolders" Content="Alles wissen"/>
          </StackPanel>
        </Grid>
      </GroupBox>

      <GroupBox Grid.Column="2" Header="  INSTELLINGEN  ">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <TextBlock Grid.Row="0" Grid.Column="0" Text="Encoder" Style="{StaticResource Label}" Margin="0,0,8,4" VerticalAlignment="Center"/>
          <ComboBox x:Name="cmbCodec" Grid.Row="0" Grid.Column="1" Margin="0,0,0,4"/>

          <TextBlock Grid.Row="1" Grid.Column="0" Text="Preset" Style="{StaticResource Label}" Margin="0,0,8,4" VerticalAlignment="Center"/>
          <ComboBox x:Name="cmbPreset" Grid.Row="1" Grid.Column="1" Margin="0,0,0,4"/>

          <TextBlock Grid.Row="2" Grid.Column="0" Text="Kwaliteit (CRF)" Style="{StaticResource Label}" Margin="0,0,8,4" VerticalAlignment="Center"/>
          <Grid Grid.Row="2" Grid.Column="1" Margin="0,0,0,4">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Slider x:Name="sldCrf" Grid.Column="0" Minimum="0" Maximum="51" Value="23"
                    TickFrequency="1" IsSnapToTickEnabled="True" VerticalAlignment="Center"/>
            <TextBlock x:Name="txtCrf" Grid.Column="1" Text="23" Width="28" TextAlignment="Right"
                       FontFamily="Consolas" FontSize="13" FontWeight="SemiBold" Margin="6,0,0,0"/>
          </Grid>

          <TextBlock Grid.Row="3" Grid.Column="0" Text="Geluid" Style="{StaticResource Label}" Margin="0,0,8,4" VerticalAlignment="Center"/>
          <ComboBox x:Name="cmbAudio" Grid.Row="3" Grid.Column="1" Margin="0,0,0,4"
                    ToolTip="Kopieren neemt de tijdstempels van het origineel over; opnieuw encoderen maakt ze opnieuw aan en vult gaten met stilte."/>

          <TextBlock Grid.Row="4" Grid.Column="0" Text="Extensies" Style="{StaticResource Label}" Margin="0,0,8,4" VerticalAlignment="Center"/>
          <TextBox x:Name="txtExt" Grid.Row="4" Grid.Column="1" Margin="0,0,0,4"/>

          <TextBlock Grid.Row="5" Grid.Column="0" Text="Werkmap" Style="{StaticResource Label}" Margin="0,0,8,4" VerticalAlignment="Center"/>
          <Grid Grid.Row="5" Grid.Column="1" Margin="0,0,0,4">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="txtWork" Grid.Column="0" Margin="0,0,6,0"/>
            <Button x:Name="btnCleanTemp" Grid.Column="1" Content="Opruimen" Margin="0" Padding="8,4"
                    ToolTip="Verwijder achtergebleven tijdelijke bestanden van eerdere runs"/>
          </Grid>

          <StackPanel Grid.Row="6" Grid.Column="0" Grid.ColumnSpan="2" Margin="0,4,0,0">
            <CheckBox x:Name="chkDeleteOrig" Content="Origineel verwijderen na geslaagde verplaatsing" IsChecked="True"/>
            <CheckBox x:Name="chkSubs"       Content="Ondertitels meenemen naar de nieuwe naam" IsChecked="True"/>
            <CheckBox x:Name="chkExitAfter"  Content="Programma afsluiten na conversie stop" IsChecked="False"/>
            <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
              <CheckBox x:Name="chkWatch" Content="Opnieuw kijken als de wachtrij leeg is, elke" IsChecked="False" VerticalAlignment="Center"
                        ToolTip="Kijkt na het ingestelde aantal uur zonder werk of er nieuwe bestanden in de bronmappen staan en zet die meteen om. Geen meldingen; laat het gewoon aanstaan."/>
              <TextBox x:Name="txtWatchHours" Width="40" Margin="6,0,4,0" Text="24" TextAlignment="Center" VerticalAlignment="Center"
                       ToolTip="Aantal uur zonder werk voordat de bronmappen opnieuw worden doorzocht (1-168)."/>
              <TextBlock Text="uur" VerticalAlignment="Center"/>
            </StackPanel>
            <!-- Kort gehouden: de kolom is 430 breed, en vinkje plus knop moeten
                 op een regel passen. De uitleg staat in de tooltip. -->
            <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
              <CheckBox x:Name="chkRenameAfter" Content="Na conversie hernoemen" IsChecked="False" VerticalAlignment="Center"
                        ToolTip="Het omgezette bestand en zijn ondertitels krijgen na de conversie een eenduidige naam volgens de naamregels, bijvoorbeeld Serienaam.S01E05.Titel.mkv. De regels staan onder RenameRules in het instellingenbestand."/>
              <Button x:Name="btnRename" Content="Bronmappen hernoemen…" Margin="12,0,0,0" Padding="8,1" VerticalAlignment="Center"
                      ToolTip="Alle video's en ondertitels in de gekozen bronmappen volgens de naamregels hernoemen. Je krijgt eerst een overzicht te zien; dubbelen gaan naar de Prullenbak. Er komt een undo-bestand bij."/>
            </StackPanel>
          </StackPanel>
        </Grid>
      </GroupBox>
    </Grid>

    <!-- ================= BEDIENING ================= -->
    <Border Grid.Row="2" Background="{StaticResource Panel}" CornerRadius="5" Padding="10" Margin="0,0,0,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal">
          <Button x:Name="btnScan"      Content="1.  Scannen" Width="130"/>
          <Button x:Name="btnStart"     Content="2.  Start conversie" Style="{StaticResource PrimaryButton}" Width="190"/>
          <Border Width="1" Background="{StaticResource Line}" Margin="8,2,14,2"/>
          <Button x:Name="btnPause"     Content="Pauze"      IsEnabled="False" Width="110"/>
          <Button x:Name="btnStopAfter" Content="Stop na huidige" IsEnabled="False" Width="150"/>
          <Button x:Name="btnStopNow"   Content="Stop direct" IsEnabled="False" Width="120"/>
        </StackPanel>
        <TextBlock x:Name="txtScanState" Grid.Column="1" Text="" Style="{StaticResource Label}"
                   Margin="14,0,0,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      </Grid>
    </Border>

    <!-- ================= VOORTGANG ================= -->
    <Border Grid.Row="3" Background="{StaticResource Panel}" CornerRadius="5" Padding="12" Margin="0,0,0,10">
      <StackPanel>
        <Grid Margin="0,0,0,3">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="txtOverallLabel" Grid.Column="0" Text="Totale voortgang" Style="{StaticResource Label}"/>
          <TextBlock x:Name="txtOverallInfo"  Grid.Column="1" Text="0 / 0" Style="{StaticResource Label}"/>
        </Grid>
        <ProgressBar x:Name="pbOverall" Minimum="0" Maximum="100" Value="0"/>

        <Grid Margin="0,10,0,3">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="txtCurrentFile" Grid.Column="0" Text="Geen actieve conversie"
                     TextTrimming="CharacterEllipsis" FontSize="12"/>
          <TextBlock x:Name="txtCurrentInfo" Grid.Column="1" Text="" Style="{StaticResource Label}" Margin="10,0,0,0"/>
        </Grid>
        <ProgressBar x:Name="pbCurrent" Minimum="0" Maximum="100" Value="0" Foreground="{StaticResource Ok}"/>
      </StackPanel>
    </Border>

    <!-- ================= STATISTIEK ================= -->
    <Border Grid.Row="4" Background="{StaticResource Panel}" CornerRadius="5" Padding="12" Margin="0,0,0,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Grid.Column="0" Margin="0,0,10,10">
          <TextBlock Text="REKENTIJD (actief)" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stActive" Text="00:00:00" Style="{StaticResource StatValue}"/>
        </StackPanel>
        <StackPanel Grid.Row="0" Grid.Column="1" Margin="0,0,10,10">
          <TextBlock Text="VERSTREKEN / GEPAUZEERD" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stWall" Text="00:00:00" Style="{StaticResource StatValue}"/>
        </StackPanel>
        <StackPanel Grid.Row="0" Grid.Column="2" Margin="0,0,10,10">
          <TextBlock Text="RESTEREND (ongeveer)" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stEta" Text="--:--" Style="{StaticResource StatValue}" Foreground="{StaticResource Accent}"/>
        </StackPanel>
        <StackPanel Grid.Row="0" Grid.Column="3" Margin="0,0,10,10">
          <TextBlock Text="KLAAR OMSTREEKS" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stEtaClock" Text="--:--" Style="{StaticResource StatValue}"/>
        </StackPanel>
        <StackPanel Grid.Row="0" Grid.Column="4" Margin="0,0,10,10">
          <TextBlock Text="GEM. ENCODE-SNELHEID" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stSpeed" Text="-" Style="{StaticResource StatValue}"/>
        </StackPanel>
        <StackPanel Grid.Row="0" Grid.Column="5" Margin="0,0,0,10">
          <TextBlock Text="BESTANDEN" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stFiles" Text="0 / 0" Style="{StaticResource StatValue}"/>
        </StackPanel>

        <StackPanel Grid.Row="1" Grid.Column="0" Margin="0,0,10,0">
          <TextBlock Text="ORIGINEEL TOTAAL" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stOrig" Text="0 B" Style="{StaticResource StatValue}"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Grid.Column="1" Margin="0,0,10,0">
          <TextBlock Text="NA OMZETTING" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stNew" Text="0 B" Style="{StaticResource StatValue}"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Grid.Column="2" Margin="0,0,10,0">
          <TextBlock Text="RUIMTEBESPARING" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stSaved" Text="0 B" Style="{StaticResource StatValue}" Foreground="{StaticResource Ok}"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Grid.Column="3" Margin="0,0,10,0">
          <TextBlock Text="BESPARING %" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stSavedPct" Text="0 %" Style="{StaticResource StatValue}" Foreground="{StaticResource Ok}"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Grid.Column="4" Margin="0,0,10,0">
          <TextBlock Text="GESLAAGD / MISLUKT" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stResult" Text="0 / 0" Style="{StaticResource StatValue}"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Grid.Column="5" Margin="0,0,0,0">
          <TextBlock Text="AANDACHT NODIG" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stWarn" Text="0" Style="{StaticResource StatValue}" Foreground="{StaticResource Warn}"/>
        </StackPanel>

        <Border Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="6" Margin="0,10,0,0"
                BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="0,8,0,0">
          <StackPanel>
            <TextBlock Text="ALLE SESSIES BIJ ELKAAR" Style="{StaticResource Label}"/>
            <TextBlock x:Name="stTotals" Text="nog niets omgezet" FontFamily="Consolas" FontSize="13"/>
          </StackPanel>
        </Border>
      </Grid>
    </Border>

    <!-- ================= TABS ================= -->
    <TabControl Grid.Row="5" Background="Transparent" BorderThickness="0" Padding="0,8,0,0">
      <TabItem Header="Bestanden">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="btnCheckAll"   Content="Alles aanvinken" Padding="8,4"/>
            <Button x:Name="btnUncheckAll" Content="Alles uitvinken" Padding="8,4"/>
            <Button x:Name="btnCheckSel"   Content="Selectie aan" Padding="8,4"/>
            <Button x:Name="btnUncheckSel" Content="Selectie uit" Padding="8,4"/>
            <Border Width="1" Background="{StaticResource Line}" Margin="6,2,10,2"/>
            <Button x:Name="btnToTop"      Content="Naar boven"  Padding="8,4" ToolTip="Selectie bovenaan de wachtrij zetten"/>
            <Button x:Name="btnToBottom"   Content="Naar onderen" Padding="8,4" ToolTip="Selectie onderaan de wachtrij zetten"/>
            <Border Width="1" Background="{StaticResource Line}" Margin="6,2,10,2"/>
            <Button x:Name="btnRemoveSel"  Content="Selectie uit lijst" Padding="8,4"/>
            <Button x:Name="btnClearList"  Content="Lijst wissen" Padding="8,4"/>
            <TextBlock x:Name="txtSelInfo" Text="" Style="{StaticResource Label}" Margin="10,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <DataGrid x:Name="grid" Grid.Row="1" IsReadOnly="False">
            <DataGrid.Columns>
              <DataGridTemplateColumn Header="" Width="34" CanUserSort="False" IsReadOnly="True">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <CheckBox IsChecked="{Binding Include, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                              IsEnabled="{Binding CanInclude, Mode=OneWay}"
                              HorizontalAlignment="Center" Margin="0"
                              ToolTip="Uitgeschakeld voor bestanden die al HEVC zijn"/>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTextColumn Header="Nr" Binding="{Binding QueueText}" Width="54" IsReadOnly="True">
                <DataGridTextColumn.ElementStyle>
                  <Style TargetType="TextBlock">
                    <Setter Property="FontFamily" Value="Consolas"/>
                    <Setter Property="TextAlignment" Value="Right"/>
                    <Setter Property="Foreground" Value="#FF4C9AFF"/>
                  </Style>
                </DataGridTextColumn.ElementStyle>
              </DataGridTextColumn>
              <DataGridTextColumn Header="Bestand"   Binding="{Binding Name}"         Width="*"   IsReadOnly="True"/>
              <DataGridTextColumn Header="Status"    Binding="{Binding Status}"       Width="180" IsReadOnly="True"/>
              <DataGridTextColumn Header="Grootte"   Binding="{Binding SizeText}"     Width="95"  IsReadOnly="True"/>
              <DataGridTextColumn Header="Nieuw"     Binding="{Binding NewSizeText}"  Width="95"  IsReadOnly="True"/>
              <DataGridTextColumn Header="Duur"      Binding="{Binding DurationText}" Width="80"  IsReadOnly="True"/>
              <DataGridTextColumn Header="Codec"     Binding="{Binding Codec}"        Width="75"  IsReadOnly="True"/>
              <DataGridTextColumn Header="Resultaat" Binding="{Binding ResultText}"   Width="150" IsReadOnly="True"/>
              <DataGridTextColumn Header="Map"       Binding="{Binding Folder}"       Width="240" IsReadOnly="True"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>
      <TabItem Header="Log">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="btnSaveLog"  Content="Log opslaan…" Padding="8,4"/>
            <Button x:Name="btnClearLog" Content="Log wissen" Padding="8,4"/>
          </StackPanel>
          <TextBox x:Name="txtLog" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True"
                   TextWrapping="NoWrap" FontFamily="Consolas" FontSize="12"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                   Background="#FF101215"/>
        </Grid>
      </TabItem>
    </TabControl>

    <!-- ================= STATUSBALK ================= -->
    <Border Grid.Row="6" Background="{StaticResource Panel}" CornerRadius="4" Padding="8,5" Margin="0,10,0,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="txtStatus" Grid.Column="0" Text="Klaar." Foreground="{StaticResource Dim}" FontSize="11"
                   TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="txtStatus2" Grid.Column="1" Text="" Foreground="{StaticResource Dim}" FontSize="11"/>
      </Grid>
    </Border>

  </Grid>
</Window>
'@

$xamlText = $xaml.OuterXml
$reader   = New-Object System.Xml.XmlNodeReader $xaml
$win      = [Windows.Markup.XamlReader]::Load($reader)

# alle benoemde elementen ophalen
$ui = @{}
foreach ($m in [regex]::Matches($xamlText, 'x:Name="([^"]+)"')) {
    $n  = $m.Groups[1].Value
    $el = $win.FindName($n)
    if ($el) { $ui[$n] = $el }
}

# ---------------------------------------------------------------------
# 6b. Vangnet voor fouten binnen de GUI
#
#     De trap bovenaan het script dekt alleen de rechtstreeks uitgevoerde
#     code. Fouten in knop-handlers en in de klok komen bij de dispatcher
#     terecht; zonder dit vangnet zou het venster geruisloos verdwijnen.
# ---------------------------------------------------------------------

$script:FaultCount = 0

function Report-Fault {
    param([string]$Where, [string]$Message, [string]$Detail = '')

    $script:FaultCount = $script:FaultCount + 1

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $text  = "[$stamp] $Where : $Message"
    if ($Detail) { $text = $text + "`r`n" + $Detail }

    try { $sync.LogQueue.Enqueue(('[{0}] {1,-5} {2}: {3}' -f (Get-Date -Format 'HH:mm:ss'), 'FOUT', $Where, $Message)) } catch { }

    $dir = $ScriptDir
    if ([string]::IsNullOrEmpty($dir)) { $dir = $env:TEMP }
    try { Add-Content -LiteralPath (Join-Path $dir 'X265-Converter.error.log') -Value ($text + "`r`n") -Encoding UTF8 } catch { }

    if ($script:FaultCount -le 5) {
        try {
            [System.Windows.MessageBox]::Show(
                "$Where`r`n`r`n$Message`r`n`r`nHet programma probeert door te gaan. De volledige melding staat in X265-Converter.error.log naast het script.",
                'X265 Converter - fout', 'OK', 'Warning') | Out-Null
        } catch { }
    }
}

$win.Dispatcher.Add_UnhandledException({
    param($eSender, $eArgs)
    try {
        $eArgs.Handled = $true
        $ex = $eArgs.Exception
        Report-Fault 'Fout in de gebruikersinterface' $ex.Message ($ex.ToString())
    } catch { }
})

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
        param([string]$SourcePath, [string]$Fixed = '', [bool]$ReplaceSource = $false)

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

        # Sinds v1.10 gewoon <naam>.mkv, zonder '.x265' ertussen. Komt dat
        # op precies de bron uit (een .mkv waar niets aan de naam te
        # schonen viel), dan:
        #  - origineel verwijderen aan: het resultaat neemt de plaats van
        #    de bron in (de verwisseling zelf gebeurt bij het verplaatsen);
        #  - origineel bewaren: dan kunnen ze niet dezelfde naam hebben en
        #    wordt het toch <naam>.x265.mkv.
        $dir   = [IO.Path]::GetDirectoryName($SourcePath)
        $base  = Get-CleanBase ([IO.Path]::GetFileNameWithoutExtension($SourcePath))
        $stam  = $base
        $cand  = Join-Path $dir ($stam + '.mkv')
        if ([string]::Equals($cand, $SourcePath, [StringComparison]::OrdinalIgnoreCase)) {
            if ($ReplaceSource) { return $SourcePath }
            $stam = $base + '.x265'
            $cand = Join-Path $dir ($stam + '.mkv')
        }
        $i = 2
        while (Test-Path -LiteralPath $cand) {
            $cand = Join-Path $dir ('{0} ({1}).mkv' -f $stam, $i)
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
    function Set-AlOmgezet {
        param($Job, [string]$Gevonden)
        $Job.Queued    = $false
        $Job.QueueText = ''
        $Job.Status    = 'Al omgezet'
        if ([string]::Equals($Gevonden, [string]$Job.FullPath, [StringComparison]::OrdinalIgnoreCase)) {
            $Job.ResultText = 'De bron is inmiddels zelf HEVC (al omgezet, mogelijk door een andere pc).'
            W ("Overgeslagen, is inmiddels al HEVC: {0}" -f $Job.FullPath) 'WAARS'
            return
        }
        $Job.ResultText = 'Er staat al een HEVC-uitvoer naast de bron: ' + [IO.Path]::GetFileName($Gevonden)
        W ("Overgeslagen, er staat al een omgezet bestand naast de bron: {0}" -f $Gevonden) 'WAARS'
        W 'Het origineel is blijkbaar niet opgeruimd na een eerdere omzetting. Verwijder het zelf, of hernoem de uitvoer als je het toch opnieuw wilt doen.' 'WAARS'
    }

    function Test-AlOmgezet {
        param([string]$SourcePath, [string]$FixedOut = '')

        # Waar kan een eerdere uitvoer staan? De huidige naam (<naam>.mkv),
        # de naam van voor v1.10 (<naam>.x265.mkv), en - als er na de
        # conversie wordt hernoemd - de naam volgens de naamregels.
        $kandidaten = @()
        if (-not [string]::IsNullOrWhiteSpace($FixedOut)) {
            $kandidaten = @($FixedOut)
        }
        else {
            try {
                $dir  = [IO.Path]::GetDirectoryName($SourcePath)
                $base = Get-CleanBase ([IO.Path]::GetFileNameWithoutExtension($SourcePath))
                $nieuw = Join-Path $dir ($base + '.mkv')
                $kandidaten += $nieuw
                $kandidaten += (Join-Path $dir ($base + '.x265.mkv'))
                if ($st -ne $null -and $st.ContainsKey('RenameAfterConvert') -and [bool]$st.RenameAfterConvert) {
                    $rn = $null
                    try { $rn = Get-RnNewName $nieuw } catch { }
                    if ($rn) { $kandidaten += (Join-Path $dir $rn) }
                }
            }
            catch { return '' }
        }

        # Sinds v1.10 kan het resultaat de plaats van de bron innemen
        # (zelfde naam). Heeft een andere pc dat al gedaan, dan is de bron
        # zelf nu HEVC. Bij een vast uitvoerpad niet: dan gaat het om dat pad.
        if ([string]::IsNullOrWhiteSpace($FixedOut)) { $kandidaten = @($SourcePath) + $kandidaten }

        foreach ($kandidaat in $kandidaten) {
            if ([string]::IsNullOrWhiteSpace($kandidaat)) { continue }
            try { if (-not [System.IO.File]::Exists($kandidaat)) { continue } } catch { continue }

            $lengte = 0
            try { $lengte = (Get-Item -LiteralPath $kandidaat -ErrorAction Stop).Length } catch { continue }
            if ($lengte -le 0) { continue }

            # Bestaan is niet genoeg: een half afgebroken bestand van een
            # eerdere poging mag de bron niet voor altijd blokkeren.
            $codec = ''
            try {
                $codec = (& $sync.Ffprobe -v error -select_streams v:0 `
                            -show_entries stream=codec_name -of default=nw=1:nk=1 $kandidaat 2>$null) -join ''
            }
            catch { continue }
            if (([string]$codec).Trim() -match '(?i)^(hevc|h265|x265)$') { return $kandidaat }
        }
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
                Set-AlOmgezet $job $alKlaar
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

                    # Nog een keer kijken, nu met het lock in handen: een
                    # andere pc kan klaar zijn gekomen tussen de controle
                    # hierboven en het lock. Zonder deze tweede blik zou
                    # die zijn (HEVC-)resultaat hier nog eens worden omgezet.
                    $alKlaar = Test-AlOmgezet -SourcePath ([string]$job.FullPath) -FixedOut ([string]$job.OutPath)
                    if ($alKlaar) {
                        if ($pre -ne $null -and $pre.Job -eq $job) { Stop-Prefetch $pre; $pre = $null }
                        Release-Lock $lock
                        $lock = $null
                        $script:HuidigLock = $null
                        Set-AlOmgezet $job $alKlaar
                        continue
                    }
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

                    $outPath = New-OutputPath -SourcePath $job.FullPath -Fixed ([string]$job.OutPath) `
                                              -ReplaceSource ([bool]$st.DeleteOriginal)

                    # Komt het resultaat op precies de naam van de bron, dan
                    # gaat de bron eerst opzij onder een naam die geen video
                    # is. Mislukt het verplaatsen, dan gaat hij terug.
                    $vervangt = [string]::Equals($outPath, [string]$job.FullPath, [StringComparison]::OrdinalIgnoreCase)
                    $opzij    = ''
                    $opzijOk  = $true
                    if ($vervangt) {
                        $opzij = [string]$job.FullPath + '.x265oud'
                        try {
                            if (Test-Path -LiteralPath $opzij) { Remove-Item -LiteralPath $opzij -Force -ErrorAction Stop }
                            Move-Item -LiteralPath $job.FullPath -Destination $opzij -ErrorAction Stop
                        }
                        catch {
                            $opzijOk = $false
                            $sync.LastMoveError = 'origineel kon niet opzij worden gezet: ' + $_.Exception.Message
                        }
                    }

                    $sync.CurPhase    = 'Verplaatsen'
                    $sync.CurPhasePct = 0
                    $job.Status       = 'Verplaatsen'
                    W ("Verplaatsen naar bronmap: {0}  ({1})" -f $outPath, (Format-Size $newLen))

                    $moved = $false
                    if ($opzijOk) {
                        $sync.LastMoveError = ''
                        $moved = Move-WithProgress $temp $outPath
                        if (-not $moved -and $vervangt) {
                            try { Move-Item -LiteralPath $opzij -Destination $job.FullPath -ErrorAction Stop }
                            catch { W ("Het origineel staat nog als {0}; zet het zelf terug." -f $opzij) 'FOUT' }
                        }
                    }

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
                            if ($vervangt) { $delOk = Remove-WithRetry $opzij $st.DeleteAttempts $st.DeleteWait }
                            else           { $delOk = Remove-WithRetry $job.FullPath $st.DeleteAttempts $st.DeleteWait }
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

                        # ---- hernoemen volgens de naamregels -----------
                        #  Pas NA de conversie: het lock hoort bij de naam
                        #  van de bron, en die blijft tot hier ongemoeid.
                        #  Niet bij een vast uitvoerpad (-Out): wie het pad
                        #  zelf opgeeft krijgt precies dat pad.
                        $hernoemd = ''
                        if ($st.ContainsKey('RenameAfterConvert') -and [bool]$st.RenameAfterConvert -and
                            [string]::IsNullOrWhiteSpace([string]$job.OutPath)) {
                            $sync.CurPhase = 'Hernoemen'
                            try {
                                $na = Invoke-RnSingle -VideoPath $outPath -UndoFile ([string]$st.RenameUndoFile)
                                if ($na -and $na -ne $outPath) { $hernoemd = [IO.Path]::GetFileName($na); $outPath = $na }
                            }
                            catch { W ("Hernoemen overgeslagen wegens fout: {0}" -f $_.Exception.Message) 'WAARS' }
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
                            if ($hernoemd) { $job.ResultText = $job.ResultText + '  -  ' + $hernoemd }
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
                            if ($vervangt) { $job.ResultText = 'x265 aangemaakt, origineel staat nog als ' + [IO.Path]::GetFileName($opzij) }
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
            WatchFolders  = [bool]$ui.chkWatch.IsChecked
            WatchMinutes  = [double]$script:WatchMinutes
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
            RenameAfterConvert = [bool]$ui.chkRenameAfter.IsChecked
            RenameRules   = $(if ($script:RenameRulesDelta -ne $null) { $script:RenameRulesDelta } else { New-RnDeltaTemplate })
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
        if ($saved.WatchFolders -ne $null)  { $ui.chkWatch.IsChecked      = [bool]$saved.WatchFolders }
        if ($saved.WatchMinutes) {
            $m = [double]$saved.WatchMinutes
            if ($m -ge 1.0 -and $m -le 10080.0) { $script:WatchMinutes = $m }
        }
        $ui.txtWatchHours.Text = [string]([Math]::Max(1, [Math]::Min(168, [Math]::Round($script:WatchMinutes / 60.0))))

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
        if ($saved.RenameAfterConvert -ne $null) { $ui.chkRenameAfter.IsChecked = [bool]$saved.RenameAfterConvert }
        if ($saved.RenameRules -ne $null) { $script:RenameRulesDelta = $saved.RenameRules }
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

        # ---- instellingen bijwerken naar een nieuwere versie ---------
        #  Sommige instellingen staan niet in de GUI en konden dus alleen
        #  de vaste standaard van een oudere versie hebben meegekregen.
        #  Bij het inlezen van een ouder instellingenbestand corrigeren we
        #  die hier naar de huidige standaard, zodat dat meteen goed staat
        #  en niet per pc met de hand rechtgezet hoeft te worden. Nieuwe
        #  correcties komen hieronder bij zodra een volgende versie dat
        #  nodig heeft - dit is de ene plek die bijhoudt wat er per versie
        #  is veranderd.
        $opgeslagenVersie = [version]'0.0'
        if ($saved.Version) {
            try { $opgeslagenVersie = [version]([string]$saved.Version) } catch { }
        }

        if ($opgeslagenVersie -lt [version]'1.9') {
            # AudioTailTolerance stond op sommige installaties nog op een
            # oudere waarde (5 s) van voor dit veld een vaste standaard
            # van 2 s kreeg. Er is geen GUI-veld voor, dus een afwijkende
            # waarde is nooit bewust ingesteld en mag terug naar de
            # standaard.
            if ($script:AudioTailTolerance -ne 2.0) {
                Write-Log ('Instellingen bijgewerkt naar v1.9: AudioTailTolerance stond op {0} s, teruggezet naar de standaard van 2 s.' -f $script:AudioTailTolerance)
                $script:AudioTailTolerance = 2.0
            }
            # Opnieuw kijken zat vast op 1 uur (60 min); er was geen
            # invoerveld om dat te wijzigen. De nieuwe standaard is 24 uur.
            if ($script:WatchMinutes -eq 60.0) {
                $script:WatchMinutes = 1440.0
                $ui.txtWatchHours.Text = '24'
                Write-Log 'Instellingen bijgewerkt naar v1.9: interval voor opnieuw kijken stond op de oude vaste waarde van 1 uur, teruggezet naar de nieuwe standaard van 24 uur.'
            }
        }
    } catch { }
}

# De naamregels: standaard plus de delta uit het instellingenbestand.
# Staat er iets onbruikbaars in de delta, dan wordt dat genegeerd en
# gemeld; het programma start gewoon.
try { $sync.RenameRules = New-RnRules $script:RenameRulesDelta ([string]$script:VcpMarker) }
catch {
    Write-Log ("RenameRules in het instellingenbestand onbruikbaar ({0}); de standaardregels worden gebruikt." -f $_.Exception.Message) 'WAARS'
    $sync.RenameRules = New-RnRules $null ([string]$script:VcpMarker)
}
foreach ($w in @($sync.RenameRules.Warnings)) { Write-Log ('Naamregels: ' + $w) 'WAARS' }

# Opruimen van de hernoem-CSV's: een achtergebleven voorbeeld (programma
# tijdens de vraag afgesloten) altijd, undo-bestanden na 30 dagen.
try {
    foreach ($f in @(Get-ChildItem -LiteralPath $DataDir -File -Filter 'hernoem_*.csv' -ErrorAction SilentlyContinue)) {
        $weg = ($f.Name -like 'hernoem_voorbeeld_*') -or
               ($f.Name -like 'hernoem_undo_*' -and $f.LastWriteTime -lt (Get-Date).AddDays(-30))
        if ($weg) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    }
} catch { }

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

function Remove-HernoemVoorbeeld {
    # Het voorbeeld-CSV is alleen voor tijdens de vraag; daarna weg. Het
    # undo-bestand blijft: dat is nodig om terug te kunnen draaien.
    try {
        $v = [string]$sync.ScanSettings.PreviewFile
        if ($v -and (Test-Path -LiteralPath $v)) { Remove-Item -LiteralPath $v -Force -ErrorAction Stop }
    } catch { }
}

function Complete-Hernoemen {
    param([string]$Fase)

    if ($sync.RenameError) {
        Remove-HernoemVoorbeeld
        [System.Windows.MessageBox]::Show("Hernoemen is afgebroken:`n`n$($sync.RenameError)", 'Hernoemen', 'OK', 'Error') | Out-Null
        return
    }

    if ($Fase -eq 'hernoem-plan') {
        $plan = @($sync.RenamePlan)
        if ($sync.RenamePlan -eq $null) { Remove-HernoemVoorbeeld; Write-Log 'Hernoemen gestopt; er is niets veranderd.'; Set-Status 'Hernoemen gestopt.'; return }

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
        if ($nRen + $nDel -eq 0) {
            Remove-HernoemVoorbeeld
            Set-Status 'Hernoemen: alles staat al goed.'
            [System.Windows.MessageBox]::Show(("Er valt niets te hernoemen.`n`n{0} al goed, {1} conflict, {2} overgeslagen." -f $nGoed, $nConf, $nOver),
                'Hernoemen', 'OK', 'Information') | Out-Null
            return
        }

        $m = "In de bronmappen:`n`n" +
             ("  {0} bestand(en) hernoemen`n" -f $nRen) +
             ("  {0} dubbel(en) naar de Prullenbak (op een netwerkschijf zijn ze dan echt weg)`n" -f $nDel) +
             ("  {0} conflict(en) en {1} overgeslagen - die blijven zoals ze zijn`n`n" -f $nConf, $nOver) +
             "Het volledige overzicht staat zolang deze vraag openstaat in:`n$($sync.ScanSettings.PreviewFile)`n(daarna wordt het opgeruimd)`n`nNu uitvoeren?"
        $a = [System.Windows.MessageBox]::Show($m, 'Bronmappen hernoemen', 'YesNo', 'Question')
        Remove-HernoemVoorbeeld
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
    if ($scanBusy -and ([string]$sync.ScanMode) -like 'hernoem*') {
        # Hernoemen heeft geen tellers zoals de scan; alleen de stand.
        $ui.txtScanState.Text = [string]$sync.ScanStatus
        if (-not $convBusy) {
            $ui.txtOverallLabel.Text = 'Hernoemen'
            $ui.pbOverall.IsIndeterminate = $true
            $ui.txtOverallInfo.Text = ''
            $ui.txtCurrentFile.Text = [string]$sync.ScanStatus
            Set-Status ([string]$sync.ScanStatus)
        }
    }
    elseif ($scanBusy) {
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
        $hernoemFase = ''
        if (([string]$sync.ScanMode) -like 'hernoem*') { $hernoemFase = [string]$sync.ScanMode }

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
        elseif ($hernoemFase) {
            $sync.ScanMode = 'scan'
            $ui.pbOverall.IsIndeterminate = $false
            $ui.pbOverall.Value     = 0
            $ui.txtOverallInfo.Text = ''
            $ui.txtOverallLabel.Text = 'Totale voortgang'
            if (-not $convBusy) { $ui.txtCurrentFile.Text = 'Geen actieve conversie' }
            Complete-Hernoemen $hernoemFase
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
