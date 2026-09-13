. (Join-Path $PSScriptRoot 'testlib.ps1')
$ok=0;$bad=0
function Check { param([string]$W,[bool]$C,[string]$E='') if($C){$script:ok++;"  OK    $W $E"}else{$script:bad++;"  FOUT  $W $E"} }
function Fresh { param($D) if(Test-Path $D){Remove-Item -Recurse -Force $D}; New-Item -ItemType Directory -Path $D -Force|Out-Null }

function MkSrc { param($P,[int]$Sec=12)
  Set-Content -Path (Join-Path $WorkRoot 't.srt') -Value "1`n00:00:01,000 --> 00:00:03,000`neen`n`n2`n00:00:08,000 --> 00:00:10,000`ntwee`n"
  & $FFMPEG -hide_banner -loglevel error -y `
    -f lavfi -i "testsrc=size=320x240:rate=25:duration=$Sec" `
    -f lavfi -i "sine=frequency=440:duration=$Sec" -i (Join-Path $WorkRoot 't.srt') `
    -map 0:v -map 1:a -map 2:s -c:v libx264 -preset ultrafast -crf 34 -c:a aac -c:s srt $P 2>$null | Out-Null }

function Run { param($Dir,$Name,[bool]$Remux)
  Reset-Run (Std-Settings -DeleteOrig $true -Subs $false -AudioMode 'aac' -Remux $Remux)
  Enqueue-Jobs @(New-Job -FullPath "$Dir/$Name" -Dur 12.0)
  $w = Start-W $ConvertWorker 'conv'
  while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }
  Stop-W $w | Out-Null
  return @(Drain-Log) }

function Streams { param($P) (& $FFPROBE -v error -show_entries stream=codec_type -of csv=p=0 $P) -join ',' }

'############ REMUX ALS SLUITSTUK VAN DE CONVERSIE ############'
''
'--- 1. remux aan: alle sporen blijven, werkmap schoon ---'
Fresh $WorkRoot/rx/a
MkSrc "$WorkRoot/rx/a/film x264.mkv" 12
$log = Run $WorkRoot/rx/a 'film x264.mkv' $true
$f = @(Get-ChildItem $WorkRoot/rx/a -File | ForEach-Object Name)
Check 'uitvoer bestaat'              ($f -contains 'film.x265.mkv')
Check 'origineel verwijderd'         (-not ($f -contains 'film x264.mkv'))
Check 'geslaagd'                     ($sync.Success -eq 1)                 "(warned=$($sync.Warned) failed=$($sync.Failed))"
Check 'video+audio+ondertitel over'  ((Streams "$WorkRoot/rx/a/film.x265.mkv") -eq 'video,audio,subtitle') ("-> " + (Streams "$WorkRoot/rx/a/film.x265.mkv"))
Check 'log meldt de remux'           (($log -join ' ') -match 'Container opnieuw opbouwen')
Check 'log meldt dat het lukte'      (($log -join ' ') -match 'Remux gelukt')
Check 'max_interleave_delta gebruikt'(($log -join ' ') -match 'max_interleave_delta 0')
$rest = @(Get-ChildItem $WorkRoot/x265work -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'x265_*' })
Check 'geen tijdelijke bestanden'    ($rest.Count -eq 0)                   "($($rest.Count) over)"
''
'--- 2. remux uit: nog steeds een goed bestand ---'
Fresh $WorkRoot/rx/b
MkSrc "$WorkRoot/rx/b/film2 x264.mkv" 12
$log = Run $WorkRoot/rx/b 'film2 x264.mkv' $false
Check 'uitvoer bestaat'              (Test-Path "$WorkRoot/rx/b/film2.x265.mkv")
Check 'geslaagd'                     ($sync.Success -eq 1)
Check 'geen remux in de log'         (-not (($log -join ' ') -match 'Container opnieuw opbouwen'))
Check 'vlag zit toch in de encode'   (($log -join ' ') -match 'max_interleave_delta 0')
''
'--- 3. interleaving van het eindresultaat gemeten ---'
$m = & python3 $WorkRoot/il/il2.py $WorkRoot/rx/a/film.x265.mkv $WorkRoot/rx/b/film2.x265.mkv
$m
Check 'geen SLECHT in de meting'     (-not (($m -join ' ') -match 'SLECHT'))
''
"====> $ok goed, $bad fout"
