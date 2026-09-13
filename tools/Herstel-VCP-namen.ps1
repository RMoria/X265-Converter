<#
    Herstel-VCP-namen.ps1
    ---------------------
    Haalt de VCP-markering uit bestandsnamen, zodat die bestanden bij een
    volgende scan weer meekomen.

    De converter zet VCP achter de naam van een bron waarbij de omzetting
    geluid had laten vallen, en de scanner slaat zulke bestanden over. Dat
    was aanvankelijk te streng: verliezen van 2 tot 5 seconden - het
    staartje van de aftiteling - leidden tot afkeuren van een conversie van
    drie kwartier. Met een grens (AudioLossLimit, standaard 30 s) worden die
    nu opgevuld en behouden, dus zijn de eerder afgekeurde bestanden weer
    het proberen waard.

      Film x264.VCP.mkv       ->  Film x264.mkv
      Film x264.VCP (2).mkv   ->  Film x264.mkv

    Gebruik:
      .\Herstel-VCP-namen.ps1 -Path '\\10.0.0.242\h\Serie'            # alleen kijken
      .\Herstel-VCP-namen.ps1 -Path '\\10.0.0.242\h\Serie' -Doen      # hernoemen
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $Path,
    [switch]   $Doen,
    [string]   $Marker    = 'VCP',
    [bool]     $Recursief = $true
)

$ErrorActionPreference = 'Stop'

$pat = ('(?i)^(?<basis>.+)\.{0}( \(\d+\))?$' -f [Regex]::Escape($Marker))

Write-Host ''
Write-Host '=============================================================' -ForegroundColor Cyan
Write-Host (' VCP-markering weghalen   (markering: {0})' -f $Marker)       -ForegroundColor Cyan
if ($Doen) { Write-Host ' Modus: HERNOEMEN'                -ForegroundColor Yellow }
else       { Write-Host ' Modus: alleen kijken'            -ForegroundColor Green  }
Write-Host '=============================================================' -ForegroundColor Cyan
Write-Host ''

$kandidaten = New-Object System.Collections.ArrayList

foreach ($p in $Path) {
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host (' NIET GEVONDEN : {0}' -f $p) -ForegroundColor Red
        continue
    }
    Write-Host (' zoeken in : {0} ...' -f $p) -NoNewline

    $gci = @{ LiteralPath = $p; File = $true; ErrorAction = 'SilentlyContinue' }
    if ($Recursief) { $gci['Recurse'] = $true }

    $n = 0
    foreach ($f in (Get-ChildItem @gci)) {
        $basis = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $m = [Regex]::Match($basis, $pat)
        if (-not $m.Success) { continue }
        [void]$kandidaten.Add([pscustomobject]@{
            Bestand = $f
            Nieuw   = Join-Path $f.DirectoryName ($m.Groups['basis'].Value + $f.Extension)
        })
        $n++
    }
    Write-Host (' {0} gevonden' -f $n)
}

Write-Host ''
if ($kandidaten.Count -lt 1) {
    Write-Host ' Niets met een VCP-markering gevonden.' -ForegroundColor Green
    Write-Host ''
    return
}

$gedaan = 0
$over   = 0
$fout   = 0

foreach ($k in $kandidaten) {
    $oud = $k.Bestand.FullName

    # Bestaat de gewone naam al, dan is dat waarschijnlijk een geslaagde
    # omzetting van hetzelfde bestand. Niet overschrijven, niet hernoemen.
    if (Test-Path -LiteralPath $k.Nieuw) {
        Write-Host ('  OVERGESLAGEN  {0}' -f $oud) -ForegroundColor Yellow
        Write-Host ('                de naam {0} bestaat al' -f [IO.Path]::GetFileName($k.Nieuw)) -ForegroundColor Yellow
        $over++
        continue
    }

    if (-not $Doen) {
        Write-Host ('  zou worden   {0}' -f [IO.Path]::GetFileName($k.Nieuw))
        Write-Host ('     nu        {0}' -f $oud) -ForegroundColor DarkGray
        $gedaan++
        continue
    }

    try {
        Move-Item -LiteralPath $oud -Destination $k.Nieuw
        Write-Host ('  HERNOEMD     {0}' -f [IO.Path]::GetFileName($k.Nieuw)) -ForegroundColor Green
        $gedaan++
    }
    catch {
        Write-Host ('  MISLUKT      {0}' -f $oud) -ForegroundColor Red
        Write-Host ('               {0}' -f $_.Exception.Message) -ForegroundColor Red
        $fout++
    }
}

Write-Host ''
Write-Host '=============================================================' -ForegroundColor Cyan
if ($Doen) { Write-Host (' {0} hernoemd, {1} overgeslagen, {2} mislukt.' -f $gedaan, $over, $fout) }
else {
    Write-Host (' {0} zouden worden hernoemd, {1} overgeslagen.' -f $gedaan, $over)
    Write-Host ' Voeg -Doen toe om het echt te doen.'
}
Write-Host '=============================================================' -ForegroundColor Cyan
Write-Host ''
