<#
    Diagnose-Bestand.ps1
    --------------------
    Meet een enkel mediabestand door en schrijft alles wat relevant is naar
    het scherm en naar een tekstbestand.

    Bedoeld om twee bestanden te vergelijken: een omgezet bestand waar het
    geluid en de ondertitels wegvallen, en een bestand dat wel goed speelt.
    Het verschil tussen die twee metingen wijst de oorzaak aan.

    Gebruik:
      .\Diagnose-Bestand.ps1 -Path 'D:\Films\kapot.x265.mkv'
      .\Diagnose-Bestand.ps1 -Path 'D:\Films\kapot.x265.mkv','D:\Films\goed.mkv'

    -Snel   sla de twee metingen over die het bestand volledig moeten lezen
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $Path,
    [switch]   $Snel,
    [int]      $SeekPunten = 12,
    [string]   $Uitvoer = ''
)

$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
if ([string]::IsNullOrEmpty($here)) { $here = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$ffmpeg  = Join-Path $here 'ffmpeg\bin\ffmpeg.exe'
$ffprobe = Join-Path $here 'ffmpeg\bin\ffprobe.exe'
if (-not (Test-Path -LiteralPath $ffmpeg))  { $ffmpeg  = 'ffmpeg' }
if (-not (Test-Path -LiteralPath $ffprobe)) { $ffprobe = 'ffprobe' }
if ([string]::IsNullOrWhiteSpace($Uitvoer)) { $Uitvoer = Join-Path $here 'Diagnose-Bestand.txt' }

$script:Regels = New-Object System.Collections.ArrayList
function L {
    param([string]$T = '', [string]$Kleur = '')
    [void]$script:Regels.Add($T)
    if ($Kleur) { Write-Host $T -ForegroundColor $Kleur } else { Write-Host $T }
}
function Inv { param([double]$V) [string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$V) }
function Num {
    param([string]$T)
    $d = 0.0
    if ([double]::TryParse($T,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$d)) { return $d }
    return [double]::NaN
}

# =====================================================================
function Diagnose {
    param([string]$File)

    L ''
    L '================================================================'
    L (' ' + $File)
    L '================================================================'

    if (-not (Test-Path -LiteralPath $File)) { L ' NIET GEVONDEN' 'Red'; return }
    $fi = Get-Item -LiteralPath $File
    L (' grootte : {0:N0} bytes ({1:N2} GB)' -f $fi.Length, ($fi.Length / 1GB))

    # ---- 1. streams en container ------------------------------------
    $raw = (& $ffprobe -v error -show_format -show_streams -of json $File 2>$null) -join "`n"
    if ([string]::IsNullOrWhiteSpace($raw)) { L ' ffprobe gaf niets terug' 'Red'; return }
    $j = $raw | ConvertFrom-Json

    $dur = Num ([string]$j.format.duration)
    L (' speelduur: {0:N1} s' -f $dur)

    # wie heeft het bestand geschreven - dit onderscheidt ffmpeg van mkvmerge
    foreach ($k in @('encoder','ENCODER','WRITING_APP','writing_app','MUXING_APP','muxing_app')) {
        $v = $j.format.tags.$k
        if ($v) { L (' geschreven door ({0}): {1}' -f $k, $v) }
    }

    L ''
    L ' STREAMS'
    $vIdx = -1
    foreach ($s in @($j.streams)) {
        $ix = [int]$s.index
        $ty = [string]$s.codec_type
        if ($ty -eq 'video' -and $vIdx -lt 0) { $vIdx = $ix }

        $extra = @()
        if ($s.channels)          { $extra += ('{0}ch' -f $s.channels) }
        if ($s.tags.language)     { $extra += ('taal={0}' -f $s.tags.language) }
        if ($s.tags.title)        { $extra += ('titel={0}' -f $s.tags.title) }
        if ($s.disposition) {
            $fl = @()
            foreach ($p in $s.disposition.PSObject.Properties) {
                if ([int]$p.Value -eq 1) { $fl += $p.Name }
            }
            if ($fl.Count -gt 0) { $extra += ('vlaggen=' + ($fl -join '+')) }
        }
        L ('   {0,2}  {1,-10} {2,-12} {3}' -f $ix, $ty, [string]$s.codec_name, ($extra -join '  '))
    }

    $nonVideo = @(@($j.streams) | Where-Object { [string]$_.codec_type -ne 'video' } | ForEach-Object { [int]$_.index })
    $audioIdx = @(@($j.streams) | Where-Object { [string]$_.codec_type -eq 'audio' } | ForEach-Object { [int]$_.index })
    $subIdx   = @(@($j.streams) | Where-Object { [string]$_.codec_type -eq 'subtitle' } | ForEach-Object { [int]$_.index })

    if ($vIdx -lt 0) { L ' geen videospoor - de rest van de meting slaat nergens op' 'Yellow'; return }

    # ---- 2. seek-test: precies wat 'doorklikken' doet ---------------
    #
    #  Op N punten in het bestand springen en kijken of er daar meteen
    #  audio- en ondertitelpakketten liggen. Dit is wat een speler doet en
    #  wat er misgaat als de streams niet netjes door elkaar staan.
    #  LET OP: geen -select_streams, dat blokkeert de seek.
    L ''
    L ' SEEK-TEST  (springen en kijken of er geluid ligt waar je landt)'
    if ([double]::IsNaN($dur) -or $dur -le 10) {
        L '   te kort om te testen'
    }
    else {
        $slecht = 0
        for ($p = 1; $p -le $SeekPunten; $p++) {
            $t = $dur * $p / ($SeekPunten + 1)
            $iv = ('{0}%+6' -f (Inv $t))
            $lines = @(& $ffprobe -v error -read_intervals $iv -show_packets `
                        -show_entries packet=stream_index,pts_time -of csv=p=0 $File 2>$null)

            $eerste = @{}
            foreach ($l in $lines) {
                $a = ([string]$l).Split(',')
                if ($a.Count -lt 2) { continue }
                $ix = 0
                if (-not [int]::TryParse($a[0].Trim(),[ref]$ix)) { continue }
                $pt = Num $a[1]
                if ([double]::IsNaN($pt)) { continue }
                if (-not $eerste.ContainsKey($ix)) { $eerste[$ix] = $pt }
                elseif ($pt -lt $eerste[$ix])       { $eerste[$ix] = $pt }
            }

            # Een seek landt altijd op het keyframe VOOR het gevraagde punt,
            # dus komen video en audio samen een paar seconden eerder terug.
            # Dat is normaal. Wat telt is of het geluid op dezelfde plek ligt
            # als het beeld: audio vergeleken met VIDEO, niet met de vraag.
            $vT = if ($eerste.ContainsKey($vIdx)) { $eerste[$vIdx] } else { [double]::NaN }
            $st = ''
            $fout = $false

            if ([double]::IsNaN($vT)) {
                $st = '  geen beeld op dit punt'
                $fout = $true
            }
            else {
                foreach ($ai in $audioIdx) {
                    if (-not $eerste.ContainsKey($ai)) {
                        $st += ('  audio{0}=GEEN' -f $ai); $fout = $true
                    }
                    else {
                        $d = $eerste[$ai] - $vT
                        $st += ('  audio{0}={1:N1}s' -f $ai, $d)
                        if ([Math]::Abs($d) -gt 5) { $fout = $true }
                    }
                }
                foreach ($si in $subIdx) {
                    if ($eerste.ContainsKey($si)) {
                        $st += ('  sub{0}={1:N1}s' -f $si, ($eerste[$si] - $vT))
                    }
                }
            }

            if ($fout) { $slecht++ }
            $kl = if ($fout) { 'Red' } else { '' }
            L ('   op {0,8:N1} s : landt op {1}{2}' -f $t, `
                ($(if ([double]::IsNaN($vT)) { '?' } else { ('{0:N1} s' -f $vT) })), $st) $kl
        }
        L ''
        L ('   -> {0} van {1} seekpunten waar het geluid niet bij het beeld ligt' -f $slecht, $SeekPunten) `
            $(if ($slecht -gt 0) { 'Red' } else { 'Green' })
        L '      (de getallen zijn afstand tot het beeld op dat punt; rond nul is goed.'
        L '       Een ondertitelspoor mag ver weg liggen - die heeft nu eenmaal gaten.)'
    }

    if ($Snel) { L ''; L ' (-Snel: de twee volledige leesrondes overgeslagen)'; return }

    # ---- 3. interleaving over het hele bestand ----------------------
    L ''
    L ' INTERLEAVING  (hoe ver loopt elk spoor uit de pas met het beeld op'
    L '                dezelfde plek in het bestand - een speler leest lineair)'

    $drift = @{}
    $vNow  = [double]::NaN
    $lines = @(& $ffprobe -v error -show_packets -show_entries packet=stream_index,pts_time -of csv=p=0 $File 2>$null)
    foreach ($l in $lines) {
        $a = ([string]$l).Split(',')
        if ($a.Count -lt 2) { continue }
        $ix = 0
        if (-not [int]::TryParse($a[0].Trim(),[ref]$ix)) { continue }
        $pt = Num $a[1]
        if ([double]::IsNaN($pt)) { continue }
        if ($ix -eq $vIdx) { $vNow = $pt; continue }
        if ([double]::IsNaN($vNow)) { continue }
        if (-not $drift.ContainsKey($ix)) { $drift[$ix] = New-Object System.Collections.ArrayList }
        [void]$drift[$ix].Add([Math]::Abs($pt - $vNow))
    }

    foreach ($ix in ($drift.Keys | Sort-Object)) {
        $v = @($drift[$ix]) | Sort-Object
        if ($v.Count -lt 1) { continue }
        $p50 = $v[[int]($v.Count * 0.50)]
        $p95 = $v[[int]([Math]::Min($v.Count - 1, $v.Count * 0.95))]
        $mx  = $v[$v.Count - 1]
        $oordeel = if ($mx -gt 5) { 'SLECHT' } elseif ($mx -gt 1.5) { 'matig' } else { 'goed' }
        $kl      = if ($mx -gt 5) { 'Red' } elseif ($mx -gt 1.5) { 'Yellow' } else { 'Green' }
        L ('   stream {0,2}: mediaan {1,7:N2} s  p95 {2,7:N2} s  max {3,8:N2} s  ({4} pakketten)  {5}' `
            -f $ix, $p50, $p95, $mx, $v.Count, $oordeel) $kl
    }

    # ---- 4. wat zegt ffmpeg zelf bij het doorlezen ------------------
    L ''
    L ' WAT FFMPEG MELDT bij het volledig doorlezen'
    $out = @(& $ffmpeg -hide_banner -loglevel warning -nostats -i $File -map 0 -c copy -f null - 2>&1)
    $out = @($out | Where-Object { ([string]$_).Trim().Length -gt 0 })
    if ($out.Count -lt 1) { L '   (niets - geen enkele waarschuwing)' 'Green' }
    else {
        $groep = @{}
        foreach ($o in $out) {
            $k = ([string]$o) -replace '\d+','#'
            if ($groep.ContainsKey($k)) { $groep[$k] = $groep[$k] + 1 } else { $groep[$k] = 1 }
        }
        foreach ($k in ($groep.Keys | Sort-Object { -$groep[$k] })) {
            L ('   {0,5} x  {1}' -f $groep[$k], $k) 'Yellow'
        }
    }
}

# =====================================================================
L ''
L ('Diagnose-Bestand  --  {0}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
L ('ffprobe: {0}' -f $ffprobe)
foreach ($p in $Path) { Diagnose $p }

L ''
try {
    Set-Content -LiteralPath $Uitvoer -Value $script:Regels -Encoding UTF8
    Write-Host (' Ook opgeslagen als: {0}' -f $Uitvoer) -ForegroundColor Cyan
}
catch { Write-Host (' Kon het rapport niet opslaan: {0}' -f $_.Exception.Message) -ForegroundColor Red }
Write-Host ''
