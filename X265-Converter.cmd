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
rem
rem  Vanuit een ander script of programma:
rem      X265-Converter.cmd -In "D:\in\film.mkv" -Out "E:\uit\film.mkv"
rem  -Out is optioneel; zonder -Out wordt <naam>.x265.mkv naast de bron
rem  gezet. Draait er al een instantie, dan gaat het bestand daar
rem  achteraan de wachtrij en komt er geen tweede venster.
rem
rem  Bij het starten wordt gekeken of er een nieuwere uitgebrachte versie
rem  op GitHub staat. Overslaan kan met:
rem      X265-Converter.cmd -GeenUpdate
rem ===================================================================

rem ===================================================================
rem  STAP 0: een klaargezette nieuwe starter omwisselen
rem
rem  Dit is het allereerste wat er gebeurt, en het gebeurt door een los
rem  hulpje dat wacht tot dit venster weg is.
rem
rem  Waarom niet gewoon overschrijven: cmd.exe leest een batchbestand
rem  niet in een keer in. Het onthoudt een BYTEPOSITIE en leest na elke
rem  regel verder op die plek. Vervang je het bestand tijdens het
rem  draaien, dan leest cmd op de oude positie verder in de NIEUWE
rem  inhoud - en voert half afgekapte regels uit. Daarom: hulpje wacht,
rem  wij sluiten meteen af, pas daarna wordt er vervangen.
rem
rem  Alleen bij een start zonder argumenten. Met -In zou een opdracht
rem  verloren gaan bij de herstart; die wisselt de volgende keer wel om.
rem ===================================================================
if exist "%~dp0X265-Converter.cmd.nieuw" if "%~1"=="" (
    echo Nieuwe starter gevonden; omwisselen en opnieuw beginnen...
    > "%TEMP%\x265-wissel.cmd" echo @echo off
    >>"%TEMP%\x265-wissel.cmd" echo ping -n 3 127.0.0.1 ^>nul
    >>"%TEMP%\x265-wissel.cmd" echo move /y "%~dp0X265-Converter.cmd.nieuw" "%~f0" ^>nul
    >>"%TEMP%\x265-wissel.cmd" echo start "" "%~f0"
    >>"%TEMP%\x265-wissel.cmd" echo del "%%~f0"
    start "" /min "%TEMP%\x265-wissel.cmd"
    exit /b 0
)

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

rem ===================================================================
rem  Bijwerken naar de nieuwste uitgebrachte versie
rem
rem  Bijwerken.ps1 kijkt welke versietag er op GitHub staat en haalt die
rem  op als hij nieuwer is. Doet niets als er al een instantie draait, en
rem  niets als het niet lukt - geen netwerk, geen rechten. Bijwerken mag
rem  nooit in de weg zitten van gewoon kunnen starten.
rem ===================================================================
set "DOUPDATE=1"
if /i "%~1"=="-GeenUpdate" (
    set "DOUPDATE="
    shift
)
if defined DOUPDATE if exist "%~dp0Bijwerken.ps1" (
    "%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Bijwerken.ps1"
)

rem enkele aanhalingstekens verdubbelen voor PowerShell
set "SCRIPT=%PS1%"
set "SCRIPT=!SCRIPT:'=''!"

set "PSCMD=& '!SCRIPT!' -FromLauncher"

rem Aanroep vanuit een ander programma: -In <pad> [-Out <pad>]
if /i "%~1"=="-In" (
    if "%~2"=="" (
        echo.
        echo FOUT: -In is opgegeven zonder pad.
        echo Gebruik: %~nx0 -In "D:\in\film.mkv" [-Out "E:\uit\film.mkv"]
        echo.
        exit /b 1
    )
    set "INFILE=%~2"
    set "INFILE=!INFILE:'=''!"
    set "PSCMD=& '!SCRIPT!' -FromLauncher -In '!INFILE!'"
    if /i "%~3"=="-Out" (
        set "OUTFILE=%~4"
        set "OUTFILE=!OUTFILE:'=''!"
        set "PSCMD=& '!SCRIPT!' -FromLauncher -In '!INFILE!' -Out '!OUTFILE!'"
    )
) else if not "%~1"=="" (
    set "DROP=%~1"
    set "DROP=!DROP:'=''!"
    set "PSCMD=& '!SCRIPT!' -FromLauncher -Path '!DROP!'"
)

rem Geen START: dit venster wacht bewust op PowerShell, maar die is na
rem het starten van de verborgen instantie meteen klaar.
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "!PSCMD!"

endlocal
exit /b 0
