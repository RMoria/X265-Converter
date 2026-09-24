
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
