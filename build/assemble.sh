#!/bin/bash
# Stelt X265-Converter.ps1 samen uit src/part1..part8.ps1 en controleert
# het resultaat: PowerShell-syntaxis, geldige XAML, en of elke $ui.<naam>
# ook echt in de XAML voorkomt.
#
# Draaien vanuit de hoofdmap van de repository:   bash build/assemble.sh
set -e
cd "$(dirname "$0")/.."

PWSH="${PWSH:-pwsh}"
command -v "$PWSH" >/dev/null || { echo "pwsh niet gevonden; zet PWSH= naar het pad."; exit 1; }

python3 - <<'PY'
import io
parts = ['src/part%d.ps1' % i for i in range(1, 9)]
s = '\n'.join(io.open(x, encoding='utf-8').read().rstrip('\n') for x in parts) + '\n'
s = s.replace('\r\n', '\n').replace('\n', '\r\n')
# UTF-8 met BOM en CRLF: dat wil Windows PowerShell 5.1 zien
io.open('X265-Converter.ps1', 'w', encoding='utf-8-sig', newline='').write(s)
print(len(s.split('\r\n')), 'regels,', len(s), 'bytes')
PY

"$PWSH" -NoProfile -Command '
$e = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path "X265-Converter.ps1"), [ref]$null, [ref]$e)
if ($e.Count) { $e | Select-Object -First 5 | ForEach-Object { "SYNTAXFOUT regel {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message }; exit 1 }
"SYNTAX: ok"'

"$PWSH" -NoProfile -File build/check_xaml.ps1
