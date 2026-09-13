# Toetst de opslag-/terugzetlogica zonder GUI: de twee takken van
# Save-Settings en wat Add_Loaded met een bewaarde lijst doet.
$ok=0;$bad=0
function Check { param([string]$W,[bool]$C,[string]$E='') if($C){$script:ok++;"  OK    $W $E"}else{$script:bad++;"  FOUT  $W $E"} }

$rows = @(
  [pscustomobject]@{ FullPath='/x/een.mkv'; Status='In wachtrij' }
  [pscustomobject]@{ FullPath='/x/twee.mkv'; Status='In wachtrij' }
)

'############ WACHTRIJ BEWAREN OF NIET ############'
''
'--- 1. RestoreQueue uit: lege lijst in het instellingenbestand ---'
$script:RestoreQueue = $false
$q = $(if ($script:RestoreQueue) { @($rows) } else { @() })
Check 'Queue wordt leeg weggeschreven'  (@($q).Count -eq 0)                 "(count=$(@($q).Count))"
$json = ([pscustomobject]@{ RestoreQueue=$script:RestoreQueue; Queue=$q }) | ConvertTo-Json -Depth 6
Check 'json blijft klein'               ($json.Length -lt 200)              "($($json.Length) tekens)"
Check 'instelling staat erin'           ($json -match '"RestoreQueue":\s*false')
''
'--- 2. RestoreQueue aan: de regels gaan wel mee ---'
$script:RestoreQueue = $true
$q = $(if ($script:RestoreQueue) { @($rows) } else { @() })
Check 'Queue wordt bewaard'             (@($q).Count -eq 2)
$json2 = ([pscustomobject]@{ RestoreQueue=$script:RestoreQueue; Queue=$q }) | ConvertTo-Json -Depth 6
Check 'paden staan in de json'          ($json2 -match 'een\.mkv' -and $json2 -match 'twee\.mkv')
''
'--- 3. de tak in Add_Loaded ---'
foreach ($aan in @($true,$false)) {
    $script:RestoreQueue = $aan
    $hersteld = $false; $gemeld = $false
    $SavedSettings = [pscustomobject]@{ Queue = $rows }
    if ($script:RestoreQueue) { $hersteld = $true }
    else {
        $bewaard = 0
        if ($SavedSettings -and $SavedSettings.Queue) { $bewaard = @($SavedSettings.Queue).Count }
        if ($bewaard -gt 0) { $gemeld = $true }
    }
    if ($aan) {
        Check 'aan  -> wel terugzetten'      ($hersteld -and -not $gemeld)
    } else {
        Check 'uit  -> niet terugzetten'     (-not $hersteld)
        Check 'uit  -> wel een logregel'     ($gemeld)
    }
}
''
'--- 4. laden van de instelling uit een bewaard bestand ---'
foreach ($v in @($true,$false)) {
    $script:RestoreQueue = -not $v
    $saved = [pscustomobject]@{ RestoreQueue = $v }
    if ($saved.RestoreQueue -ne $null) { $script:RestoreQueue = [bool]$saved.RestoreQueue }
    Check ("bewaarde waarde $v wordt overgenomen") ($script:RestoreQueue -eq $v)
}
# ontbrekende sleutel mag de standaard niet omgooien
$script:RestoreQueue = $false
$saved = [pscustomobject]@{ Crf = 23 }
if ($saved.RestoreQueue -ne $null) { $script:RestoreQueue = [bool]$saved.RestoreQueue }
Check 'ontbrekende sleutel laat standaard staan' ($script:RestoreQueue -eq $false)
''
"====> $ok goed, $bad fout"
