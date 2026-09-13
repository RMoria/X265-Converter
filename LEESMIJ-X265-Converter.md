# Video naar H.265 / HEVC — PowerShell GUI

**Versie 1.3 (14 september 2026)**

Het versienummer staat achter in de venstertitel (`… [v1.3]`), als eerste regel
in de log bij het opstarten, bovenaan `X265-Converter.error.log` en als `Version`
in het instellingenbestand. Bij een melding is dat het eerste wat je wilt weten.
Bijwerken gaat met `$AppVersion` en `$AppDate` bovenaan het script: tweede cijfer
erbij voor nieuw gedrag, derde cijfer voor een reparatie.

Opvolger van `convert.bat`. Eén PowerShell-script met een grafische interface.

## Wat er per versie is veranderd

### 1.3 — 14 september 2026

- **Twee computers kunnen op dezelfde map werken** zonder elkaar in de weg te
  zitten. Voordat er aan een bestand wordt begonnen legt de pc er een klein
  lock-bestandje naast; de ander ziet dat en gaat door naar het volgende.
  Zie *Twee computers op dezelfde map*.
- **De bron wordt vlak voor het oppakken nog een keer nagekeken.** Is hij
  inmiddels weg — omdat de andere pc hem net heeft omgezet — dan wordt de regel
  overgeslagen in plaats van als fout geteld.
- **Achtergebleven lock-bestanden worden bij het scannen opgeruimd**, zonder
  extra ronde over de share.
- **Vlak voor het wegschrijven wordt gecontroleerd of het lock nog van ons is.**
  Was deze pc lang in slaapstand en heeft de ander het bestand overgenomen, dan
  gaat het eigen resultaat de prullenbak in in plaats van over dat van de ander
  heen.

### 1.2 — 13 september 2026

- **Een bron op een netwerklocatie wordt eerst naar de werkmap gekopieerd.**
  ffmpeg leest een bestand tijdens het encoderen niet één keer netjes van voor
  naar achter, dus zonder die kopie staat er urenlang verkeer op de share en
  blijft de schijf aan de andere kant draaien. Er wordt er steeds maar één
  vooruit gehaald, en die kopie begint al terwijl het vorige bestand nog aan het
  encoderen is. Zie *De bron eerst lokaal zetten*.
- **Het script is nu vanaf de opdrachtregel te gebruiken**, met `-In` en `-Out`,
  zodat een ander script of programma er werk aan kan geven. Draait er al een
  instantie, dan komt het bestand daar achteraan de wachtrij in plaats van dat
  er een tweede venster opent. Zie *Aanroepen vanuit een ander programma*.
- **Het wachtrijnummer telt in vier cijfers** (`0001`, `0002`, …), zodat de
  kolom niet meer verspringt zodra je boven de negen of de negenennegentig komt.

### 1.1 — 12 september 2026

- **Vensterpositie blijft bewaard**, inclusief afmetingen en gemaximaliseerd.
  Ligt de bewaarde plek buiten het huidige beeld — tweede scherm uit, laptop van
  het dock — dan wordt het venster teruggeschoven in plaats van onzichtbaar op te
  starten.
- **KeepAwake wordt gestopt** zodra een conversierun afloopt, en altijd voordat
  het programma zichzelf eventueel afsluit.
- **Sporen worden vooraf uitgezocht in plaats van blind `-map 0`.** Dat repareert
  mp4's die afketsten op *"Nothing was written into output file"*: timecode- en
  datastromen gaan er nu uit, mov_text-ondertitels worden omgezet naar srt, en
  een omslagafbeelding wordt overgeslagen.
- **`Invalid argument` uit de lijst gehaald** die een herpoging blokkeert. Die
  tekst komt ook voor in *"Could not write header … Invalid argument"* — een
  probleem met de uitvoer — en zo werd juist de herpoging overgeslagen die het
  bestand had kunnen redden.
- **De wachtrij begint leeg bij het opstarten.** De bronmappen blijven wel
  bewaard, en een rescan is zo gebeurd. Terug te draaien met `RestoreQueue`.
- **Drie vinkjes weg** uit het instellingenpaneel: submappen meenemen,
  wijzigingsdatum overnemen en de slimme herpoging. Ze stonden altijd aan; het
  gedrag is ongewijzigd en ze staan nog wel in het instellingenbestand.

### 1.0 — 11 september 2026

- Versienummer ingevoerd, zichtbaar in de venstertitel, de log, het
  foutenlogboek en het instellingenbestand.
- **Geen beheerdersrechten meer nodig op een dichtgezette machine.** Padcontroles
  kunnen niet meer omvallen op "Toegang geweigerd", en werkmap, instellingen en
  logboek wijken uit naar een plek waar de gebruiker wél mag schrijven.
- **Verlies van geluid in verhouding afgehandeld**: tot 30 seconden wordt de
  staart opgevuld en het bestand behouden, daarboven pas afgekeurd als VCP.
- **De geluidscontrole vergelijkt met de bron** in plaats van met een vaste
  drempel — een tekort van een paar seconden aan het eind is doodnormaal.
- **De container wordt nagemeten** na de encode, en alleen opnieuw opgebouwd als
  het nodig is. Dit was de oplossing voor geluid en ondertitels die halverwege
  wegvielen.
- Hulpscripts: `Controleer-Geluid.ps1`, `Diagnose-Bestand.ps1` en
  `Herstel-VCP-namen.ps1`.

## Starten

Dubbelklik **`X265-Converter.cmd`** — de enige starter. Je kunt er ook een map
op slepen; die wordt meteen als bronmap toegevoegd.

Het `.vbs`-bestand is vervallen. Het cmd-venster hoort nu binnen een seconde
weg te zijn: het script start zichzelf opnieuw als proces **zonder console** en
de instantie die het venster bezet sluit zich direct daarna af.

> **Waarom het venster eerder bleef staan.** De vorige aanpak verborg het
> venster achteraf, met `-WindowStyle Hidden` en `ShowWindow`. Dat werkt niet
> als Windows Terminal de standaard terminal is: dat venster is niet van
> conhost en trekt zich van `ShowWindow` niets aan. Nu wordt er voor het proces
> dat blijft leven helemaal geen console meer aangemaakt — `CreateNoWindow` op
> een verse `ProcessStartInfo`. Er is dus geen venster meer om te verbergen.

## Aanroepen vanuit een ander programma

Eén bestand aanbieden gaat met `-In` en, optioneel, `-Out`:

```
X265-Converter.cmd -In "D:\in\film.mkv" -Out "E:\uit\film.mkv"
```

Of rechtstreeks op het script:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "C:\Tools\2-265\X265-Converter.ps1" -In "D:\in\film.mkv" -Out "E:\uit\film.mkv"
```

**`-Out` wordt letterlijk gebruikt.** Er komt geen `.x265` achter en geen `(2)`
erbij als het pad al bestaat — wie het pad zelf opgeeft krijgt precies dat pad,
bestaande naam of niet. Ontbreekt de map, dan wordt die aangemaakt. Laat je
`-Out` weg, dan gedraagt het zich als altijd: `<naam>.x265.mkv` naast de bron.

**Draait er al een instantie, dan komt er geen tweede venster.** Het bestand
gaat achteraan de wachtrij van het venster dat al openstaat, en de aanroep is
meteen klaar — hij wacht dus niet tot de conversie gedaan is. Roep je tien keer
achter elkaar aan, dan staan er tien regels in de wachtrij en wordt er één
tegelijk verwerkt. Staat er niets in de wachtrij, dan begint de conversie
vanzelf; je hoeft niet op **Start** te klikken.

> **Hoe dat werkt.** Een named mutex (`Local\X265Converter.SingleInstance`)
> bepaalt wie de eerste is. De tweede aanroep schrijft een klein json-bestandje
> in `opdrachten\` naast de instellingen en sluit zichzelf af; de draaiende
> instantie kijkt die map elke twee seconden na. Bewust een mutex en geen
> lock-bestand: een mutex verdwijnt vanzelf als het proces stopt, ook bij een
> crash. Een lock-bestand zou na een harde afsluiting blijven staan en het
> programma onstartbaar maken.
>
> Het json-bestandje wordt eerst als `.tmp` weggeschreven en daarna hernoemd,
> zodat de andere instantie nooit een half geschreven opdracht oppakt. Ook een
> onleesbare opdracht wordt weggegooid — anders komt hij elke ronde opnieuw
> langs.

Wat er wordt overgeslagen, met een regel in de log: een bestand dat niet bestaat
of niet leesbaar is, een bestand zonder bruikbare videostream, en een bestand dat
al HEVC is. Het uitzoekwerk (`ffprobe`) gebeurt in de achtergrondthread, zodat
een trage share het venster niet laat vastlopen.

Kan de mutex niet worden aangemaakt — dat kan op een streng dichtgezette machine
— dan start het programma gewoon als eerste instantie. Twee vensters is minder
erg dan een programma dat niet opstart.

## Twee computers op dezelfde map

Laat je twee pc's op dezelfde (net)werkmap los, dan moeten ze niet allebei aan
hetzelfde bestand beginnen. Dat regelt het programma zelf: voordat er aan een
bestand wordt begonnen komt er een klein tekstbestandje naast te staan.

```
One Piece\
    aflevering 12.mkv
    aflevering 12.mkv.x265lock      <- zolang die pc ermee bezig is
```

Je kunt het in Kladblok openen en zien wie ermee bezig is:

```
pc=ACERROB
pid=12345
gebruiker=rob
bestand=aflevering 12.mkv
laatst=2026-09-14T20:09:11Z
versie=X265 Converter 1.3 (2026-09-14)
```

Komt de tweede pc bij dat bestand, dan ziet hij het lock, zet de regel op
**Andere pc bezig** en gaat meteen door naar het volgende vrije bestand. Aan het
eind van de rit wordt er nog **één keer** langs de overgeslagen bestanden
gelopen — de andere pc kan inmiddels gestopt zijn. Blijft het dan nog bezet, dan
laat hij het erbij; blijven wachten heeft geen zin, want een bestand dat de ander
wél afmaakt komt niet meer terug (het origineel is dan weg).

Er wordt ook vlak voor het oppakken nog gekeken of de bron er überhaupt nog is.
De lijst is een momentopname van de scan, en op een gedeelde map kan die binnen
een uur achterlopen.

### Waarom geen gedeeld lijstje

Het lijkt handiger om één `bezig.txt` in de map te leggen en daar regels aan toe
te voegen. Dat is precies het onderdeel dat niet veilig is: twee pc's lezen dat
lijstje, vullen het allebei aan en schrijven het allebei terug — en dan is een
van de twee regels weg. Er zit een moment tussen lezen en schrijven waarin de
ander ertussen kan komen, en over SMB is dat moment lang genoeg om het echt te
laten misgaan.

Een lock-bestand per video heeft dat gat niet. Het wordt aangemaakt met
*"alleen als het nog niet bestaat"* (`FileMode::CreateNew`), en dat is aan de
serverkant één handeling die of lukt of faalt. In de CIFS/SMB-specificatie staat
het letterlijk: als er al een bestand met die naam is, *"the command MUST fail"*.

Het lock staat naast de bron en niet in een centrale lijst, omdat dezelfde map
op de ene pc `\\10.0.0.242\g\One Piece` heet en op de andere misschien
`G:\One Piece` of gewoon `C:\g\One Piece`. Een centrale lijst op pad zou die
drie als drie verschillende dingen zien.

### Als er een pc uitvalt

Blijft er een lock liggen van een pc die is afgesloten, gecrasht of van het
netwerk is gevallen, dan komt het bestand vanzelf weer vrij. Er zijn twee sloten
op de deur, en ze vullen elkaar aan:

1. **Het lock-bestand blijft openstaan** zolang de conversie loopt. Op Windows
   kan een andere pc het dan niet hernoemen of weggooien — ook niet als hij
   denkt dat het lock oud is. Sluit de pc af of crasht hij, dan sluit Windows
   dat bestand en is het slot weg.
2. **De eigenaar werkt zijn lock elke minuut bij.** Blijft dat een kwartier uit,
   dan geldt het lock als verweesd en mag een ander het overnemen.

> **Het kwartier is geen maximum voor de conversie.** Het is hoe lang een pc
> *stil* mag zijn. Een trage pc die acht uur over een groot bestand doet houdt
> zijn lock die hele acht uur vast, want hij laat elke minuut van zich horen —
> ook tijdens het encoderen, het remuxen, het opvullen, het kopiëren van en naar
> de share, en tijdens een pauze. Die hartslag zit daarom op één plek
> (`Update-Timers`) waar al die lussen langskomen, en niet in elke lus apart:
> zo kan er geen lus zijn die hem vergeet.

### Als het lock toch wordt afgepakt

Blijft een pc écht een kwartier stil — slaapstand, netwerk weg — dan neemt de
ander het bestand over. Wordt de eerste pc daarna wakker en maakt hij zijn
conversie af, dan zou hij zijn resultaat over dat van de ander heen zetten.

Dat gebeurt niet. Vlak voordat het omgezette bestand naar de bronmap gaat wordt
gecontroleerd of het lock nog van ons is. Is dat niet zo, dan wordt het eigen
resultaat **weggegooid** en blijft het origineel ongemoeid — de ander is er
immers al mee bezig of al klaar. De regel krijgt status **Lock kwijt** en telt
niet mee voor de noodstop: er is niets mis met het bestand.

Is het lock-bestand alleen maar *verdwenen* zonder dat iemand het heeft
overgenomen — een hik van de share, een opruimactie — dan wordt het gewoon
opnieuw geplaatst en loopt de conversie door. Er wordt geen uren rekenwerk
weggegooid op grond van een twijfelgeval.

Het overnemen zelf gebeurt met een **hernoeming** en niet met een verwijdering.
Hernoemen kan maar één keer slagen, dus twee pc's die tegelijk tot de conclusie
komen dat een lock oud is kunnen niet allebei doorlopen — en ze kunnen elkaars
zojuist aangemaakte verse lock ook niet per ongeluk weggooien.

> **Klokken.** Het kwartier wordt gemeten met de klok van de pc die kijkt. Loopt
> die meer dan een kwartier vóór op de andere, dan zou hij een levend lock voor
> verweesd kunnen aanzien. Punt 1 hierboven vangt dat op Windows alsnog af, maar
> het is geen kwaad om de tijd op beide machines gewoon te laten synchroniseren.

### Instellingen

| Sleutel | Standaard | Betekenis |
| --- | --- | --- |
| `SharedLocks` | `true` | Lock-bestanden plaatsen. Op `false` als er maar één pc draait |
| `LockStaleMinutes` | `15` | Na hoeveel minuten stilte een lock als verweesd geldt (minimaal 2) |

Achtergebleven lock-bestanden waarvan de bron niet meer bestaat worden bij het
scannen opgeruimd. Dat kost geen extra ronde over de share: ze komen in dezelfde
opsomming voorbij. Een lock waarvan de bron er nog wél is blijft staan — die kan
van een pc zijn die op dit moment aan het werk is.

## De bron eerst lokaal zetten

Staat de bron op een netwerklocatie, dan wordt het bestand eerst naar de werkmap
gekopieerd en leest `ffmpeg` van die kopie.

Dat is niet voor de snelheid. `ffmpeg` leest een bestand tijdens het encoderen
niet één keer netjes van voor naar achter: het springt heen en weer en leest
stukken opnieuw. Bij een bestand van een paar GB betekent dat urenlang verkeer
over de share en een schijf die aan de andere kant blijft draaien. Eén keer
doorkopiëren is aan beide kanten rustiger.

- **Eén tegelijk vooruit.** Niet de hele wachtrij, alleen het eerstvolgende
  bestand. De werkmap loopt dus nooit vol met kopieën.
- **Overlappend.** De kopie van het volgende bestand begint al terwijl het
  vorige nog aan het encoderen is, zodat de encoder er niet op hoeft te wachten.
- **Opruimen gebeurt in alle gevallen.** Geslaagd, mislukt, afgebroken of
  afsluiten: de map `x265_pre_<id>` gaat weg. Wordt de wachtrij onderweg
  veranderd, zodat het vooruit gehaalde bestand niet meer aan de beurt is, dan
  wordt die kopie weggegooid en meldt de log dat.
- **Ruimtecontrole vooraf.** Is er minder vrij dan twee keer het bestand plus
  2 GB, dan wordt er niet gekopieerd en leest `ffmpeg` gewoon van de share.
  Datzelfde gebeurt als de kopie halverwege misgaat of de grootte niet klopt.

Twee instellingen sturen dit (in `X265-Converter.settings.json`):

| Sleutel | Standaard | Betekenis |
| --- | --- | --- |
| `PrefetchToWorkDir` | `true` | Bron eerst naar de werkmap kopiëren |
| `PrefetchOnlyNetwork` | `true` | Alleen doen bij een UNC-pad of een netwerkschijf |

Zet `PrefetchOnlyNetwork` op `false` als je ook een langzame lokale schijf of een
USB-disk zo wilt behandelen. Zet `PrefetchToWorkDir` op `false` om het helemaal
uit te zetten.

Tijdens het kopiëren staat er **Bron lokaal zetten** bij de voortgang, met het
percentage. Onder aan de rit blijft er niets van de kopie staan; **Werkmap
opruimen** in het instellingenpaneel veegt ook eventuele `x265_pre_`-mappen weg
die van een harde afsluiting zijn overgebleven.

## Wat er gebeurt

1. **Scannen** — de bronmappen worden doorlopen (recursief als dat aanstaat).
   Alleen bestanden met een video-extensie gaan naar `ffprobe`; daaruit komen
   codec en speelduur. Resultaten komen onderaan de lijst.
2. **Start conversie** — alles wat is aangevinkt gaat achteraan de wachtrij en
   de encoder begint. Per bestand:
   - `ffmpeg` encodeert naar de werkmap
   - het eindbestand gaat naar de bronmap
   - ondertitels krijgen de nieuwe naam
   - **pas na een geslaagde verplaatsing** wordt het origineel verwijderd
     (10 pogingen, 10 s ertussen)

Naamgeving: `h264` / `h.264` / `h 264` / `x264` en `avc` verdwijnen uit de naam,
het resultaat wordt `<naam>.x265.mkv`. Bestaat die naam al, dan komt er `(2)`,
`(3)` … achter in plaats van overschrijven.

## De wachtrij

De wachtrij is het hart van het programma en tegelijk de lijst die je ziet:
regels die in de wachtrij staan staan bovenaan, in de volgorde waarin ze gedaan
worden, met hun **positie in vier cijfers** (`0001`, `0017`) in de kolom `Nr`.

- **De encoder pakt altijd de bovenste.** Er is geen vaste index: de werk-thread
  haalt de bovenste regel van de lijst en werkt die af. Daardoor kun je de rest
  van de rij vrij herschikken terwijl er wordt geëncodeerd, zonder dat er iets
  kan worden overgeslagen of dubbel gedaan. Het bestand dat onder handen is
  staat niet meer in de rij.
- **Naar boven / Naar onderen** verplaatst één regel of een hele selectie; bij
  een meervoudige selectie blijft de onderlinge volgorde behouden.
- **Wat erbij komt gaat achteraan.** Nieuwe scanresultaten, en ook regels die je
  eerder uitvinkte en weer aanvinkt. Wie eruit gaat en terugkomt sluit achteraan
  aan.
- **Er wordt altijd meteen hernummerd** — bij herschikken, bij aan- en
  uitvinken, bij een bestand dat klaar is, en bij een regel die je uit de lijst
  haalt. Geen gaten in de reeks.
- **"Resterend" en "Klaar omstreeks" bewegen direct mee.** De nog te doen tijd
  is de rest van het huidige bestand plus de hele wachtrij, en die wordt elke
  slag opnieuw opgeteld. De rekenfactor voor de schatting blijft op zijn eigen
  ritme: het eerste halfuur elke 30 seconden, daarna elke 2 minuten.

Een bestand dat **geslaagd** is verdwijnt uit de lijst; het resultaat blijft in
de Log staan. **Mislukt** en **Let op** blijven staan met het vinkje eraf, zodat
je ze ziet en desgewenst opnieuw kunt aanzetten.

## Bij het opstarten begint de lijst leeg

Standaard wordt de wachtrij **niet** bewaard over een herstart heen. Start je het
programma opnieuw, dan is de lijst leeg en komt een nieuwe scan niet bij de resten
van de vorige keer te staan.

Wat wél bewaard blijft in `X265-Converter.settings.json` naast het script: de
instellingen, de bronmappen en de cumulatieve totalen. Er wordt atomisch
geschreven (eerst een `.tmp`, dan vervangen) en er is precies één schrijver, dus
het bestand kan niet half beschreven raken.

### Wil je de wachtrij wel bewaren

Zet `RestoreQueue` op `true` in het instellingenbestand. Dan komen lijst en
volgorde terug bij het opstarten, inclusief het bestand dat bij het afsluiten
onder handen was — dat komt weer vooraan te staan.

In dat geval wordt er bij het opstarten in de achtergrond nagelopen of de
bestanden er nog staan. Diezelfde ronde haalt grootte, speelduur en codec opnieuw
op: een automatische herscan van alleen de regels in de lijst. Dat gebeurt bewust
in de achtergrond, want een UNC-pad naar een server die uit staat kost seconden
per bestand en het venster mag daar niet op vastlopen.

- Niet aanwezig of niet benaderbaar → de regel blijft staan met status
  **"Niet gevonden"**, het vinkje gaat eraf, en je krijgt een melding.
- Inmiddels al HEVC → de regel gaat uit de wachtrij en is niet meer aanvinkbaar.
- Er wordt **niet** automatisch begonnen met converteren; jij drukt op Start.

Met `RestoreQueue` uit wordt de wachtrij ook niet meer naar het instellingen-
bestand geschreven. Dat scheelt fors: met een volle lijst liep dat bestand op tot
honderden kilobytes, zonder is het een paar regels.

Een oud of beschadigd instellingenbestand levert nooit een crash op: dan wordt er
met een lege lijst gestart, met een melding in de log.

## Tijdens het encoderen

Scannen en converteren lopen los van elkaar. Map toevoegen, op **1. Scannen**,
de conversie gaat ongestoord door, de nieuwe bestanden komen onderaan de lijst,
en de knop heet dan **2. Toevoegen aan wachtrij**.

| Knop | Gedrag |
|---|---|
| **Pauze / Hervatten** | bevriest het ffmpeg-proces zelf (`NtSuspendProcess`); de rekentijd loopt niet door |
| **Stop na huidige** | schakelaar: maakt het lopende bestand af en start daarna niets meer. Nog een keer klikken **trekt het weer in** en de conversie gaat verder met de bovenste uit de wachtrij |
| **Stop direct** | breekt ffmpeg af, ruimt het tijdelijke bestand op; de rest van de wachtrij blijft staan |
| **Scan stoppen** | de scanknop tijdens een scan; raakt de conversie niet |

Na elke stop staat wat niet is uitgevoerd nog in de wachtrij: één keer **Start**
en het gaat verder waar het gebleven was.

## Noodstop na drie fouten op rij

Gaat het **drie keer achter elkaar** fout, dan stopt de run zichzelf. Dan is er
meestal iets structureel mis — een share die read-only is geworden, een volle
schijf, een werkmap die niet beschikbaar is — en heeft doorploegen geen zin.

- Als "fout" telt **elke uitkomst die geen volledig succes is**: `Mislukt`, maar
  ook `Let op` (het x265-bestand staat er, maar het origineel kan niet weg — het
  klassieke read-only-symptoom), en elk bestand dat op het moment van verwerken
  niet blijkt te bestaan.
- Alleen een geslaagde conversie zet de teller terug op nul. Eén kapot bestand
  tussen goede bestanden stopt de run dus niet.
- Niet meegeteld: wat jij zelf veroorzaakt (Stop direct, Stop na huidige, een
  regel uit de wachtrij halen), al-HEVC-bestanden, en een mislukte
  ondertitel-actie.
- De rest van de wachtrij blijft staan. Los de oorzaak op en druk op Start.
- **Bij een noodstop sluit het programma zich nooit af**, ook niet als
  "Programma afsluiten na conversie stop" aanstaat — juist dan moet je kunnen
  zien wat er aan de hand is.

Het aantal (drie) staat als `MaxFailStreak` in het instellingenbestand.

## Geluid: waarom het soms halverwege wegviel

Tot nu toe ging het geluid er ongewijzigd door met `-c:a copy`, **inclusief de
tijdstempels uit het origineel**. Zit daar een gat of een sprong in — bij rips
en downloads niet ongebruikelijk — dan neemt de MKV die sprong over, en veel
spelers laten de audiotrack op dat punt vallen en pakken die niet meer op. Het
beeld liep gewoon door, want dat werd volledig opnieuw opgebouwd. Vandaar het
patroon: beeld goed, geluid na een tijdje stil.

> **Extra ankers zouden hier niets hebben opgelost.** Keyframes ("ankers")
> zitten in de video en bepalen hoe nauwkeurig je kunt doorspoelen. Een
> audiostream heeft ze niet nodig — elk audioframe is al een sync-punt. Meer
> keyframes maakt het bestand alleen groter.

Daarom is er nu een instelling **Geluid**:

| Keuze | Wat het doet |
|---|---|
| **Kopieren** | het oude gedrag: snelst, maar neemt de tijdstempels van het origineel over |
| **AAC** *(standaard)* | opnieuw encoderen; bitrate volgt het aantal kanalen (2.0 → 192k, 5.1 → 384k, 7.1 → 512k) |
| **AC3** | voor een TV of receiver die AAC-meerkanaals niet lust; 5.1 → 448k, meer dan 5.1 wordt gedownmixt |
| **FLAC** | verliesvrij, dus geen tweede generatie kwaliteitsverlies, maar aanzienlijk grotere bestanden |

Bij elke vorm van opnieuw encoderen komt er `aresample=async=1:first_pts=0` bij,
en dat is het eigenlijke werk:

- **`async=1`** — *filling and trimming*. Een gat in de bron wordt met stilte
  opgevuld en een overlap weggeknipt, in plaats van dat de sprong in de
  tijdstempels wordt doorgegeven.
- **`first_pts=0`** — de nieuwe track begint op nul. Begint het geluid in de
  bron later dan het beeld, dan wordt dat verschil met stilte opgevuld, zodat de
  **sync behouden blijft** en niet meer afhangt van een offset in de container
  die sommige spelers negeren.

Kosten: verwaarloosbaar. Audio-encoderen is niets naast x265. Bij AAC en AC3 is
er wel een tweede generatie lossy compressie; wil je dat niet, kies dan FLAC.

**Waarschuwingen van ffmpeg komen nu in de log.** Het loglevel stond op `error`,
en dat is nu `warning`. Juist de waarschuwingen zijn hier interessant:
`Non-monotonous DTS` en `Delay between the first packet and last packet in the
muxing queue` zijn precies de meldingen die bij dit soort geluidsuitval horen.
Die werden eerder weggegooid. Komt de melding over de *muxing queue* voorbij,
dan is `-max_interleave_delta 0` de volgende stap; die vlag staat er bewust nog
niet in, omdat hij de rem van de muxwachtrij haalt en dan zelf kan afbreken op
"Too many packets buffered".

## Al omgezette bestanden nakijken en repareren

`Controleer-Geluid.ps1` zoekt naar twee verschillende gebreken, die beide door
het oude `-c:a copy` konden ontstaan. Ze lijken op elkaar als je kijkt, maar het
zijn niet dezelfde en er is er maar een van te repareren.

| | Wat er aan de hand is | Te repareren? |
|---|---|---|
| **AUDIO STOPT** | de audiotrack houdt halverwege op en komt niet terug; de video loopt door | **nee** — die pakketten staan niet meer in het bestand. Opnieuw omzetten vanaf het origineel is de enige weg |
| **GAT** / **SPRONG** | de pakketten zijn er wel, maar hun tijdstempels maken een sprong; spelers laten de track daar vallen | **ja** — zonder de video opnieuw te encoderen |

### Twee rondes, want ze kosten niet hetzelfde

**De snelle ronde** (standaard) kijkt of het geluid het einde van de film haalt.
Er wordt naar de staart van het bestand gesprongen en daar een venster van 20
seconden gelezen — grofweg 1 tot 3 MB per bestand in plaats van de hele film.
Duizend bestanden is dus minuten.

```powershell
.\Controleer-Geluid.ps1 -Path 'D:\Films'
```

**De volledige ronde** (`-Volledig`) loopt alle audiopakketten langs en vindt ook
gaten en sprongen midden in het bestand. Daarvoor moet ffprobe het bestand wel
volledig demuxen, en dat kost dus de hele bestandsgrootte aan leesverkeer.

```powershell
.\Controleer-Geluid.ps1 -Path 'D:\Films' -Volledig -Herstel
```

`-Herstel` doet in de snelle ronde niets, en dat wordt ook gemeld: wat die ronde
vindt is niet met een remux op te lossen.

### Waar de tijd in gaat

Nagemeten met `strace`, op hetzelfde bestand:

| aanpak | gelezen | ziet |
|---|---|---|
| alleen de kop (duur, streams) | 7% | niets over het verloop |
| staartvenster, snelle ronde | **4%** | of het geluid het einde haalt |
| hetzelfde, maar met `-select_streams` | 103% | idem — de optie blokkeert de seek |
| steekproef met `-read_intervals` over het geheel | 66% | deels |
| volledige probe | 105% | alles |

Die derde regel is een valkuil: `-select_streams a:0` lijkt zuiniger omdat je maar
een spoor opvraagt, maar ffprobe negeert daarmee de seek en leest het bestand
alsnog helemaal. Daarom komen in de snelle ronde alle pakketten binnen met hun
stream-index ervoor en wordt er in het script op index gefilterd.

### Het naamfilter

Standaard: **de basisnaam eindigt op `.x265`** (of `.x265 (2)` bij een
naamsbotsing) — precies zoals de converter zijn uitvoer noemt, en niets anders.
Dat is in twee stappen scherp geworden:

| filter | resultaat |
|---|---|
| `*x265*` | pakte ook `...1080p.x265-ELiTE.mkv` en `HEVC x265 BONE` — de helft van een eerste ronde ging naar bestanden die de converter nooit zag |
| `*.x265.*` | beter, maar `...6CH.x265.HEVC-PSA.mkv` glipt erdoor: `.x265.` staat daar middenin |
| eindigt op `.x265` | alleen echte eigen uitvoer |

Zelf een patroon meegeven kan met `-Patroon '*iets*'`; dat wordt dan als wildcard
op de bestandsnaam gebruikt. `-Alles` zet het filter helemaal uit.

### Het rapport

Na elk bestand gaat er een regel naar `Controleer-Geluid.rapport.csv`
(puntkomma's, opent zo in Excel): pad, grootte, speelduur, audiocodec, kanalen,
tot hoever het geluid komt, het tekort, het grootste gat en waar, de sprong
terug, het oordeel en wat er eventueel is hersteld.

**Ctrl-C mag dus altijd.** Bij een volgende ronde worden de bestanden die al in
het rapport staan overgeslagen. Een rapport van een oudere versie wordt herkend
en apart gezet als `.oud`, want die uitkomsten misten de controle op "audio
stopt".

### Schijfruimte bij herstellen

**Een gelukt herstel laat geen `*.origineel.*` achter.** Tijdens het omwisselen
staat het bestand kort twee keer op de schijf; zodra de nieuwe versie is nagemeten
gaat de oude weg. Er is dus alleen tijdelijk ruimte nodig ter grootte van het
grootste bestand.

- **Per bestand wordt de vrije ruimte gecontroleerd.** Past het niet binnen de
  marge (`-MinVrijGB`, standaard 5 GB), dan wordt dat bestand overgeslagen met
  een melding in het rapport. Er wordt nooit half geschreven.
- **`-BewaarOrigineel`** zet de oude versie wel apart, voor wie eerst wil
  vergelijken.
- Lukt het verwijderen van de oude versie niet, dan is het herstel nog steeds
  goed — het nieuwe bestand staat onder de juiste naam — maar je krijgt een
  melding.

Het omwisselen kan niet halverwege blijven hangen: mislukt het terugzetten van de
nieuwe versie, dan wordt de naamswijziging teruggedraaid en staat het origineel
weer onder zijn eigen naam, byte voor byte onaangeroerd.

### Overige schakelaars

- `-EindDrempel 5` — hoeveel seconden het geluid mag achterblijven op de
  speelduur voordat het "AUDIO STOPT" heet
- `-Staart 20` — hoe groot het staartvenster van de snelle ronde is
- `-Drempel 0.5` — vanaf welk gat of welke sprong een bestand verdacht is
- `-Patroon '*iets*'` — eigen naamfilter in plaats van de vaste regel
- `-Max 25` — proefronde
- `-Codec ac3` of `-Codec flac` — in plaats van AAC bij herstel
- `-Path` neemt meerdere mappen, losse bestanden en UNC-paden
- `-Recursief:$false` — alleen de map zelf
- `-Rapport 'D:\ergens\anders.csv'` — ander rapportpad
- `-MinVrijGB 20` — grotere veiligheidsmarge op de doelschijf
- `-BewaarOrigineel` — de oude versie apart houden in plaats van weggooien
- `-Opnieuw` — het rapport negeren en opnieuw beginnen
- `-Ja` — niet om bevestiging vragen

## De container: waarom geluid en ondertitels wegvielen

Dit was de echte oorzaak van "halverwege vallen het geluid en de ondertitels weg
terwijl het beeld doorloopt, en doorspoelen lokt het uit". Niet de audio, maar de
**interleaving** van de MKV: de sporen stonden niet netjes door elkaar in het
bestand, en een speler die lineair leest kan ze verderop dan niet meer vinden.

De ffmpeg-documentatie over `max_interleave_delta`:

> "To ensure all the streams are interleaved correctly, libavformat will wait
> until it has at least one packet for each stream before actually writing any
> packets. When some streams are 'sparse' (i.e. there are large gaps between
> successive packets), this can result in excessive buffering. \[Deze waarde\]
> specifies the maximum difference between the timestamps of the first and the
> last packet in the muxing queue, **above which libavformat will output a packet
> regardless of whether it has queued a packet for all the streams**."

Standaard 10 seconden. Een ondertitelspoor is bij uitstek zo'n dun bezette stream
— minuten tussen twee regels. Dan schrijft de muxer het beeld weg zonder op
geluid en ondertitels te wachten.

**De encode zet nu zelf `-max_interleave_delta 0`.** Daarmee hoort de container
meteen goed te zijn en hoort een extra ronde overbodig te zijn.

### Meten in plaats van aannemen

"Hoort" is daar het sleutelwoord. Dat de vlag alleen genoeg is, is niet bewezen:
het defect liet zich buiten de echte bestanden niet namaken. Een deel van de
verklaring is de ffmpeg-versie — de metingen hier gebeurden op 6.1.1, de
werkelijke conversies op 9.0.1, drie hoofdversies verschil in precies die muxer.

Daarom wordt er na de encode **nagemeten** in plaats van aangenomen:

1. Op acht punten in het nieuwe bestand wordt gesprongen en gekeken of daar
   audiopakketten liggen die bij het beeld op diezelfde plek horen. Dat is wat
   een speler doet. Kosten: seeks, geen leesronde — een fractie van een seconde
   op een bestand dat net is geschreven en nog in de cache staat.
2. Ligt alles goed, dan gebeurt er niets extra's. Dat is de normale gang van
   zaken en dat staat ook zo in de log.
3. Ligt het niet goed, dan volgt alsnog de remux — de ingreep die aantoonbaaar
   wel werkt: alle bestaande bestanden zijn daarmee gerepareerd. Daarna wordt er
   opnieuw gemeten, en blijft het dan mis, dan komt dat met nadruk in de log.

Twee details van de meting die makkelijk verkeerd gaan, met een waarschuwing
erbij in de code zodat niemand ze later "opruimt":

- **Vergelijk geluid met beeld, niet met het gevraagde tijdstip.** Een seek landt
  altijd op het keyframe vóór dat punt, dus komen beeld en geluid samen een paar
  seconden eerder terug. Dat is normaal; vergelijken met de vraag geeft overal
  valse alarmen.
- **`-select_streams` mag er niet bij.** Die optie lijkt zuiniger omdat je maar
  één spoor opvraagt, maar ffprobe negeert daarmee de seek en leest het hele
  bestand alsnog — nagemeten 13,4 MB tegen 0,6 MB.

### De remux

Een remux is `-c copy` met `-max_interleave_delta 0`: de container wordt in één
keer opnieuw opgebouwd, beeld en geluid worden letterlijk gekopieerd. Nagemeten
op een testbestand zijn de video-md5 en audio-md5 identiek voor en na, en kostte
het 280 ms voor 2 MB.

Voordat een remux wordt geaccepteerd, wordt gecontroleerd dat er even veel sporen
zijn als ervoor en dat de speelduur binnen een seconde gelijk is. Klopt dat niet,
of mislukt de remux, dan wordt het bestand van de encode gebruikt met een melding
— een mislukte extra stap is geen reden om een geslaagde encode weg te gooien.

Twee schakelaars in het instellingenbestand:

| | standaard | wat het doet |
|---|---|---|
| `RemuxIfNeeded` | `true` | nameten, en alleen remuxen als het niet klopt |
| `FinalRemux` | `false` | altijd remuxen, zonder nameten — het zekere voor het onzekere |

Zet `FinalRemux` op `true` als je liever de gordel om houdt; het kost een fractie
van de encodetijd. Zet `RemuxIfNeeded` op `false` en beide staan uit, en dan
vertrouwt het volledig op de vlag in de encode.

## Nacontrole op het geluid

Na elke geslaagde encode wordt gekeken of de audiotrack het einde van de film
haalt — op het tijdelijke bestand, dus voordat het origineel ook maar in de buurt
van verwijderen komt.

**Er wordt vergeleken met de bron, niet met een vaste drempel.** Dat is het
verschil met de eerste opzet, en het is de reden dat die veel te vaak aansloeg.
Een tekort van een paar seconden aan het eind is namelijk doodnormaal: in een
steekproef van 136 gewone bestanden uit de eigen bibliotheek had **18% er een, tot
4,9 seconden toe**. Een absolute grens van 5 seconden ligt daar precies bovenop,
en dus ging het alarm af op bestanden waar niets mis mee was. Zat er in het
origineel al 8 seconden stilte aan het eind, dan is 8 seconden in de uitvoer geen
fout maar een getrouwe kopie.

Daarom wordt vóór het encoderen ook de **bron** gemeten. Drie uitkomsten:

| | | |
|---|---|---|
| uitvoer net zo goed als de bron | niets aan de hand | geslaagd |
| bron was zelf al kort | staart met stilte opvullen | geslaagd |
| uitvoer duidelijk slechter dan de bron | resultaat weggooien, bron markeren | **VCP** |

### Staart opvullen

Houdt het geluid in de bron al eerder op dan het beeld, dan wordt de staart van
de uitvoer met stilte doorgetrokken tot het einde van het beeld. Er komt geen
geluid bij dat er niet was; het spoor wordt alleen compleet gemaakt, zodat
spelers aan het eind niet struikelen over een audiospoor dat er ineens niet meer
is.

Het beeld wordt daarbij gekopieerd, alleen het geluid gaat opnieuw door de
encoder — seconden, geen tweede conversie. Uit te zetten met `PadShortAudio`.

### Verlies in verhouding: opvullen of afkeuren

Is de uitvoer meer dan `AudioTailMargin` (2 s) slechter dan de bron, dan is er
bij het omzetten geluid verloren gegaan. Wat er dan gebeurt hangt af van hoeveel:

| verlies | wat er gebeurt |
|---|---|
| tot 2 s | niets, dat is meetruis |
| 2 s tot `AudioLossLimit` (30 s) | staart opvullen, **bestand behouden**, verlies in de log en in de resultaatkolom |
| meer dan 30 s | **VCP** — bestand weg, bron gemarkeerd |

Die tweede regel is een correctie op de eerste opzet, en een belangrijke. Die
keurde af zodra er meer dan een paar seconden weg was, en gooide daarmee een
conversie van drie kwartier weg voor het staartje van de aftiteling. In de
praktijk sneuvelde daar **25% van de bestanden** op: 33 van de 134, met verliezen
van 2,2 tot 5,4 seconden — geen enkel geval van echt ontbrekende inhoud. Ruim een
dag rekentijd, en niets om te houden.

### VCP

Pas boven `AudioLossLimit` ontbreekt er zoveel dat het bestand niets waard is
naast een origineel dat wel compleet is. Dan:

- het omgezette bestand wordt **weggegooid**
- het origineel blijft staan en krijgt **`VCP`** in de naam:
  `Film x264.mkv` wordt `Film x264.VCP.mkv`
- de scanner **slaat bestanden met die markering over**, dus een volgende ronde
  over dezelfde map steekt er geen uren meer in. Na de scan staat in de log
  hoeveel er zijn overgeslagen
- het telt **niet** mee voor de noodstop na drie fouten op rij. Het bestand komt
  toch niet meer langs, dus er kan geen herhaling ontstaan, en een run afbreken
  zou alleen rekentijd kosten

Wil je het later toch opnieuw proberen, gebruik dan **`Herstel-VCP-namen.ps1`**:

```powershell
.\Herstel-VCP-namen.ps1 -Path '\\10.0.0.242\h\Serie'         # alleen kijken
.\Herstel-VCP-namen.ps1 -Path '\\10.0.0.242\h\Serie' -Doen   # hernoemen
```

Dat haalt de markering uit de naam (`Film x264.VCP.mkv` en
`Film x264.VCP (2).mkv` worden beide weer `Film x264.mkv`), zodat de bestanden
bij de volgende scan gewoon meekomen. Bestaat de gewone naam al — er staat dus al
een geslaagde omzetting — dan wordt dat bestand overgeslagen en niets
overschreven. Zonder `-Doen` laat het alleen zien wat het zou doen.

De markering is aan te passen met `VcpMarker` in het instellingenbestand; geef
dan hetzelfde mee aan `-Marker`.

### Wat de meting wel en niet kan

De controle kost bijna niets: er wordt naar de staart van het bestand gesprongen
en daar een venster van 20 seconden gelezen. Het bestand is net geschreven en
staat nog in de cache.

> Eén valkuil in de code, met een waarschuwing erbij zodat niemand hem later
> "opruimt": bij die ffprobe-aanroep mag **`-select_streams` er niet bij staan**.
> Die optie lijkt zuiniger omdat je maar één spoor opvraagt, maar ffprobe negeert
> daarmee de seek en leest het hele bestand alsnog — nagemeten 13,4 MB tegen
> 0,6 MB.

Wat het **niet** doet: opnieuw encoderen met AAC brengt geluid dat in de bron
ontbreekt niet terug. `aresample` vult gaten *tussen* pakketten op, niet een
ontbrekende staart — nagetest. Daarvoor is het opvullen hierboven.

Instellingen: `CheckAudioTail` (aan), `AudioTailTolerance` (2 s — vanaf welk
tekort de staart het opvullen waard is), `AudioTailMargin` (2 s — vanaf hoeveel
achterstand op de bron het verlies heet), `AudioLossLimit` (30 s — vanaf hoeveel
verlies het bestand wordt afgekeurd), `PadShortAudio` (aan) en `VcpMarker`
(`VCP`).

## Welke sporen meegaan naar de MKV

MKV kan alleen beeld, geluid, ondertitels en bijlagen opslaan. Een mp4 bevat
vaak meer, en blind `-map 0` gaat daar stuk op. De melding is dan:

```
[out#0/matroska] Nothing was written into output file,
because at least one of its streams received no packets.
```

Dat klinkt alsof er iets mis is met het bestand, maar de echte oorzaak staat een
paar regels eerder: *"Only audio, video, and subtitles are supported for
Matroska"*. De muxer weigert de header te schrijven, en dan komt er niets uit.

Daarom worden de sporen nu vooraf opgevraagd en wordt er een expliciete maplijst
gebouwd:

| spoor | wat er gebeurt |
|---|---|
| beeld | gaat mee |
| beeld met de vlag "omslagafbeelding" | **overgeslagen** — anders gaat een plaatje onnodig door de x265-encoder |
| geluid | gaat mee |
| ondertitels in srt, ass, ssa, webvtt, PGS, dvd_subtitle | gaan mee zoals ze zijn |
| ondertitels in mov_text of tx3g (uit mp4/mov) | **omgezet naar srt** — MKV kan die niet kopiëren |
| ondertitels in een ander formaat | overgeslagen, met melding |
| bijlagen (fonts) | gaan mee |
| data, timecode (`tmcd`) en de rest | **overgeslagen**, met melding |

Elk ondertitelspoor krijgt zijn eigen instelling. Dat moet: een vaste `-c:s copy`
gaat stuk op mov_text, en een vaste `-c:s srt` zou beeldondertitels zoals PGS
slopen. Alles wat wordt overgeslagen komt als regel in de log, dus je ziet wat er
niet is meegegaan.

Kunnen de sporen niet worden uitgelezen, dan wordt alles meegenomen behalve
datastromen (`-map 0 -map -0:d`) — die weigert de muxer sowieso.

### De herpoging

Mislukt de eerste poging toch, dan volgt er één met **alleen het eerste
beeldspoor en het geluid**, zonder ondertitels en bijlagen. Dat is vast gedrag;
uit te zetten met `SmartRetry` in het instellingenbestand.

> Hier zat een fout in die precies het tegenovergestelde deed van wat de
> bedoeling was. De lijst met meldingen waarbij een herpoging wordt overgeslagen
> ("het invoerbestand is zelf kapot") bevatte `Invalid argument`. Dat is veel te
> algemeen: die tekst komt ook voorbij in *"Could not write header (incorrect
> codec parameters ?): Invalid argument"* — een probleem met de **uitvoer**. Zo
> werd juist de herpoging overgeslagen die het bestand had kunnen redden.

## Ondertitels

Staat er naast de video een ondertitelbestand met dezelfde naam, dan krijgt dat
de nieuwe naam mee. `Film x264.srt` wordt `Film.x265.srt`.

- **Origineel verwijderen aan** → omnoemen.
- **Origineel verwijderen uit** → kopiëren; de originele ondertitels blijven bij
  het originele videobestand staan.
- Lukt het verwijderen van het origineel niet (status "Let op"), dan wordt er ook
  gekopieerd in plaats van omgenoemd, zodat het origineel zijn eigen ondertitels
  houdt.
- Een taalcode of vlag blijft staan: `Film x264.en.forced.srt` wordt
  `Film.x265.en.forced.srt`.
- `.idx` en `.sub` horen bij elkaar en gaan samen mee.
- Alleen bestanden waarvan de naam begint met exact de naam van de video **en**
  waarvan de rest met een punt begint. `Film x264b.srt` gaat dus niet mee.
- Een bestaande doelnaam wordt nooit overschreven; dat komt in de log.
- Het gaat nooit ten koste van de conversie en telt nooit mee in de noodstop.

Extensies: `.srt .sub .idx .ssa .ass .vtt .sup .txt .smi .sbv`. Die lijst staat
niet in de GUI (te veel knoppen) maar wel als `SubExtensions` in het
instellingenbestand, dus met de hand aan te passen.

## Statistieken

Per run: rekentijd zonder pauzes, wandkloktijd en pauzeduur, aantal bestanden,
totaal origineel, totaal na omzetting, besparing in bytes en procenten,
gemiddelde snelheid, resterende tijd en "klaar omstreeks". Ook in de
venstertitel en op de taakbalkknop.

Onderaan staat **ALLE SESSIES BIJ ELKAAR**: een cumulatieve teller die over
sessies heen doorloopt — aantal bestanden, origineel, na omzetting, bespaarde
ruimte, rekentijd en omgezette speelduur. Die wordt na **iedere** geslaagde
conversie weggeschreven, niet pas bij het afsluiten, zodat een crash of
stroomstoring de historie niet weggooit.

## Vensterpositie

Waar je het venster neerzet blijft bewaard: positie, afmetingen en of het
gemaximaliseerd stond. Dat gaat mee in het instellingenbestand en wordt
teruggezet voordat het venster in beeld komt, zodat het niet zichtbaar
verspringt.

**Het lastige is niet het bewaren maar het terugzetten.** Een positie die
gisteren klopte kan vandaag buiten beeld liggen: een tweede scherm dat uit staat,
een laptop die van het dock af is, een monitor die links van de hoofdmonitor hing
(en dus negatieve coördinaten had) en er niet meer is. Zonder controle start het
programma dan onzichtbaar op, en dan lijkt het kapot.

Daarom wordt een teruggezette positie getoetst aan het scherm zoals het **nu** is:

- ligt het venster (deels) buiten beeld, dan wordt het teruggeschoven tot het er
  helemaal binnen valt, met een regel in de log
- is het venster groter dan wat er nog aan schermruimte over is, dan worden de
  afmetingen ingekort
- was het gemaximaliseerd, dan komt het zo terug — met de herstelmaat eronder,
  zodat het venster ook na un-maximaliseren een bruikbaar formaat heeft
- een negatieve X wordt **niet** zomaar weggepoetst: hangt dat scherm er nog,
  dan blijft het venster gewoon staan waar het stond
- onzin of ontbrekende waarden in het instellingenbestand leiden nooit tot een
  vreemd venster; dan wordt het gewoon gecentreerd zoals vroeger

> De schermafmetingen komen van `SystemParameters`, niet van
> `System.Windows.Forms.Screen`. Dat laatste kan per monitor kijken, maar het
> levert fysieke pixels op, en die kloppen niet meer met `$win.Left` zodra er
> ergens een schaling van 125% of 150% aanstaat.

## KeepAwake: de pc weer laten slapen

Draait er een KeepAwake-script dat Windows wakker houdt zolang er wordt
geconverteerd, dan geeft dit programma het stopsignaal zodra de conversie klaar
is — en in elk geval **voordat het zichzelf eventueel afsluit**. Anders blijft de
pc wakker met niemand thuis.

Het gaat om een named event, standaard `KeepAwakeStopSignal`. Dat wordt gezet:

- zodra een conversierun afloopt, op welke manier dan ook: wachtrij leeg, **Stop
  direct**, **Stop na huidige**, of een noodstop na drie fouten
- bij het afsluiten terwijl er nog werk liep
- altijd vóór de afsluitteller van "Programma afsluiten na conversie stop"

Per run gaat het signaal één keer af. Start je daarna een nieuwe conversie, dan
kan het weer.

Draait KeepAwake niet, dan bestaat het event niet en gebeurt er niets — geen
melding, geen fout. Alleen als er iets ánders misgaat komt er een regel in de
log. De naam is aan te passen met `KeepAwakeSignal` in het instellingenbestand;
leeg maken schakelt het helemaal uit.

## Instellingen

Bij het opstarten: **libx265, preset medium, CRF 23, audio/subs/attachments
kopiëren, container MKV**. Aanpasbaar:

- **Encoder** — `libx265` (CPU) of hardware: `hevc_nvenc`, `hevc_qsv`,
  `hevc_amf`. Presetlijst en kwaliteitsparameter passen zich aan.
- **CRF** — schuif 0–51.
- **Geluid** — kopieren, AAC, AC3 of FLAC. Zie het kopje hierboven.
- **Extensies** — welke bestanden aan `ffprobe` worden aangeboden.
- **Werkmap** — "Opruimen" wist achtergebleven `x265_*`-bestanden.
- **Origineel verwijderen na geslaagde verplaatsing**
- **Ondertitels meenemen naar de nieuwe naam**
- **Programma afsluiten na conversie stop** — standaard uit. Sluit af als de
  wachtrij leeg is, én na Stop direct en Stop na huidige. Er wordt eerst alles
  bewaard (instellingen, wachtrij, totalen) en de werkmap opgeruimd. Je krijgt
  10 seconden met een **Afsluiten annuleren**-knop. Loopt er nog een scan, dan
  wacht het tot die klaar is. Bij een noodstop wordt er niet afgesloten.

**Drie dingen staan vast en hebben geen vinkje meer**, omdat ze altijd aan
stonden: submappen meenemen, de wijzigingsdatum van het origineel overnemen, en
de slimme herpoging. Ze staan nog wel als `Recursive`, `KeepDate` en `SmartRetry`
in het instellingenbestand, dus met de hand aanpassen kan.

**Alleen in het instellingenbestand**, zonder vinkje in het venster:

| Sleutel | Standaard | Betekenis |
| --- | --- | --- |
| `PrefetchToWorkDir` | `true` | Bron eerst naar de werkmap kopiëren |
| `PrefetchOnlyNetwork` | `true` | Alleen bij een UNC-pad of netwerkschijf |
| `SharedLocks` | `true` | Lock-bestanden plaatsen voor twee pc's op dezelfde map |
| `LockStaleMinutes` | `15` | Wanneer een lock als verweesd geldt |
| `RestoreQueue` | `false` | Wachtrij bewaren over een herstart heen |
| `Recursive`, `KeepDate`, `SmartRetry` | `true` | Zie hierboven |

**Al HEVC overslaan is vast gedrag** — daar is geen vinkje meer voor. Zulke
bestanden komen na een scan wel in de lijst met status `Al HEVC`, zodat je ziet
wat er is overgeslagen, en verdwijnen bij het starten van de conversie. Ze zijn
**niet aanvinkbaar**: het vinkje is grijs en de code weigert het ook, dus ook
"alles aanvinken" en een teruggezette wachtrij kunnen er niet omheen.

## Op een beheerde (dichtgezette) machine

Het programma heeft **geen beheerdersrechten nodig**. Draait het toch mis met
"Toegang geweigerd", dan zit het in een van deze twee dingen, en die worden nu
allebei opgevangen.

**Mappen waar je niet bij mag.** Windows geeft bij zo'n map geen "bestaat niet"
terug maar gooit een fout, en een kale `Test-Path` laat het programma dan omvallen
op een knopdruk. In de stack is dat te herkennen aan `NativeDirectoryExists` en
`IsItemContainer`. Alle padcontroles in de interface lopen nu via `Test-PathSafe`,
dat altijd gewoon `$true` of `$false` teruggeeft.

**Schrijven waar het niet mag.** Twee plekken:

- **De werkmap.** Die moet bestaan én beschrijfbaar zijn — dat laatste is een
  ander verhaal, een map kan prima bestaan en toch op slot zitten. Een pad uit het
  instellingenbestand van een andere machine (`C:\Temp\WinTemp`, bijvoorbeeld)
  valt hier doorheen. Bij het opstarten en bij het starten van een conversie wordt
  dit nagegaan; is de map niet bruikbaar, dan wijkt het programma uit naar
  `%TEMP%\X265-Converter` en zegt dat in de log.
- **De map naast het script.** Daar gaan normaal het instellingenbestand en
  `X265-Converter.error.log` heen. Is die map alleen-lezen — op een beheerde
  laptop is `C:\Tools` dat vaak — dan gaan ze naar
  `%LOCALAPPDATA%\X265-Converter`. Een bestaand instellingenbestand wordt daarbij
  eenmalig meegenomen, zodat de wachtrij en de totalen niet verdwijnen. Ook dat
  staat in de log.

Starten als beheerder is dus niet nodig, en ook niet de bedoeling: de bestanden
zouden dan onder het beheerdersaccount worden weggeschreven en bij een gewone
start weer onvindbaar zijn.

## Als er iets misgaat

Onverwachte fouten komen in het logvenster, in een melding op het scherm, en in
`X265-Converter.error.log` — naast het script, of in `%LOCALAPPDATA%\X265-Converter`
als daar niet geschreven mag worden. De melding op het scherm noemt het pad. Een fout in de weergave zet de
conversie niet stil.

## Benodigdheden

Windows PowerShell 5.1 (standaard aanwezig) en `ffmpeg\bin\ffmpeg.exe` +
`ffprobe.exe` naast het script. Zijn ze er niet, dan valt het script terug op
ffmpeg in `PATH` en biedt anders aan de release te downloaden.
