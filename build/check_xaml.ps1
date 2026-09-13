$text = Get-Content -Raw (Join-Path $PSScriptRoot '..\X265-Converter.ps1')
$m = [regex]::Match($text, "(?s)\[xml\]\`$xaml = @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { 'XAML NIET GEVONDEN'; exit 1 }
$x = $m.Groups[1].Value
Set-Content -Path (Join-Path $PSScriptRoot '..\ui.xaml') -Value $x -NoNewline
try {
  [xml]$d = $x
  'XAML IS GELDIGE XML'
  $pat = 'x:Name="([^"]+)"'
  $names = [regex]::Matches($x, $pat) | ForEach-Object { $_.Groups[1].Value }
  "aantal benoemde elementen: $($names.Count)"
  $dupes = $names | Group-Object | Where-Object { $_.Count -gt 1 }
  if ($dupes) { "DUBBELE NAMEN: $($dupes.Name -join ', ')" } else { 'geen dubbele namen' }
  # controleer of elke $ui.<naam> in het script bestaat in de XAML
  $used = [regex]::Matches($text, '\$ui\.([A-Za-z0-9_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
  $missing = $used | Where-Object { $names -notcontains $_ }
  if ($missing) { "ONTBREKEND IN XAML: $($missing -join ', ')" } else { 'alle $ui.<naam> verwijzingen bestaan' }
} catch { "XML FOUT: $($_.Exception.Message)" }
