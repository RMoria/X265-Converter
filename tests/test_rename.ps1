. (Join-Path $PSScriptRoot 'testlib.ps1')
$ok=0;$bad=0
function Check { param([string]$W,[bool]$C,[string]$E='') if($C){$script:ok++;"  OK    $W $E"}else{$script:bad++;"  FOUT  $W $E"} }
function Fresh { param($D) if(Test-Path $D){Remove-Item -Recurse -Force $D}; New-Item -ItemType Directory -Path $D -Force|Out-Null }
function Touch { param($P) $d = Split-Path -Parent $P; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }; Set-Content -LiteralPath $P 'x' }
function MkVid { param($P,[int]$Sec=4,[string]$V='libx264')
  & $FFMPEG -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=$Sec" `
    -f lavfi -i "sine=duration=$Sec" -map 0:v -map 1:a -c:v $V -preset ultrafast -crf 36 -c:a aac $P 2>$null | Out-Null }
function Names { param($D) @(Get-ChildItem -LiteralPath $D -File | ForEach-Object Name | Sort-Object) }

$sync.RenameRules = New-RnRules $null

'############ HERNOEMEN VOLGENS DE NAAMREGELS ############'
''
'--- 1. namen (voorbeelden uit de regels) ---'
$gevallen = [ordered]@{
    'F:\serie\Punisher\marvels.the.punisher.s01e05.1080p.WEB-DL.x265-MeGusta.mkv'        = 'ThePunisher.S01E05.mkv'
    'F:\serie\Supernatural.S01\Supernatural.S01E01.Pilot.720p.HDTV.mkv'                   = 'Supernatural.S01E01.Pilot.mkv'
    'G:\anime\Dungeon Meshi\[CameEsp] Dungeon Meshi - 01 [1080p][A1B2C3D4].mkv'           = 'DungeonMeshi.01.mkv'
    'G:\anime\Hell Mode\Hell Mode S2 - 12v2 (1080p).mkv'                                  = 'HellMode.S02E12.mkv'
    'F:\serie\Futurama\Futurama 1407 Welcome to the Playground.avi'                       = 'Futurama.1407.Welcome.to.the.Playground.avi'
    'F:\serie\Anime\BokuNoHeroAcademia.171.mkv'                                          = 'BokuNoHeroAcademia.171.mkv'
    'F:\serie\Anime\Boku no Hero Academia 171 [1080p].mkv'                               = 'BokuNoHeroAcademia.171.mkv'
    'F:\serie\Friends\Friends 1x09 The One Where.avi'                                    = 'Friends.S01E09.The.One.Where.avi'
    'F:\serie\Friends\friends.10x17.mkv'                                                 = 'Friends.S10E17.mkv'
    'F:\serie\Show\Show.2019.05.Titel.mkv'                                               = 'Show.05.Titel.mkv'
    'F:\films\TheAvengers.VCP.mkv'                                                        = 'TheAvengers.VCP.mkv'
    'F:\films\The.Avengers.2012.1080p.VCP.mkv'                                            = 'TheAvengers.VCP.mkv'
    'F:\serie\Show\show.s01e02.720p.VCP.mkv'                                             = 'Show.S01E02.VCP.mkv'
    'F:\serie\Show\x264 1x09 niet.mkv'                                                   = $null
    'F:\serie\Death Note\Death.Note.01.Rebirth.mkv'                                       = 'DeathNote.01.Rebirth.mkv'
    'F:\film\Sharknado_2_The_Second_One.mp4'                                              = 'Sharknado.2.The.Second.One.mp4'
    'F:\film\The.Fantastic.Four.First.Steps.2025.2160p.WEB.mkv'                           = 'TheFantasticFourFirstSteps.mkv'
    'F:\serie\One Piece\One Piece - 0001.mkv'                                             = 'OnePiece.0001.mkv'
    'F:\serie\WandaVision\WandaVision.S01E01.Filmed.Before.a.Live.Studio.Audience.mkv'    = 'WandaVision.S01E01.Filmed.Before.a.Live.Studio.Audience.mkv'
    'F:\serie\ONE PIECE\ONE PIECE S01E05 1080p.mkv'                                       = 'OnePiece.S01E05.mkv'
    'F:\film\Armageddon (1).MKV'                                                          = 'Armageddon.1.mkv'
    'F:\serie\Show\Show.S1E5.mkv'                                                         = 'Show.S01E05.mkv'
    'F:\serie\Show\Show.S01 E05.Title.mkv'                                                = 'Show.S01E05.Title.mkv'
    'F:\serie\Show\Show.S01E01-E02.mkv'                                                   = 'Show.S01E01-E02.mkv'
    'F:\serie\The End\The.End.S01E01.mkv'                                                 = 'TheEnd.S01E01.mkv'
    'F:\serie\Fallout\Fallout.2024.S01E03.The.Head.1080p.mkv'                             = 'Fallout.S01E03.The.Head.mkv'
}
foreach ($k in $gevallen.Keys) {
    if ($gevallen[$k] -eq $null) { continue }
    $n = Get-RnNewName $k
    Check ("{0}" -f $gevallen[$k]) ($n -ceq $gevallen[$k]) "($n)"
}
# x264 is geen 1x09: geen S..E.. uit een codecnaam
Check 'x264 is geen seizoen'        ((Get-RnNewName 'F:\serie\Show\Show.S01E03.x264.mkv') -ceq 'Show.S01E03.mkv')
Check 'VCP-kenmerk uit de instellingen' ((& { $sync.RenameRules = New-RnRules $null 'KAPOT'; $x = Get-RnNewName 'F:\films\the.avengers.KAPOT.mkv'; $sync.RenameRules = New-RnRules $null; $x }) -ceq 'TheAvengers.KAPOT.mkv')
# In een filmmap geen afleveringsnummers: "Naam 1407" blijft een film
Check 'filmmap: geen SSEE'         ((Get-RnNewName 'F:\films\Blade Runner 2049.mkv') -ceq 'BladeRunner.mkv') "($(Get-RnNewName 'F:\films\Blade Runner 2049.mkv'))"
''

'--- 2. regels aanpassen met een delta ---'
$d = [pscustomobject]@{ JunkAdd = @('prutsgroep'); ArticlesAdd = @('le'); VideoExtensionsAdd = @('WEBM');
                        GenericDirsAdd = @('mijn video''s'); JunkRemove = @('web'); LangTagsAdd = @('(')  }
$r = New-RnRules $d
Check 'extensie zonder punt erbij'  ($r.VideoExtensions -contains '.webm')
Check 'eigen rommel-token'          ('Show.S01E01.Titel.prutsgroep.mkv' -and ('prutsgroep' -match $r.JunkRegex))
Check 'token weg uit de lijst'      (-not ('web' -match $r.JunkRegex))
Check 'standaard blijft verder'     ('webrip' -match $r.JunkRegex)
Check 'lidwoord erbij'              ($r.Articles -contains 'le')
Check 'algemene map erbij'          ("mijn video's" -match $r.GenericDirRegex)
Check 'onzin-regex genegeerd'       (-not ($r.LangTags -contains '('))
Check 'en gemeld'                   (@($r.Warnings | Where-Object { $_ -match 'LangTagsAdd' }).Count -eq 1)
$r2 = New-RnRules ([pscustomobject]@{ JunkRemove = @('bestaatniet') })
Check 'onbekende Remove gemeld'     (@($r2.Warnings | Where-Object { $_ -match 'bestaatniet' }).Count -eq 1)
# delta werkt ook echt door in de namen
$sync.RenameRules = New-RnRules ([pscustomobject]@{ JunkAdd = @('Titel') })
Check 'delta werkt door'            ((Get-RnNewName 'F:\serie\Show\Show.S01E01.Titel.Nog.mkv') -ceq 'Show.S01E01.mkv')
$sync.RenameRules = New-RnRules $null
Check 'zonder delta weer standaard' ((Get-RnNewName 'F:\serie\Show\Show.S01E01.Titel.Nog.mkv') -ceq 'Show.S01E01.Titel.Nog.mkv')
# via JSON heen en terug, zoals in het instellingenbestand
$tpl = New-RnDeltaTemplate
Check 'sjabloon heeft Add en Remove' (($tpl.PSObject.Properties.Name -contains 'JunkAdd') -and ($tpl.PSObject.Properties.Name -contains 'ExcludePathRemove'))
$j = ([pscustomobject]@{ RenameRules = [pscustomobject]@{ JunkAdd = @('xyz'); ExcludePathAdd = @('*\privé\*') } } | ConvertTo-Json -Depth 6) | ConvertFrom-Json
$r3 = New-RnRules $j.RenameRules
Check 'uit JSON: token'             ('xyz' -match $r3.JunkRegex)
Check 'uit JSON: uitsluiting'       ($r3.ExcludePath -contains '*\privé\*')
''

'--- 3. het plan: dubbelen, ondertitels, conflicten ---'
$b = '/tmp/rn/a/serie/Show'
Fresh '/tmp/rn/a'
$f = @(
  "$b/Show.S01E01.1080p.WEB-DL.mkv", "$b/Show.S01E01.1080p.WEB-DL.nl.srt",
  "$b/Show.S01E01.720p.HDTV.mkv",    "$b/Show.S01E01.720p.HDTV.nl.srt",
  "$b/Show.S01E02.mkv", "$b/show.s01e02.720p.mkv",
  "$b/Show 2.S01E03.mkv", "$b/Show 2.S01E03 nl.srt",
  "$b/Show.S01E04.mkv", "$b/Show.S01E05.mkv",
  "$b/los.S01E09 Dutch.srt", "$b/los.s01e09.dutch.srt",
  '/tmp/rn/a/3d/print S01E01.mkv'
)
foreach ($x in $f) { Touch $x }
$plan = Get-RnPlan -Files $f -Frozen @("$b/Show.S01E04.mkv")
function Rij { param($naam) $plan | Where-Object { $_.Oud -eq $naam } }
Check 'beste versie blijft'         ((Rij 'Show.S01E01.1080p.WEB-DL.mkv').Status -eq 'OK')              "($((Rij 'Show.S01E01.1080p.WEB-DL.mkv').Status))"
Check 'slechtere versie weg'        ((Rij 'Show.S01E01.720p.HDTV.mkv').Status -eq 'VERWIJDEREN (dubbel)')
Check 'ondertitel van de dubbel ook' ((Rij 'Show.S01E01.720p.HDTV.nl.srt').Status -like 'VERWIJDEREN*')
Check 'ondertitel volgt de video'   ((Rij 'Show.S01E01.1080p.WEB-DL.nl.srt').Nieuw -ceq 'Show.S01E01.nl.srt')
Check 'dubbel zonder kenmerk wijkt'  ((Rij 'Show.S01E02.mkv').Status -eq 'VERWIJDEREN (dubbel)')        "($((Rij 'Show.S01E02.mkv').Status))"
Check 'de 720p neemt de naam'       ((Rij 'show.s01e02.720p.mkv').Nieuw -ceq 'Show.S01E02.mkv' -and (Rij 'show.s01e02.720p.mkv').Status -eq 'OK')
# twee ondertitels op dezelfde naam: wie al (op hoofdletters na) zo heet
# houdt zijn plek, de ander wordt een conflict
Check 'zelfde doel: conflict'       ((Rij 'los.S01E09 Dutch.srt').Status -like 'CONFLICT*')                  "($((Rij 'los.S01E09 Dutch.srt').Status))"
Check 'de ander houdt zijn plek'    ((Rij 'los.s01e09.dutch.srt').Status -like 'OK*')
Check 'al goed blijft staan'        ((Rij 'Show.S01E05.mkv').Status -eq 'AL GOED')
Check 'spatie-taal wordt .nl'       ((Rij 'Show 2.S01E03 nl.srt').Nieuw -ceq 'Show2.S01E03.nl.srt')     "($((Rij 'Show 2.S01E03 nl.srt').Nieuw))"
Check 'in gebruik: afblijven'       ((Rij 'Show.S01E04.mkv').Status -eq 'OVERGESLAGEN (in gebruik)')
Check 'ondertitel zonder video'     ((Rij 'los.s01e09.dutch.srt').Nieuw -ceq 'Los.S01E09.dutch.srt')      "($((Rij 'los.s01e09.dutch.srt').Nieuw))"
Check '3d-map niet aangeraakt'      (-not (Rij 'print S01E01.mkv'))
''

'--- 4. het plan uitvoeren, met undo ---'
$undo = '/tmp/rn/a/undo.csv'
$res = Invoke-RnPlan -Plan $plan -UndoFile $undo
$nu = Names $b
Check 'hernoemd'                    ($nu -contains 'Show.S01E01.mkv' -and $nu -contains 'Show.S01E01.nl.srt')   ("map: " + ($nu -join ', '))
Check 'dubbel weg'                  (-not ($nu -contains 'Show.S01E01.720p.HDTV.mkv') -and -not ($nu -contains 'Show.S01E01.720p.HDTV.nl.srt'))
Check 'in gebruik ongemoeid'        ($nu -contains 'Show.S01E04.mkv')
Check 'conflict ongemoeid'          ($nu -contains 'los.S01E09 Dutch.srt')
Check 'resultaat telt'              (@($res.Deleted).Count -eq 3 -and $res.Failed -eq 0)       "(weg=$(@($res.Deleted).Count) mis=$($res.Failed))"
$u = @(Import-Csv $undo)
Check 'undo-bestand'                ($u.Count -eq @($res.Renamed).Count -and $u.Count -ge 4)   "($($u.Count))"
# alleen hoofdletters anders
Fresh '/tmp/rn/c/serie/Kast'
Touch '/tmp/rn/c/serie/Kast/kast.s01e01.mkv'
$pc = Get-RnPlan -Files @('/tmp/rn/c/serie/Kast/kast.s01e01.mkv')
$rc = Invoke-RnPlan -Plan $pc -UndoFile ''
Check 'alleen hoofdletters'         ((Names '/tmp/rn/c/serie/Kast') -ceq @('Kast.S01E01.mkv'))   ("(" + ((Names '/tmp/rn/c/serie/Kast') -join ',') + ")")
''

'--- 5. terugdraaien met -HernoemTerug ---'
$pw = (Get-Process -Id $PID).Path
$voor = & $pw -NoProfile -File $AppScript -HernoemTerug $undo 2>&1
Check 'zonder -Uitvoeren: alleen kijken' ((Names $b) -contains 'Show.S01E01.mkv' -and (($voor -join ' ') -match 'voorbeeld'))
& $pw -NoProfile -File $AppScript -HernoemTerug $undo -Uitvoeren 2>&1 | Out-Null
$terug = Names $b
Check 'teruggezet'                  ($terug -contains 'Show.S01E01.1080p.WEB-DL.mkv' -and $terug -contains 'Show.S01E01.1080p.WEB-DL.nl.srt')   ("map: " + ($terug -join ', '))
''

'--- 6. een los bestand na de conversie ---'
$m = '/tmp/rn/b/serie/Dark'
Fresh '/tmp/rn/b'
Touch "$m/dark.s01e03.mkv"; Touch "$m/dark.s01e03.nl.srt"; Touch "$m/dark.s01e03.en.forced.srt"
Touch "$m/dark.s01e03 extra.mkv"; Touch "$m/dark.s01e03 extra.nl.srt"
$nieuw = Invoke-RnSingle -VideoPath "$m/dark.s01e03.mkv" -UndoFile '/tmp/rn/b/undo.csv'
$n6 = Names $m
Check 'video hernoemd'              ($nieuw -like '*Dark.S01E03.mkv' -and $n6 -contains 'Dark.S01E03.mkv')      ("map: " + ($n6 -join ', '))
Check 'ondertitels mee'             ($n6 -contains 'Dark.S01E03.nl.srt' -and $n6 -contains 'Dark.S01E03.en.forced.srt')
Check 'ondertitel van een andere video blijft' ($n6 -contains 'dark.s01e03 extra.nl.srt')
Check 'undo bijgehouden'            (@(Import-Csv '/tmp/rn/b/undo.csv').Count -eq 3)
Touch "$m/dark.s01e04.mkv"; Touch "$m/Dark.S01E04.mkv"
$zelf = Invoke-RnSingle -VideoPath "$m/dark.s01e04.mkv" -UndoFile ''
Check 'doel bestaat: niets doen'    ($zelf -like '*dark.s01e04.mkv' -and (Test-Path "$m/dark.s01e04.mkv"))
''

'--- 7. hernoemen na een echte conversie ---'
$c = '/tmp/rn/d/serie/Mijn Serie'
Fresh '/tmp/rn/d'
New-Item -ItemType Directory -Path $c -Force | Out-Null
MkVid "$c/mijn.serie.s02e07.720p.x264-GRP.mkv" 4
Set-Content "$c/mijn.serie.s02e07.720p.x264-GRP.nl.srt" 'a'
$s7 = Std-Settings -DeleteOrig $true -Subs $true -AudioMode 'aac' -TailCheck $false
$s7.RenameAfterConvert = $true
$s7.RenameUndoFile = '/tmp/rn/d/undo.csv'
Reset-Run $s7
$j7 = New-Job -FullPath "$c/mijn.serie.s02e07.720p.x264-GRP.mkv" -Dur 4.0
Enqueue-Jobs @($j7)
$w = Start-W $ConvertWorker 'conv'; while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }; Stop-W $w | Out-Null
$lg = @(Drain-Log)
$n7 = Names $c
Check 'geslaagd'                    ($sync.Success -eq 1)                                    "(succ=$($sync.Success))"
Check 'nette naam'                  ($n7 -contains 'MijnSerie.S02E07.mkv')                   ("map: " + ($n7 -join ', '))
Check 'ondertitel ook'              ($n7 -contains 'MijnSerie.S02E07.nl.srt')
Check 'geen .x265 meer in de naam'  (-not ($n7 | Where-Object { $_ -match 'x265' }))
Check 'in de resultaatkolom'        ($j7.ResultText -match 'MijnSerie\.S02E07\.mkv')          "($($j7.ResultText))"

# origineel bewaard + hernoemen: de volgende ronde ziet het resultaat
Fresh '/tmp/rn/e/serie/Kees'
MkVid '/tmp/rn/e/serie/Kees/kees.s01e01.x264.mkv' 4
$s8 = Std-Settings -DeleteOrig $false -Subs $false -AudioMode 'aac' -TailCheck $false
$s8.RenameAfterConvert = $true
$s8.RenameUndoFile = ''
Reset-Run $s8
Enqueue-Jobs @(New-Job -FullPath '/tmp/rn/e/serie/Kees/kees.s01e01.x264.mkv' -Dur 4.0)
$w = Start-W $ConvertWorker 'conv'; while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }; Stop-W $w | Out-Null
Drain-Log | Out-Null
Check 'origineel en nette naam'     ((Names '/tmp/rn/e/serie/Kees') -join ',' -eq 'kees.s01e01.x264.mkv,Kees.S01E01.mkv' -or
                                     ((Names '/tmp/rn/e/serie/Kees') -contains 'Kees.S01E01.mkv'))   ("map: " + ((Names '/tmp/rn/e/serie/Kees') -join ', '))
Reset-Run $s8
$j8 = New-Job -FullPath '/tmp/rn/e/serie/Kees/kees.s01e01.x264.mkv' -Dur 4.0
Enqueue-Jobs @($j8)
$w = Start-W $ConvertWorker 'conv'; while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }; Stop-W $w | Out-Null
Drain-Log | Out-Null
Check 'tweede keer: al omgezet'     ($j8.Status -eq 'Al omgezet')                            "($($j8.Status))"
''

'--- 8. de knop: bronmappen doorlopen, plan, uitvoeren ---'
$p7 = Get-Content -Raw $SrcDir/part7.ps1
$mw = [regex]::Match($p7, '(?s)\$RenameWorker = \{(.*?)\r?\n\}\r?\n')
Check 'worker gevonden'             ($mw.Success)
$RenameWorker = [scriptblock]::Create($mw.Groups[1].Value)
$g = '/tmp/rn/f/serie/Loki'
Fresh '/tmp/rn/f'
Touch "$g/loki.s01e01.1080p.mkv"; Touch "$g/loki.s01e01.1080p.nl.srt"
Touch "$g/loki.s01e02.1080p.mkv"
Touch "$g/x265_abc.tmp.mkv"
# de andere pc is met aflevering 2 bezig
Set-Content "$g/loki.s01e02.1080p.mkv.x265lock" ("pc=ANDER`nlaatst=" + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') + "`n")
$sync.ScanSettings = @{ Folders = @('/tmp/rn/f'); Recursive = $true; LockStaleMinutes = 15.0
                        PreviewFile = '/tmp/rn/f/voorbeeld.csv'; UndoFile = '/tmp/rn/f/undo.csv' }
$sync.ScanCancel = $false
$sync.ScanMode = 'hernoem-plan'
$w = Start-W $RenameWorker 'scan'; while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 100 }; Stop-W $w | Out-Null
$sync.ScanBusy = $false
$pl = @($sync.RenamePlan)
Check 'plan gemaakt'                ($pl.Count -eq 3)                                        "($($pl.Count))"
Check 'werkbestand niet meegenomen' (-not ($pl | Where-Object { $_.Oud -like 'x265_*' }))
Check 'bezet bestand afblijven'     (($pl | Where-Object { $_.Oud -eq 'loki.s01e02.1080p.mkv' }).Status -eq 'OVERGESLAGEN (in gebruik)')
Check 'voorbeeld-CSV'               (Test-Path '/tmp/rn/f/voorbeeld.csv')
Check 'nog niets veranderd'         ((Names $g) -contains 'loki.s01e01.1080p.mkv')
$sync.ScanMode = 'hernoem-uit'
$w = Start-W $RenameWorker 'scan'; while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 100 }; Stop-W $w | Out-Null
$sync.ScanBusy = $false
Drain-Log | Out-Null
$nf = Names $g
Check 'uitgevoerd'                  ($nf -contains 'Loki.S01E01.mkv' -and $nf -contains 'Loki.S01E01.nl.srt')   ("map: " + ($nf -join ', '))
Check 'bezette blijft'              ($nf -contains 'loki.s01e02.1080p.mkv')
Check 'resultaat voor de GUI'       (@($sync.RenameResult.Renamed).Count -eq 2)
''

'--- 9. de GUI-kant ---'
$p3 = Get-Content -Raw $SrcDir/part3.ps1
$p6 = Get-Content -Raw $SrcDir/part6.ps1
Check 'vinkje in het venster'       ($p3 -match 'x:Name="chkRenameAfter"[^>]*IsChecked="False"')
Check 'knop in het venster'         ($p3 -match 'x:Name="btnRename"')
Check 'vinkje wordt bewaard'        ($p6 -match 'RenameAfterConvert = \[bool\]\$ui\.chkRenameAfter\.IsChecked')
Check 'delta wordt bewaard'         ($p6 -match 'RenameRules\s+= ')
Check 'delta wordt gelezen'         ($p6 -match '\$script:RenameRulesDelta = \$saved\.RenameRules')
Check 'regels gebouwd bij opstarten' ($p6 -match '\$sync\.RenameRules = New-RnRules \$script:RenameRulesDelta')
Check 'niet tijdens een conversie'  ($p7 -match '\$ui\.btnRename\.IsEnabled = \(-not \$scanBusy\) -and \(-not \$convBusy\)')
Check 'start geblokkeerd tijdens hernoemen' ($p7 -match '(?s)btnStart\.Add_Click.{0,300}hernoem\*')
Check 'eerst bevestigen'            ($p7 -match "(?s)function Complete-Hernoemen.{0,4000}'YesNo'")
Check 'voorbeeld-CSV na de vraag weg' ($p7 -match "(?s)'YesNo', 'Question'\)\s*\r?\n\s*Remove-HernoemVoorbeeld")
Check 'oude CSVs bij het opstarten weg' ($p6 -match "hernoem_undo_\*' -and \`$f\.LastWriteTime -lt \(Get-Date\)\.AddDays\(-30\)")
''
"====> $ok goed, $bad fout"
