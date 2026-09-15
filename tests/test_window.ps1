# Zelfstandig: deze test laadt testlib niet, dus de paden hier uitzoeken.
$TestDir = $PSScriptRoot
if (-not $TestDir) { $TestDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$SrcDir = Join-Path (Split-Path -Parent $TestDir) 'src'
if (-not (Test-Path (Join-Path $SrcDir 'part2.ps1'))) { $SrcDir = $TestDir }
$AppScript = Join-Path (Split-Path -Parent $TestDir) 'X265-Converter.ps1'
if (-not (Test-Path $AppScript)) { $AppScript = Join-Path $TestDir 'X265-Converter.ps1' }

# De ECHTE Restore-WindowPlacement uit part7, met alleen de vier
# SystemParameters-regels vervangen door instelbare waarden en $win door
# een nepobject. Zo wordt de echte rekenlogica getoetst en geen kopie.
$bron = Get-Content -Raw $SrcDir/part7.ps1
$m = [regex]::Match($bron, '(?s)function Restore-WindowPlacement \{.*?\n\}\r?\n')
if (-not $m.Success) { 'FUNCTIE NIET GEVONDEN'; exit 1 }
$code = $m.Value
$code = $code -replace '\[double\]\[System\.Windows\.SystemParameters\]::VirtualScreenLeft',   '[double]$script:vL'
$code = $code -replace '\[double\]\[System\.Windows\.SystemParameters\]::VirtualScreenTop',    '[double]$script:vT'
$code = $code -replace '\[double\]\[System\.Windows\.SystemParameters\]::VirtualScreenWidth',  '[double]$script:vW'
$code = $code -replace '\[double\]\[System\.Windows\.SystemParameters\]::VirtualScreenHeight', '[double]$script:vH'
Invoke-Expression $code

$ok=0;$bad=0
function Check { param([string]$W,[bool]$C,[string]$E='') if($C){$script:ok++;"  OK    $W $E"}else{$script:bad++;"  FOUT  $W $E"} }

function NieuwVenster {
    $o = New-Object psobject -Property @{
        Left=[double]::NaN; Top=[double]::NaN; Width=1200.0; Height=900.0
        MinWidth=980.0; MinHeight=780.0
        WindowState='Normal'; WindowStartupLocation='CenterScreen'
    }
    return $o
}
function Scherm { param($L,$T,$W,$H) $script:vL=$L; $script:vT=$T; $script:vW=$W; $script:vH=$H }
function Zet { param($Saved) $script:win = NieuwVenster; $script:WindowMoved=$false; Restore-WindowPlacement $Saved; return $script:win }

'############ VENSTERPOSITIE OVER MONITORS HEEN ############'
''
'--- 1. twee schermen naast elkaar, alles nog aanwezig ---'
Scherm 0 0 3840 1080
$v = Zet ([pscustomobject]@{ Left=2100; Top=100; Width=1200; Height=900; Maximized=$false })
Check 'positie onveranderd'        ($v.Left -eq 2100 -and $v.Top -eq 100)          "(L=$($v.Left) T=$($v.Top))"
Check 'niet als verschoven gemeld' (-not $script:WindowMoved)
Check 'startlocatie op Manual'     ($v.WindowStartupLocation -eq 'Manual')
''
'--- 2. tweede scherm RECHTS gaat uit ---'
Scherm 0 0 1920 1080
$v = Zet ([pscustomobject]@{ Left=2100; Top=100; Width=1200; Height=900; Maximized=$false })
Check 'terug in beeld geschoven'   ($v.Left -ge 0 -and ($v.Left + $v.Width) -le 1920) "(L=$($v.Left) W=$($v.Width))"
Check 'hoogte past ook'            (($v.Top + $v.Height) -le 1080)                 "(T=$($v.Top) H=$($v.Height))"
Check 'wel gemeld in de log'       ($script:WindowMoved)
''
'--- 3. tweede scherm LINKS (negatieve X) gaat uit ---'
Scherm 0 0 1920 1080
$v = Zet ([pscustomobject]@{ Left=-1500; Top=-200; Width=1200; Height=900; Maximized=$false })
Check 'niet meer negatief'         ($v.Left -ge 0 -and $v.Top -ge 0)               "(L=$($v.Left) T=$($v.Top))"
Check 'gemeld'                     ($script:WindowMoved)
''
'--- 4. negatieve X terwijl dat scherm er NOG is: met rust laten ---'
Scherm -1920 0 3840 1080
$v = Zet ([pscustomobject]@{ Left=-1500; Top=100; Width=1200; Height=900; Maximized=$false })
Check 'blijft op het linkerscherm' ($v.Left -eq -1500)                             "(L=$($v.Left))"
Check 'niet gemeld'                (-not $script:WindowMoved)
''
'--- 5. venster groter dan het overgebleven scherm ---'
Scherm 0 0 1280 1024
$v = Zet ([pscustomobject]@{ Left=0; Top=0; Width=2400; Height=1800; Maximized=$false })
Check 'breedte ingekort'           ($v.Width -le 1280)                             "(W=$($v.Width))"
Check 'hoogte ingekort'            ($v.Height -le 1024)                            "(H=$($v.Height))"
Check 'linksboven geplaatst'       ($v.Left -eq 0 -and $v.Top -eq 0)
''
'--- 6. te kleine maten worden opgetrokken naar het minimum ---'
Scherm 0 0 3840 2160
$v = Zet ([pscustomobject]@{ Left=100; Top=100; Width=300; Height=200; Maximized=$false })
Check 'breedte minstens MinWidth'  ($v.Width -ge 980)                              "(W=$($v.Width))"
Check 'hoogte minstens MinHeight'  ($v.Height -ge 780)                             "(H=$($v.Height))"
''
'--- 7. gemaximaliseerd bewaard ---'
Scherm 0 0 1920 1080
$v = Zet ([pscustomobject]@{ Left=100; Top=50; Width=1400; Height=900; Maximized=$true })
Check 'komt gemaximaliseerd terug' ($v.WindowState -eq 'Maximized')
Check 'herstelmaat bewaard'        ($v.Left -eq 100 -and $v.Width -eq 1400)
''
'--- 8. onzin of ontbrekende waarden: niets doen ---'
foreach ($slecht in @(
    ([pscustomobject]@{ Left='abc'; Top=0; Width=1200; Height=900 }),
    ([pscustomobject]@{ Left=0; Width=1200; Height=900 }),
    ([pscustomobject]@{ Left=0; Top=0; Width=0; Height=900 }),
    $null )) {
    $v = Zet $slecht
    Check 'venster onaangeroerd'   ([double]::IsNaN($v.Left) -and $v.WindowStartupLocation -eq 'CenterScreen')
}
''
'--- 9. scherm meldt onzin (0 breed): niets doen ---'
Scherm 0 0 0 0
$v = Zet ([pscustomobject]@{ Left=100; Top=100; Width=1200; Height=900; Maximized=$false })
Check 'venster onaangeroerd'       ([double]::IsNaN($v.Left))
''
"====> $ok goed, $bad fout"
