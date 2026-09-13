# X265 Converter

Video naar H.265 / HEVC omzetten op Windows, met een grafische interface.
Eén PowerShell-script plus een starter; verder alleen ffmpeg.

**Versie 1.2** — [wat er per versie is veranderd](LEESMIJ-X265-Converter.md#wat-er-per-versie-is-veranderd)

![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-blue)
![Windows](https://img.shields.io/badge/Windows-10%20%2F%2011-blue)

## Wat het doet

Bronmappen kiezen (ook UNC-paden), scannen met `ffprobe`, en de gevonden
video's één voor één omzetten naar H.265. Met een herschikbare wachtrij,
pauze en hervatten, stoppen (direct of na het huidige bestand), live
statistieken en een tijdsindicatie die meebeweegt met elke wijziging van
de wachtrij.

Bestanden die al HEVC zijn worden overgeslagen. Het origineel gaat pas weg
als de verplaatsing van het nieuwe bestand is gelukt.

Een paar dingen die minder vanzelfsprekend zijn en waar het meeste werk in
is gaan zitten:

- **De container wordt nagemeten.** Na de encode wordt op acht punten
  gekeken of het geluid daar bij het beeld ligt. Zo niet, dan wordt de
  container opnieuw opgebouwd. Dit was de oplossing voor geluid en
  ondertitels die halverwege het afspelen wegvielen.
- **Het geluid wordt vergeleken met de bron**, niet met een vaste drempel.
  Een tekort van een paar seconden aan het eind is doodnormaal; pas als de
  uitvoer het duidelijk slechter doet dan het origineel is er iets mis.
- **Sporen worden vooraf uitgezocht.** Timecode- en datastromen kan MKV
  niet opslaan, mov_text-ondertitels moeten naar srt, en een
  omslagafbeelding hoeft niet door de encoder.
- **Een bron op een netwerklocatie wordt eerst lokaal gezet.** ffmpeg leest
  tijdens het encoderen heen en weer door het bestand; zonder die kopie
  staat er urenlang verkeer op de share. Er wordt er één tegelijk vooruit
  gehaald, overlappend met de lopende encode.
- **Geen beheerdersrechten nodig**, ook niet op een dichtgezette machine.

## Installeren

1. Zet de bestanden in een map, bijvoorbeeld `C:\Tools\2-265`.
2. Haal ffmpeg op ([gyan.dev](https://www.gyan.dev/ffmpeg/builds/) of
   [BtbN](https://github.com/BtbN/FFmpeg-Builds/releases)) en zet
   `ffmpeg.exe` en `ffprobe.exe` in `ffmpeg\bin\` naast het script.
   Staat ffmpeg in je `PATH`, dan werkt dat ook.
3. Dubbelklik **`X265-Converter.cmd`**.

Vanuit een ander script of programma kan er ook één bestand worden
aangeboden:

```
X265-Converter.cmd -In "D:\in\film.mkv" -Out "E:\uit\film.mkv"
```

`-Out` wordt letterlijk gebruikt — geen `.x265` erachter en geen `(2)`
erbij. Draait er al een instantie, dan komt het bestand daar achteraan de
wachtrij in plaats van in een tweede venster.

Getest met ffmpeg 9.0.1 en Windows PowerShell 5.1.

## Wat er in deze map staat

| | |
|---|---|
| `X265-Converter.ps1` | het programma |
| `X265-Converter.cmd` | de starter waar je op dubbelklikt |
| `LEESMIJ-X265-Converter.md` | de volledige handleiding |
| `tools/` | losse hulpscripts: één bestand doormeten, een map nakijken op geluidsgaten, VCP-markeringen weghalen |
| `src/` | de acht onderdelen waaruit het script wordt samengesteld |
| `build/` | samenstellen en controleren |
| `tests/` | de tests |

`X265-Converter.ps1` wordt **samengesteld** uit `src/part1..part8.ps1`
met `build/assemble.sh`. Pas dus de onderdelen aan en niet het
samengestelde bestand, anders is je wijziging bij de volgende build weg.

Gebruik je het alleen als programma, dan kun je `src/`, `build/` en
`tests/` gerust weggooien; `X265-Converter.ps1` staat op zichzelf.

## Tests

De tests draaien op PowerShell 7 met ffmpeg op het `PATH`, en maken hun
eigen testbestanden aan met `lavfi`:

```bash
pwsh -NoProfile -File tests/test_final.ps1
```

De handleiding staat in [LEESMIJ-X265-Converter.md](LEESMIJ-X265-Converter.md).
