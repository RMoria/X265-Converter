# Zoekt aanroepen naar functies die nergens zijn gedefinieerd.
# 'W' en 'Quote-Arg' horen in de uitslag: die staan in `$HelperText en
# worden pas binnen de worker-runspaces gedefinieerd.
$errors=$null;$tokens=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\X265-Converter.ps1'),[ref]$tokens,[ref]$errors)

$defined = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $true) |
           ForEach-Object { $_.Name }
'--- gedefinieerde functies ---'
$defined | Sort-Object -Unique

$cmds = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst]}, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique

'--- onbekende commando''s (niet gedefinieerd, niet beschikbaar) ---'
$unknown = @()
foreach ($c in $cmds) {
    if ($defined -contains $c) { continue }
    if (Get-Command $c -ErrorAction SilentlyContinue) { continue }
    $unknown += $c
}
if ($unknown) { $unknown } else { 'geen' }
