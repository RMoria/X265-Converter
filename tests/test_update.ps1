$ErrorActionPreference = 'Stop'
$env:X265_BIJWERKEN_ALLEEN_LADEN = '1'
. /tmp/build/Bijwerken.ps1
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
$echt = Get-Content -Raw /tmp/build/X265-Converter.ps1
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

$klacht = Plaats-Nieuw -Tijdelijk '/tmp/up/nieuw' -Doel '/tmp/up/doel' -Versie ([version]'1.5')
Check 'geen klacht'               ($klacht -eq '')                                      "($klacht)"
Check 'script vervangen'          ((Get-VersieUitScript '/tmp/up/doel/X265-Converter.ps1') -eq [version]'1.5')
Check 'leesmij vervangen'         ((Get-Content -Raw '/tmp/up/doel/LEESMIJ-X265-Converter.md').Trim() -eq 'nieuwe leesmij')
Check 'updater vervangen'         ((Get-Content -Raw '/tmp/up/doel/Bijwerken.ps1').Trim() -eq '# nieuwe updater')
Check 'starter NIET overschreven' ((Get-Content -Raw '/tmp/up/doel/X265-Converter.cmd').Trim() -eq 'oude starter')
Check 'starter klaargezet als .nieuw' (Test-Path '/tmp/up/doel/X265-Converter.cmd.nieuw')
Check 'vorige versie bewaard'     ((Get-VersieUitScript '/tmp/up/doel/vorige-versie/X265-Converter.ps1') -eq [version]'1.4')
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
$cmd = Get-Content -Raw /tmp/build/X265-Converter.cmd
Check 'wisselt via een hulpje'    ($cmd -match 'x265-wissel\.cmd')
Check 'hulpje wacht eerst'        ($cmd -match 'ping -n 3')
Check 'en sluit meteen af'        ($cmd -match '(?s)x265-wissel\.cmd"\s*\r?\n\s*exit /b 0')
Check 'alleen zonder argumenten'  ($cmd -match 'cmd\.nieuw" if "%~1"==""')
Check 'updater wordt aangeroepen' ($cmd -match 'Bijwerken\.ps1"')
Check '-GeenUpdate bestaat'       ($cmd -match '"%~1"=="-GeenUpdate"')
$voor = $cmd.IndexOf('x265-wissel.cmd')
$na   = $cmd.IndexOf('Bijwerken.ps1')
Check 'omwisselen komt eerst'     ($voor -gt 0 -and $na -gt $voor)
''
"====> $ok goed, $bad fout"
