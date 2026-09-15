. (Join-Path $PSScriptRoot 'testlib.ps1')
$ok=0;$bad=0
function Check { param([string]$W,[bool]$C,[string]$E='') if($C){$script:ok++;"  OK    $W $E"}else{$script:bad++;"  FOUT  $W $E"} }
function Fresh { param($D) if(Test-Path $D){Remove-Item -Recurse -Force $D}; New-Item -ItemType Directory -Path $D -Force|Out-Null }
function MkVid { param($P,[int]$Sec=4,[string]$V='libx264')
  & $FFMPEG -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=$Sec" `
    -f lavfi -i "sine=duration=$Sec" -map 0:v -map 1:a -c:v $V -preset ultrafast -crf 36 -c:a aac $P 2>$null | Out-Null }
function RunScan {
  param($Settings)
  $sync.ScanSettings = $Settings
  $sync.ScanCancel=$false; $sync.ScanTotal=0; $sync.ScanChecked=0; $sync.ScanFound=0
  $sync.ScanSkippedHevc=0; $sync.ScanSkippedVcp=0; $sync.ScanSkippedNoVid=0; $sync.ScanMode='scan'
  $w = Start-W $ScanWorker 'scan'
  while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 120 }
  Stop-W $w | Out-Null
}

'############ NASCAN EN AUTOMATISCH KIJKEN ############'
''
'--- 1. de scan kan meteen in de wachtrij zetten ---'
Fresh '/tmp/wt'
MkVid '/tmp/wt/nieuw een.mkv' 4
MkVid '/tmp/wt/nieuw twee.mkv' 4
MkVid '/tmp/wt/al hevc.mkv' 4 'libx265'

$sync.LockGezien = $false
RunScan @{ Folders=@('/tmp/wt'); Extensions=@('mkv'); Recursive=$true; VcpMarker='VCP'; LockStaleMinutes=15.0; AutoQueue=$true }
Drain-Log | Out-Null
$gevonden = @(Drain-Jobs)
# Al-HEVC-bestanden komen wel in de LIJST (als 'Al HEVC'), maar horen
# niet in de wachtrij te belanden.
Check 'drie regels aangeboden'    ($gevonden.Count -eq 3)                             "($($gevonden.Count))"
Check 'twee mogen in de wachtrij' (@($gevonden | Where-Object { $_.AutoQueue }).Count -eq 2)
Check 'de HEVC niet'              (@($gevonden | Where-Object { $_.IsHevc -and $_.AutoQueue }).Count -eq 0)
Check 'al HEVC geteld'            ($sync.ScanSkippedHevc -eq 1)
Check 'geen lock gezien'          (-not $sync.LockGezien)

RunScan @{ Folders=@('/tmp/wt'); Extensions=@('mkv'); Recursive=$true; VcpMarker='VCP'; LockStaleMinutes=15.0 }
Drain-Log | Out-Null
$gewoon = @(Drain-Jobs)
Check 'zonder vlag geen AutoQueue' (@($gewoon | Where-Object { $_.AutoQueue }).Count -eq 0)
''

'--- 2. een lock in de map wordt onthouden ---'
Fresh '/tmp/wt2'
MkVid '/tmp/wt2/film.mkv' 4
Set-Content '/tmp/wt2/andere.mkv.x265lock' ("pc=MINIPC3`nlaatst=" + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') + "`n")
$sync.LockGezien = $false
RunScan @{ Folders=@('/tmp/wt2'); Extensions=@('mkv'); Recursive=$true; VcpMarker='VCP'; LockStaleMinutes=15.0 }
Drain-Log | Out-Null
Drain-Jobs | Out-Null
Check 'scan onthoudt het lock'    ($sync.LockGezien)
''

'--- 3. de conversie onthoudt het ook ---'
Fresh '/tmp/wt3'
MkVid '/tmp/wt3/bezet.mkv' 4
MkVid '/tmp/wt3/vrij.mkv' 4
$ander = Take-Lock -SourcePath '/tmp/wt3/bezet.mkv' -StaleMinutes 15 -Stamp 'andere pc'
Reset-Run (Std-Settings -DeleteOrig $false -Subs $false -AudioMode 'aac' -TailCheck $false -Locks $true)
$sync.LockGezien = $false
Enqueue-Jobs @((New-Job -FullPath '/tmp/wt3/bezet.mkv' -Dur 4.0), (New-Job -FullPath '/tmp/wt3/vrij.mkv' -Dur 4.0))
$w = Start-W $ConvertWorker 'conv'
while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 150 }
Stop-W $w | Out-Null
Drain-Log | Out-Null
Release-Lock $ander.Lock
Check 'lock van de ander gezien'  ($sync.LockGezien)
Check 'de vrije is wel gedaan'    ($sync.Success -eq 1)                                "($($sync.Success))"

# met locks uit hoort de vlag juist op false te komen
Fresh '/tmp/wt4'
MkVid '/tmp/wt4/los.mkv' 4
Reset-Run (Std-Settings -DeleteOrig $false -Subs $false -AudioMode 'aac' -TailCheck $false -Locks $false)
$sync.LockGezien = $true
Enqueue-Jobs @((New-Job -FullPath '/tmp/wt4/los.mkv' -Dur 4.0))
$w = Start-W $ConvertWorker 'conv'
while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 150 }
Stop-W $w | Out-Null
Drain-Log | Out-Null
Check 'zonder locks weer op false' (-not $sync.LockGezien)
''

'--- 4. de nascan gebeurt precies een keer ---'
$p7 = Get-Content -Raw $SrcDir/part7.ps1
$p8 = Get-Content -Raw $SrcDir/part8.ps1
Check 'nascan heeft een geheugen'  ($p7 -match '\$script:NascanGedaan = \$false')
Check 'en slaat over als het al is geweest' ($p7 -match 'if \(\$script:NascanGedaan\) \{ return \$false \}')
Check 'zet de vlag voor het starten'        ($p7 -match '\$script:NascanGedaan  = \$true')
Check 'handmatig starten geeft hem vrij'    ($p7 -match '(?s)btnStart\.Add_Click.{0,200}NascanGedaan = \$false')
Check 'automatisch kijken ook'              ($p7 -match '(?s)function Start-WatchScan.{0,1400}NascanGedaan = \$false')
Check 'haalt stale regels uit de lijst'     ($p7 -match "(?s)function Start-Nascan.{0,1500}'Andere pc bezig'.{0,200}Remove-JobRow")
''

'--- 5. wanneer de nascan NIET mag ---'
Check 'niet na een eigen stop'     ($p8 -match '-not \$gestopt -and \[bool\]\$sync\.LockGezien')
Check 'stopvlaggen eerst bewaard'  ($p8 -match '\$gestopt = \(\[bool\]\$sync\.Cancel -or \[bool\]\$sync\.StopAfterCurrent\)')
Check 'niet na een noodstop'       ($p8 -match '(?s)if \(\$emergency\).{0,2000}else \{.{0,800}Start-Nascan')
Check 'afsluiten wacht op de nascan' ($p8 -match '-not \$nascan -and \[bool\]\$ui\.chkExitAfter\.IsChecked')
''

'--- 6. elk uur kijken ---'
Check 'vinkje bestaat'             ((Get-Content -Raw $SrcDir/part3.ps1) -match 'x:Name="chkWatch"')
Check 'standaard uit'              ((Get-Content -Raw $SrcDir/part3.ps1) -match 'x:Name="chkWatch"[^>]*IsChecked="False"')
Check 'klok in de tik'             ($p8 -match '\$script:WatchVanaf')
Check 'alleen als er niets loopt'  ($p8 -match '\$sync\.ScanBusy -or \$sync\.ConvBusy -or \$sync\.Queue\.Count -gt 0')
Check 'en de wachtrij leeg is'     ($p7 -match '(?s)function Start-WatchScan.{0,300}\$sync\.Queue\.Count -gt 0.*?return \$false')
Check 'zonder pop-up'              ($p7 -notmatch '(?s)function Start-WatchScan.{0,1600}MessageBox')
Check 'zet meteen in de wachtrij'  ($p7 -match '(?s)function Start-WatchScan.{0,900}Get-ScanSettings -AutoQueue \$true')
Check 'wordt bewaard'              ((Get-Content -Raw $SrcDir/part6.ps1) -match 'WatchFolders  = \[bool\]\$ui\.chkWatch\.IsChecked')
Check 'en teruggezet'              ((Get-Content -Raw $SrcDir/part6.ps1) -match '\$ui\.chkWatch\.IsChecked      = \[bool\]\$saved\.WatchFolders')
''

'--- 7. kijken en afsluiten sluiten elkaar uit ---'
Check 'de combinatie wordt bewaakt' ($p7 -match 'function Set-WatchExitCombinatie')
Check 'afsluiten gaat uit'          ($p7 -match '(?s)Set-WatchExitCombinatie.{0,600}chkExitAfter\.IsChecked = \$false')
Check 'en op slot'                  ($p7 -match '(?s)Set-WatchExitCombinatie.{0,600}chkExitAfter\.IsEnabled = \$false')
Check 'en weer vrij als het uitgaat' ($p7 -match '(?s)Set-WatchExitCombinatie.{0,900}else \{\s*\r?\n\s*\$ui\.chkExitAfter\.IsEnabled = \$true')
Check 'ook bij het opstarten'       ($p8 -match 'Set-WatchExitCombinatie')
Check 'vinkje reageert meteen'      ($p7 -match 'chkWatch\.Add_Checked')
''

'--- 8. geen bevestigingsvenster meer bij Start ---'
$start = $p7.Substring($p7.IndexOf('$ui.btnStart.Add_Click'))
$start = $start.Substring(0, $start.IndexOf('Start-Worker $ConvertWorker'))
Check 'geen Starten?-vraag'        ($start -notmatch 'Starten\?')
Check 'geen OKCancel'              ($start -notmatch 'OKCancel')
Check 'overzicht staat in de log'  ($start -match "Write-Log \(""Start: \{0\} bestand\(en\)")
Check 'encoder erbij'              ($start -match 'Encoder \{0\}, preset \{1\}')
Check 'uitwijkmap zonder venster'  ($start -match "(?s)uitgeweken naar \{1\}.{0,200}Set-Status" )
# echte fouten mogen wel een venster geven
Check 'werkmap-fout meldt nog wel' ($start -match "(?s)geen bruikbaar alternatief.{0,120}MessageBox|MessageBox.{0,200}geen bruikbaar alternatief")
''
"====> $ok goed, $bad fout"
