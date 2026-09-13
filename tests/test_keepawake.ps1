$ok=0;$bad=0
function Check { param([string]$W,[bool]$C,[string]$E='') if($C){$script:ok++;"  OK    $W $E"}else{$script:bad++;"  FOUT  $W $E"} }

# De echte functie, maar met de .NET-aanroep vervangen door een teller:
# named events bestaan niet op Linux, dus de bewaking eromheen is wat hier
# te toetsen valt.
$script:Pogingen = 0
$script:Gedrag   = 'draait'     # 'draait' | 'draait-niet' | 'stuk'
$script:Log      = New-Object System.Collections.ArrayList
function Write-Log { param($m,$l='INFO') [void]$script:Log.Add("$l $m") }

$script:KeepAwakeStopped = $false
function Stop-KeepAwake {
    param([switch]$Force)
    if ($script:KeepAwakeStopped -and -not $Force) { return }
    $naam = [string]$script:KeepAwakeSignal
    if ([string]::IsNullOrWhiteSpace($naam)) { return }
    $script:KeepAwakeStopped = $true
    try {
        $script:Pogingen++
        switch ($script:Gedrag) {
            'draait-niet' { throw (New-Object System.Threading.WaitHandleCannotBeOpenedException) }
            'stuk'        { throw (New-Object System.InvalidOperationException 'iets anders') }
        }
        Write-Log ("KeepAwake-signaal '{0}' verstuurd; de pc mag weer slapen." -f $naam)
    }
    catch [System.Threading.WaitHandleCannotBeOpenedException] { }
    catch { Write-Log ("KeepAwake kon niet worden gestopt: {0}" -f $_.Exception.Message) 'WAARS' }
}

'############ KEEPAWAKE STOPPEN ############'
''
'--- 1. KeepAwake draait: signaal gaat af, en maar een keer ---'
$script:KeepAwakeSignal='KeepAwakeStopSignal'; $script:Gedrag='draait'
$script:KeepAwakeStopped=$false; $script:Pogingen=0; $script:Log.Clear()
Stop-KeepAwake; Stop-KeepAwake; Stop-KeepAwake
Check 'precies een poging'          ($script:Pogingen -eq 1)                    "(=$($script:Pogingen))"
Check 'meldt het in de log'         (($script:Log -join ' ') -match 'signaal .* verstuurd')
Check 'geen waarschuwing'           (-not (($script:Log -join ' ') -match 'WAARS'))
''
'--- 2. nieuwe run: mag opnieuw ---'
$script:KeepAwakeStopped=$false
Stop-KeepAwake
Check 'tweede run stuurt opnieuw'   ($script:Pogingen -eq 2)                    "(=$($script:Pogingen))"
''
'--- 3. KeepAwake draait niet: stil, geen melding ---'
$script:Gedrag='draait-niet'; $script:KeepAwakeStopped=$false; $script:Pogingen=0; $script:Log.Clear()
Stop-KeepAwake
Check 'wel geprobeerd'              ($script:Pogingen -eq 1)
Check 'geen enkele logregel'        ($script:Log.Count -eq 0)                   "($($script:Log.Count) regels)"
''
'--- 4. iets anders mis: wel melden, niet omvallen ---'
$script:Gedrag='stuk'; $script:KeepAwakeStopped=$false; $script:Pogingen=0; $script:Log.Clear()
Stop-KeepAwake
Check 'waarschuwing in de log'      (($script:Log -join ' ') -match 'WAARS.*kon niet worden gestopt')
''
'--- 5. lege signaalnaam: helemaal uitgeschakeld ---'
$script:KeepAwakeSignal=''; $script:Gedrag='draait'; $script:KeepAwakeStopped=$false
$script:Pogingen=0; $script:Log.Clear()
Stop-KeepAwake
Check 'geen poging'                 ($script:Pogingen -eq 0)
Check 'vlag blijft vrij'            ($script:KeepAwakeStopped -eq $false)
''
'--- 6. -Force negeert de bewaking ---'
$script:KeepAwakeSignal='KeepAwakeStopSignal'; $script:KeepAwakeStopped=$true; $script:Pogingen=0
Stop-KeepAwake -Force
Check 'Force stuurt toch'           ($script:Pogingen -eq 1)
''
"====> $ok goed, $bad fout"
