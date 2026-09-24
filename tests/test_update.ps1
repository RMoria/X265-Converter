# Zelfstandig: deze test laadt testlib niet, dus de paden hier uitzoeken.
$TestDir = $PSScriptRoot
if (-not $TestDir) { $TestDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$SrcDir = Join-Path (Split-Path -Parent $TestDir) 'src'
if (-not (Test-Path (Join-Path $SrcDir 'part2.ps1'))) { $SrcDir = $TestDir }
$AppScript = Join-Path (Split-Path -Parent $TestDir) 'X265-Converter.ps1'
if (-not (Test-Path $AppScript)) { $AppScript = Join-Path $TestDir 'X265-Converter.ps1' }

$ErrorActionPreference = 'Stop'

# De updater zit sinds 1.8 IN X265-Converter.ps1 zelf. Voor het los
# uitproberen van de onderdelen wordt het blok tussen de twee merktekens
# uit het samengestelde script gesneden en apart uitgevoerd.
$heel = Get-Content -Raw $AppScript
$i = $heel.IndexOf('# ==== BIJWERKEN BEGIN ====')
$j = $heel.IndexOf('# ==== BIJWERKEN EIND ====')
if ($i -lt 0 -or $j -lt $i) { throw 'Het bijwerkblok is niet gevonden in X265-Converter.ps1' }
$blokTekst = $heel.Substring($i, $j - $i)

# de aanroep onderaan het blok hoort hier niet mee te draaien
$k = $blokTekst.IndexOf('if ($Bijwerken) {')
if ($k -gt 0) { $blokTekst = $blokTekst.Substring(0, $k) }

$UpdMap = '/tmp/up'
$AlleenKijken = $false; $Opnieuw = $false; $Stil = $false; $GeenGit = $false
if (-not (Test-Path '/tmp/up')) { New-Item -ItemType Directory -Path '/tmp/up' -Force | Out-Null }
Invoke-Expression $blokTekst

# Een echte aanroep gaat via het echte script, precies zoals de starter
# het doet. De map is de map waar het script staat, dus voor een test
# wordt er een kopie in een eigen map gezet.
function Draai-Updater {
    # NIET $Args noemen: dat is een automatische variabele in PowerShell,
    # en dan komt er niets van de meegegeven schakelaars aan.
    param([string]$Map, [string[]]$Argumenten = @())
    $kopie = Join-Path $Map 'X265-Converter.ps1'
    return @(& (Get-Process -Id $PID).Path -NoProfile -File $kopie -Bijwerken @Argumenten 2>&1)
}
function Zet-Versie {
    param([string]$Map, [string]$Versie)
    if (-not (Test-Path -LiteralPath $Map)) { New-Item -ItemType Directory -Path $Map -Force | Out-Null }
    $t = (Get-Content -Raw $AppScript) -replace "(?m)^\`$AppVersion = '[^']+'", "`$AppVersion = '$Versie'"
    Set-Content -LiteralPath (Join-Path $Map 'X265-Converter.ps1') -Value $t -Encoding UTF8
}
function LeesLog {
    param([string]$Pad)
    if (-not (Test-Path -LiteralPath $Pad)) { return @() }
    return @(Get-Content -LiteralPath $Pad)
}
$ok=0;$bad=0
function Check { param([string]$W,[bool]$C,[string]$E='') if($C){$script:ok++;"  OK    $W $E"}else{$script:bad++;"  FOUT  $W $E"} }
function Fresh { param($D) if(Test-Path $D){Remove-Item -Recurse -Force $D}; New-Item -ItemType Directory -Path $D -Force|Out-Null }

'############ BIJWERKEN ############'
''
'--- 1. versienummer uit een script lezen ---'
Fresh '/tmp/up'
@"
# kop
`$AppName    = 'X265 Converter'
`$AppVersion = '1.4'
`$AppDate    = '2026-09-14'
"@ | Set-Content '/tmp/up/goed.ps1'
Set-Content '/tmp/up/geenversie.ps1' '# niets bijzonders'
Check 'leest 1.4'                 ((Get-VersieUitScript '/tmp/up/goed.ps1') -eq [version]'1.4')
Check 'zonder versie -> niets'    ((Get-VersieUitScript '/tmp/up/geenversie.ps1') -eq $null)
Check 'onbestaand -> niets'       ((Get-VersieUitScript '/tmp/up/weg.ps1') -eq $null)
''

'--- 2. tags omrekenen naar versies ---'
foreach ($p in @(@('v1.4','1.4'), @('1.4','1.4'), @('refs/tags/v1.4','1.4'),
                 @('refs/tags/v1.4^{}','1.4'), @('v2.0.1','2.0.1'))) {
    Check "'$($p[0])' -> $($p[1])"  ((ConvertTo-Versie $p[0]) -eq [version]$p[1])
}
foreach ($r in @('', 'rommel', 'v', 'release-kerst', 'v1.4-beta')) {
    Check "'$r' wordt genegeerd"   ((ConvertTo-Versie $r) -eq $null)
}
''

'--- 3. de hoogste tag kiezen ---'
$h = Get-HoogsteTag @('refs/tags/v1.2','refs/tags/v1.10','refs/tags/v1.9','refs/tags/rommel')
Check 'v1.10 wint van v1.9'       ($h -ne $null -and $h.Versie -eq [version]'1.10')   "($($h.Tag))"
Check 'tagnaam blijft leesbaar'   ($h.Tag -eq 'v1.10')
$h2 = Get-HoogsteTag @('refs/tags/v1.4^{}','refs/tags/v1.4')
Check 'het ^{}-restje eraf'       ($h2.Tag -eq 'v1.4')                                 "($($h2.Tag))"
Check 'niets bruikbaars -> niets' ((Get-HoogsteTag @('rommel','main')) -eq $null)
Check 'lege lijst -> niets'       ((Get-HoogsteTag @()) -eq $null)
''

'--- 4. is wat er binnenkwam bruikbaar? ---'
Fresh '/tmp/up/tmp'
Check 'ontbrekend hoofdbestand'   ((Test-Binnengekomen -Tijdelijk '/tmp/up/tmp' -Verwacht ([version]'1.5')) -match 'ontbreekt')

Set-Content '/tmp/up/tmp/X265-Converter.ps1' "`$AppVersion = '1.5'"
Check 'te klein wordt geweigerd'  ((Test-Binnengekomen -Tijdelijk '/tmp/up/tmp' -Verwacht ([version]'1.5')) -match 'kan niet kloppen')

# een echt, groot en geldig script maken
$echt = Get-Content -Raw $AppScript
($echt -replace "(?m)^\`$AppVersion = '[^']+'", "`$AppVersion = '1.5'") | Set-Content '/tmp/up/tmp/X265-Converter.ps1'
Check 'goed bestand wordt goedgekeurd' ((Test-Binnengekomen -Tijdelijk '/tmp/up/tmp' -Verwacht ([version]'1.5')) -eq '')
Check 'verkeerde versie valt op'  ((Test-Binnengekomen -Tijdelijk '/tmp/up/tmp' -Verwacht ([version]'1.9')) -match 'beloofde')

# afgekapte download: groot genoeg, maar onvolledig
$halve = $echt.Substring(0, [int]($echt.Length * 0.6))
($halve -replace "(?m)^\`$AppVersion = '[^']+'", "`$AppVersion = '1.5'") | Set-Content '/tmp/up/tmp/X265-Converter.ps1'
$klacht = Test-Binnengekomen -Tijdelijk '/tmp/up/tmp' -Verwacht ([version]'1.5')
Check 'afgekapte download valt op' ($klacht -match 'syntaxfout')                        "($klacht)"
''

'--- 5. op zijn plek zetten, met vangnet ---'
Fresh '/tmp/up/doel'
Fresh '/tmp/up/nieuw'
($echt -replace "(?m)^\`$AppVersion = '[^']+'", "`$AppVersion = '1.4'") | Set-Content '/tmp/up/doel/X265-Converter.ps1'
Set-Content '/tmp/up/doel/LEESMIJ-X265-Converter.md' 'oude leesmij'
Set-Content '/tmp/up/doel/Bijwerken.ps1'             '# oude updater'
Set-Content '/tmp/up/doel/X265-Converter.cmd'        'oude starter'

($echt -replace "(?m)^\`$AppVersion = '[^']+'", "`$AppVersion = '1.5'") | Set-Content '/tmp/up/nieuw/X265-Converter.ps1'
Set-Content '/tmp/up/nieuw/LEESMIJ-X265-Converter.md' 'nieuwe leesmij'
Set-Content '/tmp/up/nieuw/Bijwerken.ps1'             '# nieuwe updater'
Set-Content '/tmp/up/nieuw/X265-Converter.cmd'        'nieuwe starter'

# een achtergebleven map van voor v1.11 hoort mee opgeruimd te worden
New-Item -ItemType Directory -Path '/tmp/up/doel/vorige-versie' -Force | Out-Null
Set-Content '/tmp/up/doel/vorige-versie/X265-Converter.ps1' 'heel oud'
$klacht = Plaats-Nieuw -Tijdelijk '/tmp/up/nieuw' -Doel '/tmp/up/doel' -Versie ([version]'1.5')
Check 'geen klacht'               ($klacht -eq '')                                      "($klacht)"
Check 'script vervangen'          ((Get-VersieUitScript '/tmp/up/doel/X265-Converter.ps1') -eq [version]'1.5')
Check 'leesmij vervangen'         ((Get-Content -Raw '/tmp/up/doel/LEESMIJ-X265-Converter.md').Trim() -eq 'nieuwe leesmij')
# Bijwerken.ps1 hoort NIET meer in de lijst: de updater zit sinds 1.8 in
# X265-Converter.ps1 zelf. Een los bestand ging bij het overzetten naar
# een tweede pc niet mee, en dat was precies de storing.
Check 'los updaterbestand blijft af' ((Get-Content -Raw '/tmp/up/doel/Bijwerken.ps1').Trim() -eq '# oude updater')
Check 'starter NIET overschreven' ((Get-Content -Raw '/tmp/up/doel/X265-Converter.cmd').Trim() -eq 'oude starter')
Check 'starter klaargezet als .nieuw' (Test-Path '/tmp/up/doel/X265-Converter.cmd.nieuw')
Check 'geen map met de oude versie' (-not (Test-Path '/tmp/up/doel/vorige-versie'))
Check 'terugrol-kopie in de ophaalmap' ((Get-VersieUitScript '/tmp/up/nieuw/_vorige-versie/X265-Converter.ps1') -eq [version]'1.4')
''

'--- 6. gelijke starter wordt niet klaargezet ---'
Remove-Item '/tmp/up/doel/X265-Converter.cmd.nieuw' -Force
Set-Content '/tmp/up/doel/X265-Converter.cmd' 'nieuwe starter'
[void](Plaats-Nieuw -Tijdelijk '/tmp/up/nieuw' -Doel '/tmp/up/doel' -Versie ([version]'1.5'))
Check 'geen overbodige .nieuw'    (-not (Test-Path '/tmp/up/doel/X265-Converter.cmd.nieuw'))
''

'--- 7. mislukt halverwege: alles gaat terug ---'
Fresh '/tmp/up/doel2'
($echt -replace "(?m)^\`$AppVersion = '[^']+'", "`$AppVersion = '1.4'") | Set-Content '/tmp/up/doel2/X265-Converter.ps1'
Set-Content '/tmp/up/doel2/LEESMIJ-X265-Converter.md' 'oude leesmij'
Set-Content '/tmp/up/doel2/Bijwerken.ps1'             '# oude updater'

# Copy-Item overschaduwen zodat de vierde aanroep stukloopt: dat is het
# vervangen van het TWEEDE bestand, nadat het eerste al is vervangen.
$script:Tel = 0
function Copy-Item {
    $script:Tel = $script:Tel + 1
    if ($script:Tel -eq 4) { throw 'schijf vol (nagebootst)' }
    Microsoft.PowerShell.Management\Copy-Item @args
}
$klacht = Plaats-Nieuw -Tijdelijk '/tmp/up/nieuw' -Doel '/tmp/up/doel2' -Versie ([version]'1.5')
Remove-Item function:Copy-Item
Check 'meldt de mislukking'       ($klacht -match 'mislukte')                            "($klacht)"
Check 'meldt het terugzetten'     ($klacht -match 'teruggezet')
Check 'script staat weer op 1.4'  ((Get-VersieUitScript '/tmp/up/doel2/X265-Converter.ps1') -eq [version]'1.4')
''

'--- 8. echt ophalen van GitHub (tag v1.2) ---'
Fresh '/tmp/up/web'
$gelukt = Get-ViaWeb -Eigenaar 'RMoria' -RepoNaam 'X265-Converter' -Tag 'v1.2' -Tijdelijk '/tmp/up/web'
Check 'download gelukt'           ($gelukt)
Check 'script binnengehaald'      (Test-Path '/tmp/up/web/X265-Converter.ps1')
# Bijwerken.ps1 bestond in v1.2 nog niet; dat mag het bijwerken niet tegenhouden
Check 'ontbrekend bijbestand ok'  (-not (Test-Path '/tmp/up/web/Bijwerken.ps1'))
Check 'leesmij binnengehaald'     (Test-Path '/tmp/up/web/LEESMIJ-X265-Converter.md')
Check 'starter binnengehaald'     (Test-Path '/tmp/up/web/X265-Converter.cmd')
$vw = Get-VersieUitScript '/tmp/up/web/X265-Converter.ps1'
Check 'en het is echt v1.2'       ($vw -eq [version]'1.2')                               "($vw)"
Check 'en het is geldig'          ((Test-Binnengekomen -Tijdelijk '/tmp/up/web' -Verwacht ([version]'1.2')) -eq '')
''

'--- 9. bestaat-deze-tag, zonder API ---'
Check 'v1.2 bestaat'              (Test-TagBestaat -Eigenaar 'RMoria' -RepoNaam 'X265-Converter' -Tag 'v1.2')
Check 'v9.9 bestaat niet'         (-not (Test-TagBestaat -Eigenaar 'RMoria' -RepoNaam 'X265-Converter' -Tag 'v9.9'))
$af = Get-TagViaAftellen -Eigenaar 'RMoria' -RepoNaam 'X265-Converter' -Vanaf ([version]'1.0')
Check 'telt omhoog naar de echte' ($af -ne $null -and $af.Versie -ge [version]'1.2')      "($($af.Tag))"
''

'--- 10. een draaiende instantie blokkeert het bijwerken ---'
Check 'niets aan -> niet draaien' (-not (Test-DraaitAl))
''

'--- 11. de starter overschrijft zichzelf niet ---'
$cmd = Get-Content -Raw (Join-Path (Split-Path -Parent $AppScript) 'X265-Converter.cmd')
Check 'wisselt via een hulpje'    ($cmd -match 'x265-wissel\.cmd')
Check 'hulpje wacht eerst'        ($cmd -match 'ping -n 3')
Check 'en sluit meteen af'        ($cmd -match '(?s)x265-wissel\.cmd"\s*\r?\n\s*exit /b 0')
Check 'alleen zonder argumenten'  ($cmd -match 'cmd\.nieuw" if "%~1"==""')
Check 'updater wordt aangeroepen' ($cmd -match '"%PS1%" -Bijwerken')
Check '-GeenUpdate bestaat'       ($cmd -match '"%~1"=="-GeenUpdate"')
$voor = $cmd.IndexOf('x265-wissel.cmd')
$na   = $cmd.IndexOf('-Bijwerken')
Check 'omwisselen komt eerst'     ($voor -gt 0 -and $na -gt $voor)
''
'--- 12. er is altijd een spoor ---'
# De belangrijkste les van 15 september: de updater besliste in stilte.
# Het venster van de starter klapt binnen een seconde dicht, dus zonder
# logboek is "niets gevonden", "kon er niet bij" en "helemaal niet
# gedraaid" niet van elkaar te onderscheiden.
Fresh '/tmp/up/log'
Zet-Versie '/tmp/up/log' '9.9'
$uit = Draai-Updater -Map '/tmp/up/log' -Argumenten @('-Stil')
$logPad = '/tmp/up/log/X265-Bijwerken.log'
Check 'logboek is aangemaakt'      (Test-Path $logPad)
$lg = LeesLog $logPad
Check 'met een startregel'         (($lg -join ' ') -match 'bijwerken gestart')
Check 'en een slotregel'           (($lg -join ' ') -match 'Klaar:')
Check 'met tijdstempel'            ($lg.Count -gt 0 -and $lg[0] -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d ')
Check 'stil = niets op het scherm' (@($uit | Where-Object { "$_".Trim() }).Count -eq 0)  "($(($uit -join '|')))"
# 9.9 is hoger dan alles wat er is, dus er hoort niets te gebeuren
Check 'nieuwere lokale versie blijft' ((Get-VersieUitScript '/tmp/up/log/X265-Converter.ps1') -eq [version]'9.9')
Check 'en dat staat in het logboek'   (($lg -join ' ') -match 'is de nieuwste|Geen nieuwere versie')

# tweede ronde: het logboek moet aangroeien, niet overschreven worden
[void](Draai-Updater -Map '/tmp/up/log' -Argumenten @('-Stil'))
$lg2 = LeesLog $logPad
Check 'logboek groeit aan'         ($lg2.Count -gt $lg.Count)                           "($($lg.Count) -> $($lg2.Count))"
$rondes = @($lg2 | Where-Object { $_ -match 'bijwerken gestart' })
Check 'twee rondes te zien'        ($rondes.Count -eq 2)                                "($($rondes.Count))"
''

'--- 13. een vastloper houdt het starten niet tegen ---'
$b = $heel
Check 'alles in een try'           ($b -match '(?s)\$veranderd = Invoke-Bijwerken.{0,400}catch \{')
Check 'de fout wordt opgeschreven' ($b -match 'Bijwerken liep vast')
Check 'proxy krijgt inloggegevens' ($b -match 'DefaultNetworkCredentials')
Check 'TLS 1.2 wordt gezet'        ($b -match 'SecurityProtocolType\]::Tls12')
''

'--- 14. het programma meldt wat de updater deed ---'
$p8 = Get-Content -Raw $SrcDir/part8.ps1
Check 'leest het logboek'          ($p8 -match 'X265-Bijwerken\.log')
Check 'kijkt of het vers is'       ($p8 -match 'TotalMinutes -lt 5')
Check 'waarschuwt als hij niet liep' ($p8 -match 'bij deze start niet gedraaid')
Check 'en als hij nooit liep'      ($p8 -match 'nog nooit gedraaid')
Check 'toont alleen de laatste ronde' ($p8 -match "bijwerken gestart")
''
'--- 15. van begin tot eind: een oude map echt bijwerken ---'
# Dit is het geval dat op pc2 misging. Een map met een oudere versie, en
# verder niets bijzonders: hij hoort er zelf de nieuwste tag bij te zoeken
# en de bestanden te vervangen.
Fresh '/tmp/up/e2e'
Zet-Versie '/tmp/up/e2e' '1.0'
Set-Content '/tmp/up/e2e/LEESMIJ-X265-Converter.md' 'stokoude leesmij'
Set-Content '/tmp/up/e2e/X265-Converter.cmd'        'stokoude starter'
Check 'begint op 1.0'              ((Get-VersieUitScript '/tmp/up/e2e/X265-Converter.ps1') -eq [version]'1.0')

$uit2 = Draai-Updater -Map '/tmp/up/e2e'
$uit2 | ForEach-Object { "      $_" }
$na = Get-VersieUitScript '/tmp/up/e2e/X265-Converter.ps1'
Check 'is echt bijgewerkt'         ($na -ne $null -and $na -gt [version]'1.0')          "($na)"
Check 'en het is geldig PowerShell' ((Test-Binnengekomen -Tijdelijk '/tmp/up/e2e' -Verwacht $na) -eq '')
Check 'leesmij ook vervangen'      ((Get-Content -Raw '/tmp/up/e2e/LEESMIJ-X265-Converter.md') -notmatch 'stokoude')
Check 'starter niet overschreven'  ((Get-Content -Raw '/tmp/up/e2e/X265-Converter.cmd').Trim() -eq 'stokoude starter')
Check 'maar wel klaargezet'        (Test-Path '/tmp/up/e2e/X265-Converter.cmd.nieuw')
Check 'geen oude versie ernaast'   (-not (Test-Path '/tmp/up/e2e/vorige-versie'))
Check 'geen los updaterbestand'    (-not (Test-Path '/tmp/up/e2e/Bijwerken.ps1'))
Check 'staat in het logboek'       (((LeesLog '/tmp/up/e2e/X265-Bijwerken.log') -join ' ') -match 'Bijgewerkt naar versie')

# tweede keer draaien mag niets meer doen
$voor = (Get-Item '/tmp/up/e2e/X265-Converter.ps1').LastWriteTime
Start-Sleep -Milliseconds 1200
[void](Draai-Updater -Map '/tmp/up/e2e' -Argumenten @('-Stil'))
Check 'tweede keer: niets gedaan'  ((Get-Item '/tmp/up/e2e/X265-Converter.ps1').LastWriteTime -eq $voor)
''
"====> $ok goed, $bad fout"
