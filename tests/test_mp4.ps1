. (Join-Path $PSScriptRoot 'testlib.ps1')
$ok=0;$bad=0
function Check { param([string]$W,[bool]$C,[string]$E='') if($C){$script:ok++;"  OK    $W $E"}else{$script:bad++;"  FOUT  $W $E"} }
function Fresh { param($D) if(Test-Path $D){Remove-Item -Recurse -Force $D}; New-Item -ItemType Directory -Path $D -Force|Out-Null }
$FF='$FFMPEG'; $FP='$FFPROBE'
function Streams { param($P) ((& $FP -v error -show_entries stream=codec_type -of csv=p=0 $P) -join ',') }
function Run { param($Dir,$Name,[int]$Dur)
  Reset-Run (Std-Settings -DeleteOrig $false -Subs $false -AudioMode 'aac')
  Enqueue-Jobs @(New-Job -FullPath "$Dir/$Name" -Dur ([double]$Dur))
  $w = Start-W $ConvertWorker 'conv'
  while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }
  Stop-W $w | Out-Null
  return @(Drain-Log) }

'############ MP4-SPOREN DIE MKV NIET AANKAN ############'
''
'--- 1. mp4 met timecodespoor (tmcd) ---'
Fresh $WorkRoot/m4/a
& $FF -v error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=10" -f lavfi -i "sine=duration=10" `
  -map 0:v -map 1:a -c:v libx264 -preset ultrafast -crf 36 -c:a aac -timecode 00:00:00:00 "$WorkRoot/m4/a/tc x264.mp4" 2>$null | Out-Null
Check 'bron heeft een datastroom'    ((Streams "$WorkRoot/m4/a/tc x264.mp4") -match 'data')  ("-> " + (Streams "$WorkRoot/m4/a/tc x264.mp4"))
$log = Run $WorkRoot/m4/a 'tc x264.mp4' 10
Check 'conversie geslaagd'           ($sync.Success -eq 1)                              "(succ=$($sync.Success) fail=$($sync.Failed))"
Check 'geen herpoging nodig'         (-not (($log -join ' ') -match 'Eerste poging mislukt'))
Check 'datastroom gemeld'            (($log -join ' ') -match 'kan niet in mkv, niet meegenomen')
Check 'uitvoer heeft beeld+geluid'   ((Streams "$WorkRoot/m4/a/tc.x265.mkv") -eq 'video,audio') ("-> " + (Streams "$WorkRoot/m4/a/tc.x265.mkv"))
''
'--- 2. mp4 met mov_text-ondertitels EN een timecodespoor ---'
Fresh $WorkRoot/m4/b
Set-Content -Path $WorkRoot/m4/s.srt -Value "1`n00:00:01,000 --> 00:00:03,000`nhallo`n"
& $FF -v error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=10" -f lavfi -i "sine=duration=10" -i $WorkRoot/m4/s.srt `
  -map 0:v -map 1:a -map 2:s -c:v libx264 -preset ultrafast -crf 36 -c:a aac -c:s mov_text -timecode 00:00:00:00 "$WorkRoot/m4/b/mt x264.mp4" 2>$null | Out-Null
Check 'bron: mov_text + data'        ((Streams "$WorkRoot/m4/b/mt x264.mp4") -match 'subtitle' -and (Streams "$WorkRoot/m4/b/mt x264.mp4") -match 'data')
$log = Run $WorkRoot/m4/b 'mt x264.mp4' 10
Check 'conversie geslaagd'           ($sync.Success -eq 1)                              "(succ=$($sync.Success) fail=$($sync.Failed))"
Check 'geen herpoging nodig'         (-not (($log -join ' ') -match 'Eerste poging mislukt'))
Check 'omzetting naar srt gemeld'    (($log -join ' ') -match 'worden omgezet naar srt')
Check 'ondertitel is meegekomen'     ((Streams "$WorkRoot/m4/b/mt.x265.mkv") -eq 'video,audio,subtitle') ("-> " + (Streams "$WorkRoot/m4/b/mt.x265.mkv"))
Check 'en is nu subrip'              (((& $FP -v error -select_streams s:0 -show_entries stream=codec_name -of csv=p=0 "$WorkRoot/m4/b/mt.x265.mkv") -join '') -match 'subrip')
''
'--- 3. mp4 met omslagafbeelding ---'
Fresh $WorkRoot/m4/c
& $FF -v error -y -f lavfi -i "color=c=red:s=64x64:d=1" -frames:v 1 $WorkRoot/m4/cover.png 2>$null | Out-Null
& $FF -v error -y -i "$WorkRoot/m4/a/tc x264.mp4" -i $WorkRoot/m4/cover.png -map 0:v -map 0:a -map 1 `
  -c copy -disposition:v:1 attached_pic "$WorkRoot/m4/c/cov x264.mp4" 2>$null | Out-Null
Check 'bron heeft 2 videosporen'     ((@((Streams "$WorkRoot/m4/c/cov x264.mp4") -split ',') | Where-Object { $_ -eq 'video' }).Count -eq 2)
$log = Run $WorkRoot/m4/c 'cov x264.mp4' 10
Check 'conversie geslaagd'           ($sync.Success -eq 1)                              "(succ=$($sync.Success) fail=$($sync.Failed))"
Check 'omslag overgeslagen'          (($log -join ' ') -match 'omslagafbeelding, niet meegenomen')
Check 'uitvoer 1x beeld, 1x geluid'  ((Streams "$WorkRoot/m4/c/cov.x265.mkv") -eq 'video,audio') ("-> " + (Streams "$WorkRoot/m4/c/cov.x265.mkv"))
''
'--- 4. gewone mkv met srt: alles blijft gewoon meekomen ---'
Fresh $WorkRoot/m4/d
& $FF -v error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=10" -f lavfi -i "sine=duration=10" -i $WorkRoot/m4/s.srt `
  -map 0:v -map 1:a -map 2:s -c:v libx264 -preset ultrafast -crf 36 -c:a aac -c:s srt "$WorkRoot/m4/d/ok x264.mkv" 2>$null | Out-Null
$log = Run $WorkRoot/m4/d 'ok x264.mkv' 10
Check 'conversie geslaagd'           ($sync.Success -eq 1)
Check 'ondertitel gekopieerd'        ((Streams "$WorkRoot/m4/d/ok.x265.mkv") -eq 'video,audio,subtitle')
Check 'geen onnodige meldingen'      (-not (($log -join ' ') -match 'niet meegenomen'))
''
"====> $ok goed, $bad fout"
