. (Join-Path $PSScriptRoot 'testlib.ps1')
$ok = 0; $bad = 0
function Check { param([string]$What,[bool]$Cond,[string]$Extra='')
  if ($Cond) { $script:ok++; "  OK    $What $Extra" } else { $script:bad++; "  FOUT  $What $Extra" } }
function Fresh { param([string]$Dir)
  if (Test-Path $Dir) { Remove-Item -Recurse -Force $Dir }
  New-Item -ItemType Directory -Path $Dir -Force | Out-Null }

# bronbestand met een echt gat van 4 s in de audio-tijdstempels
function MkGap { param([string]$Path,[int]$Ch=1)
  $pan = if ($Ch -eq 6) { ',pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0' } else { '' }
  & $FFMPEG -hide_banner -loglevel error -y `
    -f lavfi -i "testsrc=size=320x240:rate=25:duration=20" `
    -f lavfi -i "sine=frequency=440:duration=20:sample_rate=48000" `
    -filter_complex "[1:a]aselect='not(between(t,8,12))'$pan[a]" `
    -map 0:v -map '[a]' -c:v libx264 -preset ultrafast -crf 32 -c:a aac -b:a 128k $Path 2>$null | Out-Null }

function GapOf { param([string]$Path)
  $j = (& $FFPROBE -v error -select_streams a:0 -show_packets `
          -show_entries packet=pts_time,duration_time -of json $Path) -join "`n" | ConvertFrom-Json
  $prev = $null; $worst = 0.0
  foreach ($p in $j.packets) {
    $t = [double]$p.pts_time; $d = 0.0
    if ($p.duration_time) { $d = [double]$p.duration_time }
    if ($prev -ne $null -and ($t - $prev) -gt $worst) { $worst = $t - $prev }
    $prev = $t + $d
  }
  return $worst }

function AudioOf { param([string]$Path)
  $c = (& $FFPROBE -v error -select_streams a:0 -show_entries stream=codec_name,channels -of csv=p=0 $Path) -join ''
  return $c }

function DecodeClean { param([string]$Path)
  $e = (& $FFMPEG -v error -i $Path -f null - 2>&1) -join ''
  return [string]::IsNullOrWhiteSpace($e) }

function RunOne { param([string]$Dir,[string]$Mode,[int]$Ch=1)
  Fresh $Dir
  MkGap "$Dir/film x264.mkv" $Ch
  Reset-Run (Std-Settings -DeleteOrig $false -Subs $false -AudioMode $Mode)
  Enqueue-Jobs @(New-Job -FullPath "$Dir/film x264.mkv" -Dur 20.0)
  $w = Start-W $ConvertWorker 'conv'
  while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }
  Stop-W $w | Out-Null
  return @(Drain-Log) }

'############ GELUID: TIJDSTEMPELS EN MODI ############'
''
'--- 0. argumentopbouw (unittest) ---'
$stub = @{ Codec='libx265'; Preset='medium'; Crf=23; AudioMode='copy' }
$probe = { param($p) 2 }
# Get-AudioArgs zit in de worker-runspace; hier via een mini-runspace testen
$sb = [scriptblock]::Create(@"
`$st = @{ Codec='libx265'; Preset='medium'; Crf=23; AudioMode='__M__' }
$($ConvertWorker.ToString() -replace '(?s)^.*?function Get-AudioArgs', 'function Get-AudioArgs' -replace '(?s)\r?\n    function Get-EncodeArgs.*$', '')
(Get-AudioArgs -Mode '__M__' -Channels __C__) -join ' '
"@)
foreach ($t in @(@('copy',2,'-c:a copy'), @('aac',2,'-c:a aac -b:a 192k -af aresample=async=1:first_pts=0'),
                 @('aac',6,'-c:a aac -b:a 384k -af aresample=async=1:first_pts=0'),
                 @('aac',12,'-ac 8 -c:a aac -b:a 512k -af aresample=async=1:first_pts=0'),
                 @('ac3',2,'-c:a ac3 -b:a 224k -af aresample=async=1:first_pts=0'),
                 @('ac3',8,'-ac 6 -c:a ac3 -b:a 448k -af aresample=async=1:first_pts=0'),
                 @('flac',2,'-c:a flac -compression_level 5 -af aresample=async=1:first_pts=0'))) {
    $code = $sb.ToString().Replace('__M__',$t[0]).Replace('__C__',"$($t[1])")
    $res = (& ([scriptblock]::Create($code))) -join ' '
    Check ("args {0}/{1}ch" -f $t[0],$t[1]) ($res.Trim() -eq $t[2]) "-> $res"
}
''
$srcGap = 0.0
'--- 1. kopieren: het gat blijft staan (dit is de klacht) ---'
$log = RunOne /tmp/aud/c 'copy'
$srcGap = GapOf '/tmp/aud/c/film x264.mkv'
$g = GapOf '/tmp/aud/c/film.mkv'
Check 'bron heeft een gat van ~4 s'  ($srcGap -gt 3.5)                "bron=$([math]::Round($srcGap,3))s"
Check 'kopieren neemt het gat over'  ($g -gt 3.5)                     "uit=$([math]::Round($g,3))s"
Check 'kopieren wijzigt codec niet'  ((AudioOf '/tmp/aud/c/film.mkv') -like 'aac*')
''
'--- 2. aac: het gat is weg ---'
$log = RunOne /tmp/aud/a 'aac'
$g = GapOf '/tmp/aud/a/film.mkv'
Check 'aac vult het gat op'          ($g -lt 0.1)                     "uit=$([math]::Round($g,3))s"
Check 'aac decodeert schoon'         (DecodeClean '/tmp/aud/a/film.mkv')
Check 'aac in de log gemeld'         (($log -join ' ') -match 'Geluid: aac')
Check 'kanaalaantal gemeld'          (($log -join ' ') -match 'bron heeft 1 kanaal')
''
'--- 3. ac3 en flac: ook geen gat ---'
$log = RunOne /tmp/aud/b 'ac3'
$g = GapOf '/tmp/aud/b/film.mkv'
Check 'ac3 vult het gat op'          ($g -lt 0.1)                     "uit=$([math]::Round($g,3))s"
Check 'ac3 is ook echt ac3'          ((AudioOf '/tmp/aud/b/film.mkv') -like 'ac3*')
$log = RunOne /tmp/aud/f 'flac'
$g = GapOf '/tmp/aud/f/film.mkv'
Check 'flac vult het gat op'         ($g -lt 0.1)                     "uit=$([math]::Round($g,3))s"
Check 'flac is ook echt flac'        ((AudioOf '/tmp/aud/f/film.mkv') -like 'flac*')
''
'--- 4. 5.1 bron blijft 5.1 ---'
$log = RunOne /tmp/aud/six 'aac' 6
Check '5.1 blijft 6 kanalen'         ((AudioOf '/tmp/aud/six/film.mkv') -eq 'aac,6') ("-> " + (AudioOf '/tmp/aud/six/film.mkv'))
Check '5.1 gat opgevuld'             ((GapOf '/tmp/aud/six/film.mkv') -lt 0.1)
''
'--- 5. sync blijft staan bij vertraagde audio ---'
Fresh /tmp/aud/s
& $FFMPEG -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=10" -itsoffset 2 -f lavfi -i "sine=frequency=1000:duration=8" -map 0:v -map 1:a -c:v libx264 -preset ultrafast -crf 32 -c:a aac '/tmp/aud/s/vertraagd x264.mkv' 2>$null | Out-Null
Reset-Run (Std-Settings -DeleteOrig $false -Subs $false -AudioMode 'aac')
Enqueue-Jobs @(New-Job -FullPath '/tmp/aud/s/vertraagd x264.mkv' -Dur 10.0)
$w = Start-W $ConvertWorker 'conv'; while (-not $w.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }; Stop-W $w | Out-Null
Drain-Log | Out-Null
$pyOut = & python3 -c @"
import subprocess
raw = subprocess.run(['ffmpeg','-v','error','-i','/tmp/aud/s/vertraagd.mkv','-map','0:a','-ac','1','-ar','8000','-f','f32le','-'],capture_output=True).stdout
import struct
a = struct.unpack('<%df' % (len(raw)//4), raw[:len(raw)//4*4])
first = next((i for i,v in enumerate(a) if abs(v) > 0.01), -1)
print('%.3f' % (first/8000.0))
"@
Check 'toon staat nog op ~2 s'       ([double]$pyOut -gt 1.8 -and [double]$pyOut -lt 2.3) "t=$pyOut s"
''
"====> $ok goed, $bad fout"
