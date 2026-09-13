<#
    Controleer-Geluid.ps1
    ---------------------
    Zoekt in de uitvoer van X265-Converter naar twee gebreken in het
    geluid, die beide door '-c:a copy' konden ontstaan:

      1. AUDIO STOPT - de audiotrack houdt ergens halverwege op en komt
         niet meer terug. De video loopt door. Dit is NIET met een remux
         te repareren: de pakketten zijn er niet meer. Opnieuw omzetten
         vanaf het origineel is de enige weg.

      2. GAT of SPRONG in de tijdstempels - de pakketten zijn er wel,
         maar hun tijdstempels maken een sprong vooruit (gat) of achteruit
         (non-monotoon). Spelers laten de audiotrack daar vaak vallen.
         Dit IS te repareren zonder de video opnieuw te encoderen.

    Twee rondes, want ze kosten niet hetzelfde:

      SNELLE RONDE (standaard) - kijkt of het geluid het einde van de film
      haalt. Kost ongeveer 1 tot 3 MB per bestand, want er wordt naar de
      staart gesprongen in plaats van alles te lezen. Duizend bestanden
      is dus minuten, geen uren.
      Belangrijk detail: '-select_streams' mag hier NIET bij. Dat blokkeert
      de seek en dan leest ffprobe alsnog het hele bestand (nagemeten:
      13,4 MB in plaats van 0,6 MB op hetzelfde bestand).

      VOLLEDIGE RONDE (-Volledig) - loopt alle audiopakketten langs en
      vindt ook gaten en sprongen midden in het bestand. Daarvoor moet
      ffprobe het bestand wel volledig demuxen; er is geen goedkopere
      manier. Nagemeten: een steekproef met -read_intervals over het hele
      bestand leest nog altijd tweederde, dus dat schiet niet op.

    Gebruik:
      .\Controleer-Geluid.ps1 -Path 'D:\Films'                  # snelle ronde
      .\Controleer-Geluid.ps1 -Path 'D:\Films' -Volledig        # ook gaten zoeken
      .\Controleer-Geluid.ps1 -Path 'D:\Films' -Volledig -Herstel
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $Path,

    [switch]   $Herstel,

    # Ook de dure ronde doen: alle audiopakketten langs voor gaten en
    # sprongen midden in het bestand.
    [switch]   $Volledig,

    # Vanaf welk gat (vooruit) of sprong (achteruit) in de tijdstempels
    # een bestand verdacht is. Alleen van belang met -Volledig.
    [double]   $Drempel   = 0.5,

    # Hoeveel seconden het geluid mag achterblijven op de speelduur van
    # het bestand voordat het 'AUDIO STOPT' heet.
    [double]   $EindDrempel = 5,

    # Hoe groot het staartvenster is dat de snelle ronde bekijkt.
    [double]   $Staart    = 20,

    [ValidateSet('aac','ac3','flac')]
    [string]   $Codec     = 'aac',

    # Leeg = de exacte regel: de basisnaam eindigt op '.x265', eventueel met
    # '(2)' erachter van een naamsbotsing. Precies zoals de converter zijn
    # uitvoer noemt, en niets anders.
    #
    # Dit is met twee stappen scherp geworden. Eerst stond het op '*x265*':
    # daar vallen alle release-namen onder ('...1080p.x265-ELiTE.mkv',
    # 'HEVC x265 BONE'), en in een eerste ronde ging daardoor de helft van
    # het werk naar bestanden die de converter nooit heeft aangeraakt.
    # Daarna '*.x265.*': beter, maar daar glipt '...6CH.x265.HEVC-PSA.mkv'
    # nog door, want dat heeft '.x265.' middenin. Alleen wat er OP eindigt
    # is echt eigen uitvoer.
    #
    # Zelf een patroon opgeven kan nog wel; dan wordt dat als wildcard op de
    # bestandsnaam gebruikt. -Alles zet het filter helemaal uit.
    [string]   $Patroon   = '',
    [switch]   $Alles,

    [string[]] $Extensies = @('mkv','mp4','m4v','mov'),
    [bool]     $Recursief = $true,

    [int]      $Max       = 0,        # 0 = geen limiet
    [switch]   $Opnieuw,              # rapport negeren, alles opnieuw
    [switch]   $Ja,                   # niet om bevestiging vragen
    [string]   $Rapport   = '',

    # Na een geverifieerd herstel wordt de oude versie WEGGEGOOID. Dat is
    # het standaardgedrag: geen *.origineel.*-bestanden laten rondslingeren
    # en geen dubbele schijfruimte. Weggooien gebeurt alleen nadat het
    # nieuwe bestand is nagemeten en het gat echt weg is.
    # -BewaarOrigineel zet de oude versie wel apart, voor wie eerst wil
    # vergelijken.
    [switch]   $BewaarOrigineel,

    # Minimaal vrij te houden ruimte op de doelschijf, in GB. Is er minder
    # vrij dan het bestand groot is plus deze marge, dan wordt het bestand
    # overgeslagen in plaats van de schijf vol te schrijven.
    [double]   $MinVrijGB = 5
)

$ErrorActionPreference = 'Stop'

# ---- ffmpeg / ffprobe vinden -----------------------------------------
$here = $PSScriptRoot
if ([string]::IsNullOrEmpty($here)) { $here = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$ffmpeg  = Join-Path $here 'ffmpeg\bin\ffmpeg.exe'
$ffprobe = Join-Path $here 'ffmpeg\bin\ffprobe.exe'
if (-not (Test-Path -LiteralPath $ffmpeg))  { $ffmpeg  = 'ffmpeg' }
if (-not (Test-Path -LiteralPath $ffprobe)) { $ffprobe = 'ffprobe' }
if ([string]::IsNullOrWhiteSpace($Rapport)) { $Rapport = Join-Path $here 'Controleer-Geluid.rapport.csv' }

# ---- kleine hulpjes --------------------------------------------------
function Fmt-Size {
    param([double]$B)
    if ($B -ge 1PB) { return ('{0:N2} PB' -f ($B / 1PB)) }
    if ($B -ge 1TB) { return ('{0:N2} TB' -f ($B / 1TB)) }
    if ($B -ge 1GB) { return ('{0:N2} GB' -f ($B / 1GB)) }
    if ($B -ge 1MB) { return ('{0:N1} MB' -f ($B / 1MB)) }
    return ('{0:N0} KB' -f ($B / 1KB))
}
function Fmt-Span {
    param([double]$Sec)
    if ($Sec -lt 0 -or [double]::IsNaN($Sec) -or [double]::IsInfinity($Sec)) { return '?' }
    $t = [TimeSpan]::FromSeconds([Math]::Round($Sec))
    if ($t.TotalDays -ge 1) { return ('{0}d {1:00}:{2:00}:{3:00}' -f [int]$t.TotalDays, $t.Hours, $t.Minutes, $t.Seconds) }
    return ('{0:00}:{1:00}:{2:00}' -f [int]$t.TotalHours, $t.Minutes, $t.Seconds)
}

function Get-FreeSpace {
    param([string]$ForPath)

    # Werkt voor een gewone letter en voor een UNC-pad; bij twijfel wordt
    # -1 teruggegeven en dan wordt de controle overgeslagen in plaats van
    # onterecht te blokkeren.
    try {
        $root = [IO.Path]::GetPathRoot($ForPath)
        if ([string]::IsNullOrWhiteSpace($root)) { return -1 }
        $d = New-Object System.IO.DriveInfo $root
        if ($d.IsReady) { return [double]$d.AvailableFreeSpace }
    }
    catch { }

    try {
        $q = Get-WmiObject -Class Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f ([IO.Path]::GetPathRoot($ForPath)).TrimEnd('\\')) -ErrorAction Stop
        if ($q -and $q.FreeSpace) { return [double]$q.FreeSpace }
    }
    catch { }

    return -1
}

function Inv {
    param([double]$V)
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.###}', $V)
}
function ToNum {
    param([string]$T)
    $d = 0.0
    if ([double]::TryParse($T, [Globalization.NumberStyles]::Float,
                           [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return [double]::NaN
}

# ---------------------------------------------------------------------
#  Goedkoop: speelduur en de audiostream uit de kop van het bestand
# ---------------------------------------------------------------------
function Get-AudioFacts {
    param([string]$File)

    $aa = @('-v','error',
            '-show_entries','format=duration',
            '-show_entries','stream=index,codec_type,codec_name,channels',
            '-of','json',$File)

    try   { $raw = (& $ffprobe @aa 2>$null) -join "`n" }
    catch { return $null }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try   { $j = $raw | ConvertFrom-Json }
    catch { return $null }

    $dur = ToNum ([string]$j.format.duration)

    $ai = -1; $ac = ''; $ach = 0
    foreach ($st in @($j.streams)) {
        if ([string]$st.codec_type -eq 'audio') {
            $ai  = [int]$st.index
            $ac  = [string]$st.codec_name
            if ($st.channels) { $ach = [int]$st.channels }
            break
        }
    }

    return [pscustomobject]@{
        DurationSec = $dur
        AudioIndex  = $ai
        AudioCodec  = $ac
        Channels    = $ach
    }
}

# ---------------------------------------------------------------------
#  Snelle ronde: haalt het geluid het einde van de film?
#
#  Er wordt naar de staart van het bestand gesprongen. Cruciaal: GEEN
#  '-select_streams' erbij. Met die optie negeert ffprobe de seek en
#  leest het het hele bestand alsnog (nagemeten: 13,4 MB tegen 0,6 MB).
#  Daarom komen alle pakketten binnen met hun stream_index ervoor en
#  wordt er hier op index gefilterd.
# ---------------------------------------------------------------------
function Get-AudioEnd {
    param([string]$File, [int]$AudioIndex, [double]$DurationSec, [double]$WindowSec)

    if ($AudioIndex -lt 0) { return $null }
    if ([double]::IsNaN($DurationSec) -or $DurationSec -le 0) { return $null }

    $start = $DurationSec - $WindowSec
    if ($start -lt 0) { $start = 0 }
    $iv = ('{0}%+{1}' -f (Inv $start), (Inv ($WindowSec + 5)))

    $aa = @('-v','error','-read_intervals',$iv,'-show_packets',
            '-show_entries','packet=stream_index,pts_time','-of','csv=p=0',$File)

    try   { $lines = @(& $ffprobe @aa 2>$null) }
    catch { return $null }

    $max = [double]::NaN
    foreach ($l in $lines) {
        $parts = ([string]$l).Split(',')
        if ($parts.Count -lt 2) { continue }
        $ix = 0
        if (-not [int]::TryParse($parts[0].Trim(), [ref]$ix)) { continue }
        if ($ix -ne $AudioIndex) { continue }
        $t = ToNum $parts[1]
        if ([double]::IsNaN($t)) { continue }
        if ([double]::IsNaN($max) -or $t -gt $max) { $max = $t }
    }

    if ([double]::IsNaN($max)) {
        # geen enkel audiopakket in de staart: het stopt eerder dan het
        # venster, maar hoeveel eerder weten we zo niet
        return [pscustomobject]@{ EndSec = [double]::NaN; ShortSec = $WindowSec; Exact = $false }
    }
    return [pscustomobject]@{ EndSec = $max; ShortSec = ($DurationSec - $max); Exact = $true }
}

# ---------------------------------------------------------------------
#  Volledige ronde: alle audiopakketten langs
#
#  Zoekt zowel een sprong vooruit (gat) als achteruit (non-monotone
#  tijdstempels). Die tweede werd eerder helemaal niet gemeten, want de
#  vergelijking keek alleen naar positieve verschillen.
# ---------------------------------------------------------------------
function Get-AudioTimeline {
    param([string]$File)

    $aa = @('-v','error','-select_streams','a:0','-show_packets',
            '-show_entries','packet=pts_time,duration_time','-of','csv=p=0',$File)

    $prev = $null; $gap = 0.0; $gapAt = 0.0; $back = 0.0; $backAt = 0.0
    $count = 0; $last = [double]::NaN

    try { $lines = @(& $ffprobe @aa 2>$null) } catch { return $null }

    foreach ($l in $lines) {
        $parts = ([string]$l).Split(',')
        if ($parts.Count -lt 1) { continue }

        $t = ToNum $parts[0]
        if ([double]::IsNaN($t)) { continue }
        $d = 0.0
        if ($parts.Count -ge 2) { $d = ToNum $parts[1]; if ([double]::IsNaN($d)) { $d = 0.0 } }

        $count++
        if ($prev -ne $null) {
            $delta = $t - $prev
            if ($delta -gt $gap)      { $gap  = $delta;  $gapAt  = $prev }
            if ((-$delta) -gt $back)  { $back = -$delta; $backAt = $prev }
        }
        $prev = $t + $d
        if ([double]::IsNaN($last) -or $t -gt $last) { $last = $t }
    }

    if ($count -lt 1) { return $null }
    return [pscustomobject]@{
        Gap = $gap; GapAt = $gapAt; Back = $back; BackAt = $backAt
        Packets = $count; LastPts = $last
    }
}

function Repair-Audio {
    param([string]$File, [string]$AudioCodec)

    $dir  = [IO.Path]::GetDirectoryName($File)
    $name = [IO.Path]::GetFileNameWithoutExtension($File)
    $ext  = [IO.Path]::GetExtension($File)
    $tmp  = Join-Path $dir ($name + '.hersteld' + $ext)

    # Tijdens het herstel staat het bestand twee keer op de schijf. Eerst
    # kijken of dat past, want een schijf die halverwege volloopt laat een
    # halve kopie achter en breekt de rest van de ronde af.
    $need = [double]((Get-Item -LiteralPath $File).Length) + ([double]$MinVrijGB * 1GB)
    $free = Get-FreeSpace $File
    if ($free -ge 0 -and $free -lt $need) {
        return ('overgeslagen: te weinig vrije ruimte ({0} vrij, {1} nodig)' -f (Fmt-Size $free), (Fmt-Size $need))
    }

    $aa = New-Object System.Collections.ArrayList
    foreach ($x in @('-hide_banner','-nostdin','-loglevel','error','-y','-i',$File,
                     '-map','0','-c','copy','-c:a',$AudioCodec)) { [void]$aa.Add($x) }
    if ($AudioCodec -eq 'aac') { foreach ($x in @('-b:a','192k')) { [void]$aa.Add($x) } }
    if ($AudioCodec -eq 'ac3') { foreach ($x in @('-b:a','448k')) { [void]$aa.Add($x) } }
    foreach ($x in @('-af','aresample=async=1:first_pts=0',$tmp)) { [void]$aa.Add($x) }

    & $ffmpeg @aa 2>&1 | ForEach-Object { Write-Host ('       ffmpeg: ' + $_) -ForegroundColor DarkYellow }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmp)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return 'ffmpeg mislukt'
    }

    # eerst nameten, dan pas het origineel laten wijken
    $na = Get-AudioTimeline $tmp
    if ($na -eq $null -or $na.Gap -gt $Drempel -or $na.Back -gt $Drempel) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return 'gat niet verholpen, origineel ongemoeid gelaten'
    }

    # ---- omwisselen, met terugdraaien als de tweede stap mislukt ----
    #
    # Dit ging eerder fout: lukte stap 1 (origineel -> .origineel) maar
    # stap 2 niet (bijvoorbeeld omdat een speler of virusscanner het
    # bestand vasthoudt), dan bestond de verwachte bestandsnaam niet meer
    # en stond de film onder een andere naam in de bibliotheek. Nu wordt
    # stap 1 in dat geval teruggedraaid.
    $oud     = Join-Path $dir ($name + '.origineel' + $ext)
    $stap1Ok = $false

    try {
        Move-Item -LiteralPath $File -Destination $oud -Force
        $stap1Ok = $true
        Move-Item -LiteralPath $tmp -Destination $File -Force
    }
    catch {
        $msg = $_.Exception.Message
        if ($stap1Ok -and -not (Test-Path -LiteralPath $File)) {
            try {
                Move-Item -LiteralPath $oud -Destination $File -Force
                $msg = $msg + ' (oorspronkelijke naam is teruggezet)'
            }
            catch {
                $msg = $msg + (' - LET OP: het origineel staat nu als {0} en moet met de hand worden teruggenoemd' -f [IO.Path]::GetFileName($oud))
            }
        }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return ('omwisselen mislukt: ' + $msg)
    }

    if ($BewaarOrigineel) {
        return ('hersteld (gat nu {0:N3} s); oude versie als {1}' -f $na.Gap, [IO.Path]::GetFileName($oud))
    }

    # Standaard: de oude versie gaat weg. Dit punt is pas bereikt nadat het
    # nieuwe bestand is nagemeten (het gat is echt verholpen) en het onder
    # de oorspronkelijke naam staat. Lukt het verwijderen niet, dan is dat
    # geen mislukt herstel - het bestand is goed - maar het wordt wel
    # gemeld en het staat in het rapport.
    try {
        Remove-Item -LiteralPath $oud -Force
        return ('hersteld (gat nu {0:N3} s); oude versie verwijderd' -f $na.Gap)
    }
    catch {
        return ('hersteld (gat nu {0:N3} s); LET OP: oude versie {1} kon niet worden verwijderd: {2}' -f `
                    $na.Gap, [IO.Path]::GetFileName($oud), $_.Exception.Message)
    }
}

# =====================================================================
#  1. kop
# =====================================================================
$exts = @($Extensies | ForEach-Object { '.' + (([string]$_).TrimStart('.').ToLowerInvariant()) })
$filt = if ($Alles) { '(alles - ook bestanden die de converter nooit zag)' }
        elseif ([string]::IsNullOrWhiteSpace($Patroon)) { 'basisnaam eindigt op .x265' }
        else { $Patroon }

Write-Host ''
Write-Host '=============================================================' -ForegroundColor Cyan
Write-Host ' Controle op gaten in de audio-tijdstempels'                   -ForegroundColor Cyan
Write-Host '=============================================================' -ForegroundColor Cyan
if ($Herstel) {
    Write-Host ' Modus      : HERSTELLEN (bestanden worden aangepast)' -ForegroundColor Yellow
    if ($BewaarOrigineel) { Write-Host ' Oude versie: blijft staan als *.origineel.* (kost dubbele ruimte)' -ForegroundColor Yellow }
    else                  { Write-Host ' Oude versie: wordt verwijderd zodra het herstel is nagemeten' }
    Write-Host (' Ruimtemarge: minimaal {0:N0} GB vrij houden' -f $MinVrijGB)
}
else { Write-Host ' Modus      : alleen kijken, niets wordt aangepast' -ForegroundColor Green }
if ($Volledig) { Write-Host ' Ronde      : VOLLEDIG - elk bestand wordt helemaal gelezen' -ForegroundColor Yellow }
else           { Write-Host ' Ronde      : snel - alleen kijken of het geluid het einde haalt' -ForegroundColor Green  }
Write-Host (' Naamfilter : {0}'  -f $filt)
Write-Host (' Extensies  : {0}'  -f ($exts -join ' '))
Write-Host (' Drempel    : {0} s' -f $Drempel)
Write-Host (' Audiocodec : {0}'  -f $Codec)
Write-Host (' Rapport    : {0}'  -f $Rapport)
Write-Host ''

# =====================================================================
#  2. bestanden zoeken (met zichtbare voortgang: UNC is traag)
# =====================================================================
$files = New-Object System.Collections.ArrayList
$totalBytes = [double]0

foreach ($p in $Path) {
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host (' NIET GEVONDEN : {0}' -f $p) -ForegroundColor Red
        continue
    }
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        $it = Get-Item -LiteralPath $p
        [void]$files.Add($it); $totalBytes += $it.Length
        Write-Host (' los bestand   : {0}' -f $p)
        continue
    }

    Write-Host (' zoeken in     : {0} ...' -f $p) -NoNewline
    $n = 0; $b = [double]0
    $gci = @{ LiteralPath = $p; File = $true; ErrorAction = 'SilentlyContinue' }
    if ($Recursief) { $gci['Recurse'] = $true }

    foreach ($f in (Get-ChildItem @gci)) {
        if ($exts -notcontains $f.Extension.ToLowerInvariant()) { continue }
        # veiligheidskopieen van een eerdere herstelronde overslaan
        if ($f.Name -match '(?i)\.origineel\.[a-z0-9]+$') { continue }
        if ($f.Name -match '(?i)\.hersteld\.[a-z0-9]+$')  { continue }
        if (-not $Alles) {
            if ([string]::IsNullOrWhiteSpace($Patroon)) {
                $basis = [IO.Path]::GetFileNameWithoutExtension($f.Name)
                if ($basis -notmatch '(?i)\.x265( \(\d+\))?$') { continue }
            }
            elseif ($f.Name -notlike $Patroon) { continue }
        }
        [void]$files.Add($f); $n++; $b += $f.Length
    }
    Write-Host (' {0} bestand(en), {1}' -f $n, (Fmt-Size $b))
    $totalBytes += $b
}

if ($files.Count -lt 1) {
    Write-Host ''
    Write-Host ' Niets gevonden om na te kijken.' -ForegroundColor Yellow
    if (-not $Alles) { Write-Host (' Het naamfilter staat op: {0}. Gebruik -Alles om alles mee te nemen.' -f $filt) }
    Write-Host ''
    return
}

# =====================================================================
#  3. rapport: wat is al gedaan (zodat een afgebroken ronde verdergaat)
# =====================================================================
$done = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if ((Test-Path -LiteralPath $Rapport) -and -not $Opnieuw) {
    try {
        $oudRap = @(Import-Csv -LiteralPath $Rapport -Delimiter ';')
        if ($oudRap.Count -gt 0 -and ($oudRap[0].PSObject.Properties.Name -notcontains 'AudioTotSec')) {
            Write-Host ' Het bestaande rapport komt van een oudere versie die de controle op'   -ForegroundColor Yellow
            Write-Host ' "audio stopt" nog niet deed. Die uitkomsten zijn niet te vertrouwen,'  -ForegroundColor Yellow
            Write-Host ' dus wordt er opnieuw begonnen. Het oude rapport blijft staan als .oud' -ForegroundColor Yellow
            try { Move-Item -LiteralPath $Rapport -Destination ($Rapport + '.oud') -Force } catch { }
        }
        else {
            foreach ($r in $oudRap) { if ($r.Pad) { [void]$done.Add([string]$r.Pad) } }
        }
    }
    catch { Write-Host (' Rapport niet leesbaar, wordt genegeerd: {0}' -f $_.Exception.Message) -ForegroundColor Yellow }
}
if ($Opnieuw -and (Test-Path -LiteralPath $Rapport)) {
    Remove-Item -LiteralPath $Rapport -Force -ErrorAction SilentlyContinue
}

$todo = New-Object System.Collections.ArrayList
$todoBytes = [double]0
foreach ($f in $files) {
    if ($done.Contains($f.FullName)) { continue }
    [void]$todo.Add($f); $todoBytes += $f.Length
    if ($Max -gt 0 -and $todo.Count -ge $Max) { break }
}

Write-Host ''
Write-Host (' Gevonden        : {0} bestand(en), {1}' -f $files.Count, (Fmt-Size $totalBytes))
if ($done.Count -gt 0) {
    Write-Host (' Al eerder gedaan: {0} (uit het rapport, worden overgeslagen)' -f $done.Count) -ForegroundColor DarkGray
}
if ($Max -gt 0) { Write-Host (' Limiet -Max     : {0}' -f $Max) -ForegroundColor DarkGray }
Write-Host (' Nu na te kijken : {0} bestand(en), {1}' -f $todo.Count, (Fmt-Size $todoBytes)) -ForegroundColor Cyan

if ($todo.Count -lt 1) {
    Write-Host ''
    Write-Host ' Alles staat al in het rapport. Gebruik -Opnieuw om opnieuw te beginnen.' -ForegroundColor Green
    Write-Host ''
    return
}

# =====================================================================
#  4. eerlijke waarschuwing vooraf
# =====================================================================
Write-Host ''
Write-Host ' Waar de tijd in gaat:' -ForegroundColor Yellow
if ($Volledig) {
    Write-Host ' Om gaten en sprongen midden in het bestand te zien moet ffprobe het'
    Write-Host ' bestand volledig demuxen. Er is geen goedkopere manier: een steekproef'
    Write-Host ' leest nog altijd tweederde. Elke byte hierboven gaat dus over de lijn.'
    Write-Host ''
    foreach ($mbs in @(50, 100, 200)) {
        Write-Host ('   bij {0,3} MB/s  ->  ongeveer {1}' -f $mbs, (Fmt-Span ($todoBytes / ($mbs * 1MB))))
    }
}
else {
    Write-Host ' De snelle ronde springt naar de staart van elk bestand en leest daar'
    Write-Host (' alleen een venster van {0:N0} seconden. Dat kost grofweg 1 tot 3 MB per' -f $Staart)
    Write-Host ' bestand in plaats van de hele film, dus dit is een kwestie van minuten.'
    Write-Host ' Wat het NIET ziet: een gat of sprong midden in het bestand. Daarvoor is'
    Write-Host ' -Volledig nodig, en dat leest alles.'
}
Write-Host ''
if ($Herstel -and $Volledig) {
    $vrij = Get-FreeSpace ([string]$todo[0].FullName)
    Write-Host ' Schijfruimte bij herstellen:' -ForegroundColor Yellow
    if ($BewaarOrigineel) {
        Write-Host ' -BewaarOrigineel staat aan: een hersteld bestand blijft twee keer op de'
        Write-Host ' schijf staan, de nieuwe versie en de oude als *.origineel.*. In het'
        Write-Host (' slechtste geval (alles heeft een gat) is dat {0} extra.' -f (Fmt-Size $todoBytes))
    }
    else {
        Write-Host ' Tijdens het herstel staat een bestand kort twee keer op de schijf; zodra'
        Write-Host ' het nieuwe bestand is nagemeten gaat de oude versie weg. Er is dus alleen'
        Write-Host ' tijdelijk ruimte nodig, ter grootte van het grootste bestand.'
    }
    if ($vrij -ge 0) { Write-Host (' Nu vrij op de doelschijf: {0}' -f (Fmt-Size $vrij)) }
    Write-Host ' Past het voor een bestand niet binnen de marge, dan wordt dat bestand'
    Write-Host ' overgeslagen. Er wordt nooit half geschreven.'
    Write-Host ''
}
Write-Host ' Ctrl-C mag altijd. Wat al is nagekeken staat in het rapport en wordt'
Write-Host ' bij een volgende ronde overgeslagen.'
Write-Host ''

if ($Herstel -and -not $Volledig) {
    Write-Host ''
    Write-Host ' LET OP: -Herstel doet in de snelle ronde niets.' -ForegroundColor Yellow
    Write-Host ' Wat de snelle ronde vindt (AUDIO STOPT) is niet met een remux te'
    Write-Host ' repareren: die audiopakketten staan niet meer in het bestand. Zulke'
    Write-Host ' bestanden moeten opnieuw worden omgezet vanaf het origineel.'
    Write-Host ' Repareren gebeurt alleen in de volledige ronde, aan gaten en sprongen.'
    Write-Host ''
}

if (-not $Ja) {
    $antw = Read-Host ' Doorgaan? [J/N]'
    if ($antw -notmatch '^(j|ja|y|yes)$') { Write-Host ' Afgebroken.'; Write-Host ''; return }
    Write-Host ''
}

# =====================================================================
#  5. doorlopen
# =====================================================================
$sw        = [Diagnostics.Stopwatch]::StartNew()
$doneBytes = [double]0
$verdacht  = 0
$schoon    = 0
$geenAud   = 0
$niet      = 0
$hersteld  = 0
$n         = 0
$lastLine  = [double]0

foreach ($f in $todo) {
    $n++

    # Geen [Math]::Max met een kaal geheel getal als eerste argument:
    # Windows PowerShell kiest dan de Int32-overload en struikelt op een
    # bytetotaal boven de 2 GB ("Value was either too large or too small
    # for an Int32"). Bovendien rondde dat het percentage af via een int.
    # Gewone vergelijkingen doen hier hetzelfde werk zonder verrassingen.
    $noemer = [double]$todoBytes
    if ($noemer -lt 1) { $noemer = 1 }
    $pct = 100.0 * ([double]$doneBytes) / $noemer
    if ($pct -lt 0)   { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }

    $el    = $sw.Elapsed.TotalSeconds
    $mbs   = if ($el -gt 1) { ($doneBytes / 1MB) / $el } else { 0 }
    $eta   = if ($mbs -gt 0.01) { (($todoBytes - $doneBytes) / 1MB) / $mbs } else { -1 }
    if ($mbs -gt 0.01) {
        $stTxt = '{0}/{1}  {2}  {3:N0} MB/s  verstreken {4}  resterend ~{5}' -f `
                    $n, $todo.Count, (Fmt-Size $doneBytes), $mbs, (Fmt-Span $el), (Fmt-Span $eta)
    } else {
        $stTxt = '{0}/{1}  snelheid nog onbekend' -f $n, $todo.Count
    }

    Write-Progress -Activity 'Audio-tijdstempels nakijken' `
                   -Status $stTxt -CurrentOperation $f.FullName `
                   -PercentComplete ([int]$pct)

    # elke 15 s ook een gewone regel, zodat het venster niet dood lijkt
    if (($el - $lastLine) -ge 15 -or $n -eq 1) {
        $lastLine = $el
        Write-Host ('  ..  {0}   |  {1} verdacht, {2} in orde' -f $stTxt, $verdacht, $schoon) -ForegroundColor DarkGray
    }

    # ---- 1. goedkoop: duur en audiostream uit de kop ----
    $fa = Get-AudioFacts $f.FullName

    $verdict = 'in orde'
    $actie   = ''
    $durTxt = ''; $codTxt = ''; $chTxt = ''
    $endTxt = ''; $shortTxt = ''
    $gapTxt = ''; $gapAtTxt = ''; $backTxt = ''

    if ($fa -eq $null) {
        $niet++
        $verdict = 'niet leesbaar'
    }
    elseif ($fa.AudioIndex -lt 0) {
        $geenAud++
        $verdict = 'geen audiospoor'
    }
    else {
        $codTxt = $fa.AudioCodec
        if ($fa.Channels -gt 0) { $chTxt = [string]$fa.Channels }
        if (-not [double]::IsNaN($fa.DurationSec)) { $durTxt = ('{0:N1}' -f $fa.DurationSec) }

        # ---- 2. snelle ronde: haalt het geluid het einde? ----
        $ae = Get-AudioEnd $f.FullName $fa.AudioIndex $fa.DurationSec $Staart
        $stopt = $false

        if ($ae -ne $null) {
            if ($ae.Exact) {
                $endTxt   = ('{0:N1}' -f $ae.EndSec)
                $shortTxt = ('{0:N1}' -f $ae.ShortSec)
                if ($ae.ShortSec -gt $EindDrempel) { $stopt = $true }
            }
            else {
                $endTxt   = 'niet in de staart'
                $shortTxt = ('>{0:N0}' -f $ae.ShortSec)
                $stopt = $true
            }
        }

        if ($stopt) {
            $verdacht++
            $verdict = 'AUDIO STOPT'
            Write-Host ('  AUDIO STOPT  geluid tot {0} s van {1} s  ({2} s tekort)   {3}' -f `
                            $endTxt, $durTxt, $shortTxt, $f.FullName) -ForegroundColor Red
            # Niet met een remux te repareren: die pakketten zijn er niet.
            $actie = 'niet te repareren met een remux - opnieuw omzetten vanaf het origineel'
            if ($Herstel) { Write-Host ('       -> ' + $actie) -ForegroundColor DarkYellow }
        }
        elseif ($Volledig) {
            # ---- 3. dure ronde: gaten en sprongen ----
            $r = Get-AudioTimeline $f.FullName
            if ($r -eq $null) {
                $niet++
                $verdict = 'niet leesbaar'
            }
            else {
                $gapTxt   = ('{0:N3}' -f $r.Gap)
                $gapAtTxt = ('{0:N1}' -f $r.GapAt)
                $backTxt  = ('{0:N3}' -f $r.Back)

                if ($r.Gap -gt $Drempel -or $r.Back -gt $Drempel) {
                    $verdacht++
                    if ($r.Back -gt $Drempel -and $r.Back -ge $r.Gap) {
                        $verdict = 'SPRONG'
                        Write-Host ('  SPRONG {0,8} s terug op {1,9} s   {2}' -f $backTxt, ('{0:N1}' -f $r.BackAt), $f.FullName) -ForegroundColor Yellow
                    }
                    else {
                        $verdict = 'GAT'
                        Write-Host ('  GAT    {0,8} s op {1,9} s   {2}' -f $gapTxt, $gapAtTxt, $f.FullName) -ForegroundColor Yellow
                    }

                    if ($Herstel) {
                        $actie = Repair-Audio $f.FullName $Codec
                        if ($actie -like 'hersteld*') { $hersteld++; Write-Host ('       -> ' + $actie) -ForegroundColor Green }
                        else                          {              Write-Host ('       -> ' + $actie) -ForegroundColor Red   }
                    }
                }
                else { $schoon++ }
            }
        }
        else { $schoon++ }
    }

    $doneBytes += $f.Length

    # per bestand wegschrijven: een afgebroken ronde is dan niet verspild
    try {
        [pscustomobject]@{
            Pad           = $f.FullName
            Bytes         = $f.Length
            DuurSec       = $durTxt
            AudioCodec    = $codTxt
            Kanalen       = $chTxt
            AudioTotSec   = $endTxt
            TekortSec     = $shortTxt
            GrootsteGat   = $gapTxt
            GatOpSec      = $gapAtTxt
            SprongTerug   = $backTxt
            Verdict       = $verdict
            Actie         = $actie
            Tijdstip      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        } | Export-Csv -LiteralPath $Rapport -Delimiter ';' -NoTypeInformation -Append -Encoding UTF8
    }
    catch { }
}

Write-Progress -Activity 'Audio-tijdstempels nakijken' -Completed

# =====================================================================
#  6. slot
# =====================================================================
$el  = $sw.Elapsed.TotalSeconds
$mbs = if ($el -gt 1) { ($doneBytes / 1MB) / $el } else { 0 }

Write-Host ''
Write-Host '=============================================================' -ForegroundColor Cyan
Write-Host (' Klaar in {0}   ({1}, {2:N0} MB/s)' -f (Fmt-Span $el), (Fmt-Size $doneBytes), $mbs)
Write-Host (' {0} verdacht, {1} in orde, {2} zonder audiospoor, {3} niet leesbaar.' -f $verdacht, $schoon, $geenAud, $niet)
if ($Herstel) { Write-Host (' {0} hersteld.' -f $hersteld) -ForegroundColor Green }
Write-Host (' Rapport: {0}' -f $Rapport)
Write-Host '=============================================================' -ForegroundColor Cyan

if ($verdacht -gt 0) {
    Write-Host ''
    if (-not $Volledig) {
        Write-Host ' Wat hier "AUDIO STOPT" heet is niet met een remux te repareren: die'
        Write-Host ' audiopakketten staan niet meer in het bestand. Zulke bestanden moeten'
        Write-Host ' opnieuw worden omgezet vanaf het origineel, met de instelling Geluid op'
        Write-Host ' AAC in plaats van kopieren.'
        Write-Host ' Wil je ook weten of er gaten of sprongen midden in de bestanden zitten,'
        Write-Host ' voeg dan -Volledig toe. Dat leest alles en duurt dus veel langer.'
    }
    elseif (-not $Herstel) {
        Write-Host ' Gaten en sprongen zijn te repareren: voeg -Herstel toe. De video wordt'
        Write-Host ' daarbij niet opnieuw geencodeerd.'
        Write-Host ' Bestanden met "AUDIO STOPT" vallen daar buiten - die moeten opnieuw'
        Write-Host ' worden omgezet vanaf het origineel.'
    }
}
Write-Host ''
