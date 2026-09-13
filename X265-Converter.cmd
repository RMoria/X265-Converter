@echo off
rem ===================================================================
rem  Starter voor X265-Converter.ps1  (dubbelklikken)
rem
rem  Dit venster hoort binnen een seconde weg te zijn: het script start
rem  zichzelf opnieuw als proces ZONDER console (-FromLauncher) en de
rem  instantie die hier draait sluit zich daarna direct af. Daarna staat
rem  er dus niets meer open.
rem
rem  Je kunt ook een map op dit bestand slepen; die wordt meteen als
rem  bronmap toegevoegd.
rem ===================================================================

setlocal EnableExtensions EnableDelayedExpansion

set "PS1=%~dp0X265-Converter.ps1"

if not exist "%PS1%" (
    echo.
    echo FOUT: X265-Converter.ps1 is niet gevonden naast dit bestand.
    echo Verwacht op: %PS1%
    echo.
    pause
    exit /b 1
)

set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PWSH%" set "PWSH=powershell.exe"

rem enkele aanhalingstekens verdubbelen voor PowerShell
set "SCRIPT=%PS1%"
set "SCRIPT=!SCRIPT:'=''!"

set "PSCMD=& '!SCRIPT!' -FromLauncher"

if not "%~1"=="" (
    set "DROP=%~1"
    set "DROP=!DROP:'=''!"
    set "PSCMD=& '!SCRIPT!' -FromLauncher -Path '!DROP!'"
)

rem Geen START: dit venster wacht bewust op PowerShell, maar die is na
rem het starten van de verborgen instantie meteen klaar.
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "!PSCMD!"

endlocal
exit /b 0
