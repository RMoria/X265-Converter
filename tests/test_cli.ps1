. (Join-Path $PSScriptRoot 'testlib.ps1')
$ok=0;$bad=0
function Check { param([string]$W,[bool]$C,[string]$E='') if($C){$script:ok++;"  OK    $W $E"}else{$script:bad++;"  FOUT  $W $E"} }
function Fresh { param($D) if(Test-Path $D){Remove-Item -Recurse -Force $D}; New-Item -ItemType Directory -Path $D -Force|Out-Null }
function MkVid { param($P,[int]$Sec=6,[string]$V='libx264')
  & $FFMPEG -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=$Sec" `
    -f lavfi -i "sine=duration=$Sec" -map 0:v -map 1:a -c:v $V -preset ultrafast -crf 36 -c:a aac $P 2>$null | Out-Null }

'############ OPDRACHTREGEL: -In / -Out ############'
''

# ------------------------------------------------------------------
'--- 1. postbus: opdracht wegschrijven en terugkomen ---'
# Write-Opdracht komt uit part2 en schrijft in $InboxDir.
Fresh '/tmp/cli'
$InboxDir = '/tmp/cli/opdrachten'
$r1 = Write-Opdracht -InPad '/tmp/cli/bron.mkv' -UitPad '/tmp/cli/uit/klaar.mkv'
$r2 = Write-Opdracht -InPad '/tmp/cli/tweede.mkv' -UitPad ''
Check 'wegschrijven lukt'        ($r1 -eq $true -and $r2 -eq $true)
$best = @(Get-ChildItem -LiteralPath $InboxDir -File -Filter 'opdracht_*.json')
Check 'twee opdrachten in de postbus' ($best.Count -eq 2)      "($($best.Count))"
Check 'geen half bestand blijven staan' (@(Get-ChildItem -LiteralPath $InboxDir -File -Filter '*.tmp').Count -eq 0)

$j1 = (Get-Content -Raw $best[0].FullName) | ConvertFrom-Json
$alle = @($best | ForEach-Object { (Get-Content -Raw $_.FullName) | ConvertFrom-Json })
$een  = $alle | Where-Object { $_.In -eq '/tmp/cli/bron.mkv' }
$twee = $alle | Where-Object { $_.In -eq '/tmp/cli/tweede.mkv' }
Check 'In komt terug'            ($een -ne $null)
Check 'Out komt terug'           ($een -ne $null -and $een.Out -eq '/tmp/cli/uit/klaar.mkv')
Check 'lege Out blijft leeg'     ($twee -ne $null -and [string]::IsNullOrEmpty($twee.Out))
Check 'unieke namen'             (($best | Select-Object -ExpandProperty Name -Unique).Count -eq 2)
''

# ------------------------------------------------------------------
'--- 2. scanmodus opdracht: wat er wel en niet in de wachtrij komt ---'
Fresh '/tmp/cli/in'
MkVid '/tmp/cli/in/film een.mkv' 5
MkVid '/tmp/cli/in/al hevc.mkv'  4 'libx265'
'geen video' | Set-Content '/tmp/cli/in/rommel.mkv'

$sync.ScanMode     = 'opdracht'
$sync.ScanCancel   = $false
$sync.ScanChecked  = 0; $sync.ScanFound = 0
$sync.ScanSkippedHevc = 0; $sync.ScanSkippedNoVid = 0
$sync.ScanSettings = @{ Jobs = @(
    [pscustomobject]@{ In='/tmp/cli/in/film een.mkv'; Out='/tmp/cli/uit/eigen naam.mkv' }
    [pscustomobject]@{ In='/tmp/cli/in/al hevc.mkv';  Out='' }
    [pscustomobject]@{ In='/tmp/cli/in/rommel.mkv';   Out='' }
    [pscustomobject]@{ In='/tmp/cli/in/bestaat niet.mkv'; Out='' }
) }
$w = Start-W $ScanWorker 'scan'
while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 150 }
Stop-W $w | Out-Null
$log  = @(Drain-Log)
$news = @(Drain-Jobs)

Check 'vier nagekeken'           ($sync.ScanChecked -eq 4)                "($($sync.ScanChecked))"
Check 'een aangenomen'           ($news.Count -eq 1)                      "($($news.Count))"
Check 'de juiste'                ($news.Count -eq 1 -and $news[0].Name -eq 'film een.mkv')
Check 'OutPath meegegeven'       ($news.Count -eq 1 -and $news[0].OutPath -eq '/tmp/cli/uit/eigen naam.mkv')
Check 'AutoQueue staat aan'      ($news.Count -eq 1 -and [bool]$news[0].AutoQueue)
Check 'duur is geprobed'         ($news.Count -eq 1 -and $news[0].DurationSec -gt 4.0)   "($($news[0].DurationSec))"
Check 'al HEVC overgeslagen'     ($sync.ScanSkippedHevc -eq 1)            "($($sync.ScanSkippedHevc))"
Check 'al HEVC gemeld'           (($log -join ' ') -match 'is al HEVC')
Check 'onleesbare gemeld'        (($log -join ' ') -match 'geen leesbare video')
Check 'ontbrekende gemeld'       (($log -join ' ') -match 'niet gevonden')
Check 'scan meldt zich af'       (-not $sync.ScanBusy)
''

# ------------------------------------------------------------------
'--- 3. lege opdrachtlijst laat de boel niet omvallen ---'
$sync.ScanMode='opdracht'; $sync.ScanCancel=$false
$sync.ScanChecked=0; $sync.ScanFound=0
$sync.ScanSettings = @{ Jobs = @() }
$w = Start-W $ScanWorker 'scan'
while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 150 }
$err = @(Stop-W $w)
Drain-Log | Out-Null
Check 'geen worker-fout'         (@($err | Where-Object { $_ -match 'WORKER-FOUT|ENDINVOKE' }).Count -eq 0) ($err -join ' | ')
Check 'niets aangenomen'         (@(Drain-Jobs).Count -eq 0)
''

# ------------------------------------------------------------------
'--- 4. -Out wordt letterlijk gebruikt, zonder .x265 en zonder (2) ---'
# New-OutputPath zit in de conversieworker; hier los uitvoeren.
$src = ($ConvertWorker.ToString())
$blok = $src.Substring($src.IndexOf('    function New-OutputPath'))
$blok = $blok.Substring(0, $blok.IndexOf('    function Remove-WithRetry'))
$sb = [scriptblock]::Create('function W { param($m,$l) }' + "`n" +
    'function Get-CleanBase { param([string]$b) return ($b -replace ''\.x265( \(\d+\))?$'','''') }' + "`n" +
    $blok + "`n" + '
Fresh2
"vast      : {0}" -f (New-OutputPath -SourcePath "/tmp/cli/out/film.mkv" -Fixed "/tmp/cli/out/nieuwe map/eigen naam.mkv")
"map gemaakt: {0}" -f (Test-Path "/tmp/cli/out/nieuwe map")
"vrij      : {0}" -f (New-OutputPath -SourcePath "/tmp/cli/out/film.mkv")
"bezet     : {0}" -f (New-OutputPath -SourcePath "/tmp/cli/out/bezet.mkv")
"vast bezet: {0}" -f (New-OutputPath -SourcePath "/tmp/cli/out/bezet.mkv" -Fixed "/tmp/cli/out/bezet.x265.mkv")
"leeg vast : {0}" -f (New-OutputPath -SourcePath "/tmp/cli/out/film.mkv" -Fixed "   ")
"mp4 bron  : {0}" -f (New-OutputPath -SourcePath "/tmp/cli/out/clip.mp4")
"vervangt  : {0}" -f (New-OutputPath -SourcePath "/tmp/cli/out/film.mkv" -ReplaceSource $true)
"avi bezet : {0}" -f (New-OutputPath -SourcePath "/tmp/cli/out/a.avi")
')
function Fresh2 {
    if (Test-Path '/tmp/cli/out') { Remove-Item -Recurse -Force '/tmp/cli/out' }
    New-Item -ItemType Directory -Path '/tmp/cli/out' -Force | Out-Null
    Set-Content '/tmp/cli/out/bezet.x265.mkv' 'x'
    Set-Content '/tmp/cli/out/a.mkv' 'x'
}
$r = & $sb
$r
$t = ($r -join ' ')
Check 'vaste naam letterlijk'    ($t -match 'vast\s+: /tmp/cli/out/nieuwe map/eigen naam\.mkv')
Check 'map wordt aangemaakt'     ($t -match 'map gemaakt: True')
Check 'zelfde naam, origineel blijft: .x265' ($t -match 'vrij\s+: /tmp/cli/out/film\.x265\.mkv')
Check 'andere extensie: gewoon .mkv' ($t -match 'mp4 bron\s+: /tmp/cli/out/clip\.mkv')
Check 'origineel weg: neemt de plaats in' ($t -match 'vervangt\s+: /tmp/cli/out/film\.mkv')
Check 'bezette .mkv krijgt (2)'  ($t -match 'avi bezet : /tmp/cli/out/a \(2\)\.mkv')
Check 'zonder -Out wel (2)'      ($t -match 'bezet\s+: /tmp/cli/out/bezet\.x265 \(2\)\.mkv')
Check 'met -Out geen (2)'        ($t -match 'vast bezet: /tmp/cli/out/bezet\.x265\.mkv')
Check 'witruimte telt als leeg'  ($t -match 'leeg vast : /tmp/cli/out/film\.x265\.mkv')
''

# ------------------------------------------------------------------
'--- 5. echte conversie naar een opgegeven -Out ---'
Fresh '/tmp/cli/run'
MkVid '/tmp/cli/run/bron.mkv' 5
Reset-Run (Std-Settings -DeleteOrig $false -Subs $false -AudioMode 'aac' -TailCheck $false)
$job = New-Job -FullPath '/tmp/cli/run/bron.mkv' -Dur 5.0
$job.OutPath = '/tmp/cli/run/klaar/mijn naam.mkv'
Enqueue-Jobs @($job)
$w = Start-W $ConvertWorker 'conv'
while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }
Stop-W $w | Out-Null
Drain-Log | Out-Null
Check 'conversie geslaagd'       ($sync.Success -eq 1)                    "(succ=$($sync.Success) fail=$($sync.Failed))"
Check 'staat op de gevraagde plek' (Test-Path '/tmp/cli/run/klaar/mijn naam.mkv')
Check 'geen .x265 ernaast'       (-not (Test-Path '/tmp/cli/run/bron.x265.mkv'))
$c = (& $FFPROBE -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 '/tmp/cli/run/klaar/mijn naam.mkv')
Check 'is HEVC geworden'         ("$c".Trim() -eq 'hevc')                 "($c)"
Check 'origineel blijft staan'   (Test-Path '/tmp/cli/run/bron.mkv')
''
'--- 6. -In/-Out overleven de herstart zonder console ---'
# Get-RelaunchArguments bouwt de opdrachtregel voor de instantie die
# blijft leven. Gaat -In daar verloren, dan verdwijnt de opdracht.
$p1  = Get-Content -Raw $SrcDir/part1.ps1
$blk = $p1.Substring($p1.IndexOf('function Get-RelaunchArguments'))
$blk = $blk.Substring(0, $blk.IndexOf('if ($FromLauncher)'))
$sb2 = [scriptblock]::Create($blk + "`n" + '
"kaal  : {0}" -f (Get-RelaunchArguments -ScriptPath "C:\Tools\2-265\X265-Converter.ps1")
"in    : {0}" -f (Get-RelaunchArguments -ScriptPath "C:\x.ps1" -InFile "D:\in\film.mkv")
"beide : {0}" -f (Get-RelaunchArguments -ScriptPath "C:\x.ps1" -InFile "D:\in\film.mkv" -OutFile "E:\uit\klaar.mkv")
"quote : {0}" -f (Get-RelaunchArguments -ScriptPath "C:\x.ps1" -InFile "D:\Rob''s films\a.mkv")
"outzin: {0}" -f (Get-RelaunchArguments -ScriptPath "C:\x.ps1" -OutFile "E:\uit\klaar.mkv")
"map   : {0}" -f (Get-RelaunchArguments -ScriptPath "C:\x.ps1" -Folders @("D:\een","D:\twee"))
')
$r2 = & $sb2
$r2
$t2 = ($r2 -join ' ')
$kaal = @($r2 | Where-Object { $_ -like 'kaal*' })[0]
Check 'kaal blijft kaal'          (($kaal -match '-NoProfile') -and ($kaal -notmatch '-In ') -and ($kaal -notmatch '-Out '))  $kaal
Check '-In gaat mee'              ($t2 -match "in    :.*-In 'D:\\in\\film\.mkv'")
Check '-Out gaat mee'             ($t2 -match "beide :.*-In 'D:\\in\\film\.mkv' -Out 'E:\\uit\\klaar\.mkv'")
Check 'apostrof verdubbeld'       ($t2 -match "quote :.*-In 'D:\\Rob''s films\\a\.mkv'")
Check '-Out zonder -In vervalt'   (($t2 -match 'outzin:') -and ($t2 -notmatch 'outzin:.*-Out'))
Check 'mappen nog steeds goed'    ($t2 -match "map   :.*-Path 'D:\\een','D:\\twee'")
''
"====> $ok goed, $bad fout"
