. (Join-Path $PSScriptRoot 'testlib.ps1')
$ok=0;$bad=0
function Check { param([string]$W,[bool]$C,[string]$E='') if($C){$script:ok++;"  OK    $W $E"}else{$script:bad++;"  FOUT  $W $E"} }
function Fresh { param($D) if(Test-Path $D){Remove-Item -Recurse -Force $D}; New-Item -ItemType Directory -Path $D -Force|Out-Null }

# bron: video van $Vid s, geluid van $Aud s
function MkSrc { param($P,[int]$Vid,[int]$Aud)
  & $FFMPEG -hide_banner -loglevel error -y `
    -f lavfi -i "testsrc=size=320x240:rate=25:duration=$Vid" `
    -f lavfi -i "sine=frequency=440:duration=$Aud" `
    -map 0:v -map 1:a -c:v libx264 -preset ultrafast -crf 34 -c:a aac $P 2>$null | Out-Null }

function Run { param($Dir,$Name,[int]$Dur,[bool]$Pad=$true)
  Reset-Run (Std-Settings -DeleteOrig $true -Subs $false -AudioMode 'aac' -Pad $Pad)
  Enqueue-Jobs @(New-Job -FullPath "$Dir/$Name" -Dur ([double]$Dur))
  $w = Start-W $ConvertWorker 'conv'
  while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }
  Stop-W $w | Out-Null
  return @(Drain-Log) }

function AudioEnd { param($P)
  $j = (& $FFPROBE -v error -select_streams a:0 -show_packets -show_entries packet=pts_time -of csv=p=0 $P) |
       ForEach-Object { [double]($_ -replace ',$','') } | Sort-Object
  if ($j.Count -lt 1) { return -1 }
  return $j[-1] }

'############ KORTE STAART, OPVULLEN EN VCP ############'
''
'--- 1. bron met geluid tot 20 s van 60 s: opvullen, GEEN Let op ---'
Fresh /tmp/vc/a
MkSrc '/tmp/vc/a/kort x264.mkv' 60 20
$log = Run /tmp/vc/a 'kort x264.mkv' 60
$f = @(Get-ChildItem /tmp/vc/a -File | ForEach-Object Name)
Check 'geslaagd, geen waarschuwing'  ($sync.Success -eq 1 -and $sync.Warned -eq 0) "(succ=$($sync.Success) warn=$($sync.Warned))"
Check 'origineel verwijderd'         (-not ($f -contains 'kort x264.mkv'))
Check 'bron-tekort herkend'          (($log -join ' ') -match 'Let op de bron')
Check 'staart opgevuld'              (($log -join ' ') -match 'Staart opgevuld tot het einde')
$e = AudioEnd '/tmp/vc/a/kort.x265.mkv'
Check 'geluid loopt nu tot het eind' ($e -gt 55)                                    ("laatste audio op {0:N1} s" -f $e)
''
'--- 2. zelfde bron, opvullen uit: melden maar niet ingrijpen ---'
Fresh /tmp/vc/b
MkSrc '/tmp/vc/b/kort2 x264.mkv' 60 20
$log = Run /tmp/vc/b 'kort2 x264.mkv' 60 $false
Check 'geslaagd, geen waarschuwing'  ($sync.Success -eq 1 -and $sync.Warned -eq 0)
Check 'wel gemeld'                   (($log -join ' ') -match 'Niets aan te doen bij het omzetten')
Check 'niet opgevuld'                ((AudioEnd '/tmp/vc/b/kort2.x265.mkv') -lt 25)
''
'--- 3. gezonde bron: niets bijzonders ---'
Fresh /tmp/vc/c
MkSrc '/tmp/vc/c/heel x264.mkv' 40 40
$log = Run /tmp/vc/c 'heel x264.mkv' 40
Check 'geslaagd'                     ($sync.Success -eq 1 -and $sync.Warned -eq 0)
Check 'geen opvullen'                (-not (($log -join ' ') -match 'Staart opgevuld'))
Check 'geen VCP'                     (-not (($log -join ' ') -match 'GELUID VERLOREN'))
Check 'log meldt bron-vergelijking'  (($log -join ' ') -match 'tekort .* bron')
''
"====> $ok goed, $bad fout"

'--- 4. uitvoer echt slechter dan de bron: VCP ---'
Fresh /tmp/vc/d
MkSrc '/tmp/vc/d/verlies x264.mkv' 40 40
# marge EN grens negatief zetten dwingt de VCP-route af, zodat het pad zelf
# getest wordt. Alleen een negatieve marge is niet genoeg meer: klein verlies
# valt nu onder de grens en wordt dan opgevuld en behouden.
Reset-Run (Std-Settings -DeleteOrig $true -Subs $false -AudioMode 'aac' -Margin -1.0 -Limit -1.0)
Enqueue-Jobs @(New-Job -FullPath '/tmp/vc/d/verlies x264.mkv' -Dur 40.0)
$w = Start-W $ConvertWorker 'conv'; while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }; Stop-W $w | Out-Null
$log = @(Drain-Log)
$f = @(Get-ChildItem /tmp/vc/d -File | ForEach-Object Name | Sort-Object)
Check 'VCP gemeld'                   (($log -join ' ') -cmatch 'GELUID VERLOREN')
Check 'resultaat weggegooid'         (-not ($f | Where-Object { $_ -like '*.x265.mkv' }))
Check 'bron hernoemd naar VCP'       ($f -contains 'verlies x264.VCP.mkv')            ("map: " + ($f -join ', '))
Check 'oude naam bestaat niet meer'  (-not ($f -contains 'verlies x264.mkv'))
Check 'niet als geslaagd geteld'     ($sync.Success -eq 0)
Check 'telt NIET mee voor noodstop'  ($sync.FailStreak -eq 0)                          "(streak=$($sync.FailStreak))"
$rest = @(Get-ChildItem /tmp/x265work -File -EA SilentlyContinue | Where-Object { $_.Name -like 'x265_*' })
Check 'werkmap opgeruimd'            ($rest.Count -eq 0)
''
'--- 5. scanner slaat VCP-bestanden over ---'
Fresh /tmp/vc/e
MkSrc '/tmp/vc/e/gewoon x264.mkv' 8 8
MkSrc '/tmp/vc/e/eerder x264.VCP.mkv' 8 8
MkSrc '/tmp/vc/e/ook x264.VCP (2).mkv' 8 8
$sync.ScanSettings = @{ Folders=@('/tmp/vc/e'); Extensions=@('mkv'); Recursive=$true; VcpMarker='VCP' }
$sync.ScanCancel=$false; $sync.ScanTotal=0; $sync.ScanChecked=0; $sync.ScanFound=0
$sync.ScanSkippedHevc=0; $sync.ScanSkippedVcp=0; $sync.ScanSkippedNoVid=0; $sync.ScanMode='scan'
$w = Start-W $ScanWorker 'scan'; while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }; Stop-W $w | Out-Null
$slog = @(Drain-Log)
$namen = @(Drain-Jobs | ForEach-Object { $_.Name })
Check 'alleen het gewone bestand'    ($namen.Count -eq 1 -and $namen[0] -eq 'gewoon x264.mkv') ("-> " + ($namen -join ', '))
Check 'twee VCP overgeslagen'        ($sync.ScanSkippedVcp -eq 2)                      "(=$($sync.ScanSkippedVcp))"
Check 'in de scansamenvatting'       (($slog -join ' ') -match 'eerder VCP: 2')
''
"====> $ok goed, $bad fout"
