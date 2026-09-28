# Bumlebee 🐝

**Konvertér filer dér, hvor du allerede er.** Bumlebee er en lille menulinje-app til macOS. Hold **⇧ Shift**, mens du trækker en fil i Finder, og et hjul af honningceller med outputformater dukker op om markøren. Slip filen på det format, du vil have, så lægges den konverterede kopi ved siden af originalen.

Holder du **⌥ Option + ⇧ Shift** i stedet, fyldes hjulet med værktøjer til netop den slags fil.

Alt foregår lokalt på din Mac. Bumlebee sender ingen filer nogen steder hen.

## Sådan bruges den

| Gør dette | Og så sker der |
| --- | --- |
| Træk en fil, og hold ⇧ | Hjulet til **konvertering** åbner om markøren |
| Træk en fil, og hold ⌥⇧ | Hjulet med **værktøjer** åbner. Skift frem og tilbage undervejs med ⌥ |
| Slip på en celle | Jobbet starter. Et lille vindue viser fremdriften, og resultatet vises i Finder |
| Slip i midten | Intet sker, og filen hopper tilbage |
| Træk flere filer | Alle behandles i ét job |
| Træk filer til ikonet i menulinjen | Hjulet åbner under ikonet (hold ⌥ for værktøjer) |
| Menulinjen → *Konvertér filer …* | Vælg filer uden at trække. Klik på midten eller tryk Tab for at skifte hjul, og Esc for at lukke |
| Højreklik → *Åbn med* → Bumlebee | Hjulet åbner midt på skærmen |

## Hvad den kan

### Konvertering

| Fra | Til |
| --- | --- |
| Billeder (JPEG, PNG, HEIC, WebP, AVIF, TIFF, BMP, GIF, SVG, RAW …) | JPG, PNG, HEIC, WebP\*, AVIF\*, PDF, GIF, TIFF, BMP, ICO |
| Video (MP4, MOV, M4V, samt MKV/WebM/AVI/WMV\*) | MP4, MOV, MKV\*, WebM\*, GIF, AVI\*, WMV\*, M4A, MP3\*, WAV |
| Lyd (MP3, M4A, WAV, AIFF, FLAC, CAF, samt OGG/Opus\*) | MP3\*, M4A, WAV, FLAC, AIFF, OGG\*, Opus\*, CAF |
| PDF | PNG, JPG, TIFF (én fil pr. side), TXT, DOCX, RTF, HTML |
| Dokumenter (DOCX, DOC, RTF, ODT, HTML, TXT, Markdown) | PDF, DOCX, RTF, TXT, HTML, ODT, Markdown |
| Undertekster (SRT, VTT) | SRT, VTT, TXT |
| Arkiver (ZIP, TAR, TAR.GZ, RAR, 7Z …) | ZIP, TAR.GZ, TAR |
| Alt andet, også mapper | ZIP, GZIP, TAR.GZ, TAR |

\* kræver [ffmpeg](#ffmpeg-valgfrit). Formater, der mangler ffmpeg, vises med en lås i hjulet.

### Værktøjer (⌥⇧)

- **Billeder:** komprimér, ram en bestemt filstørrelse, skalér, beskær, justér (eksponering, kontrast, mætning, varme, højlys, skygger, skarphed), tegn (pen, pil, firkant), censurér (pixelér, slør eller sort), fjern baggrund, læs QR-koder og stregkoder, vis/redigér/fjern metadata. Med flere billeder: saml til PDF, lav collage eller GIF.
- **Video:** komprimér (HEVC), ram en filstørrelse, klip, snapshot, del op, skift hastighed, fjern lyd, udtræk lyd, rotér (uden kvalitetstab), metadata. Med flere videoer: saml til én.
- **Lyd:** komprimér, ram en filstørrelse, normalisér (−1 dBFS), klip, del op, mono/stereo, skift hastighed (tonehøjden bevares), metadata. Med flere filer: saml til én.
- **PDF:** komprimér, ram en filstørrelse, organisér sider (flyt, rotér, slet), del op i sider, rotér, læs QR-koder, redigér/fjern metadata. Med flere PDF'er: saml til én.
- **Dokumenter og undertekster:** statistik (ord, tegn, læsetid), forskyd undertekster i tid.
- **Arkiver og mapper:** pak ud (også RAR og 7Z), pak som ZIP, vis indhold.

## Byg og installér

Kræver macOS 14 (Sonoma) eller nyere og Xcode 15+ eller Xcodes Command Line Tools (`xcode-select --install`).

```bash
cd apps/Bumlebee
./Scripts/build-app.sh --install
```

Scriptet bygger `build/Bumlebee.app`, tegner app-ikonet, signerer ad hoc, lægger appen i `/Applications` og starter den. Uden `--install` bygges kun `build/Bumlebee.app` og `build/Bumlebee.zip`.

Til udvikling kan du åbne `Package.swift` i Xcode og køre derfra.

**Første gang:** Der kommer et velkomstvindue. Bumlebee skal ikke bruge særlige tilladelser, for den lytter kun efter musetræk og læser, hvilke filer der bliver trukket.

Henter du en færdigbygget `Bumlebee.zip` fra GitHub Actions i stedet for at bygge selv, er appen kun ad hoc-signeret. Fjern derfor karantænen efter udpakning:

```bash
xattr -dr com.apple.quarantine /Applications/Bumlebee.app
```

## ffmpeg (valgfrit)

macOS klarer selv de fleste formater. MP3, OGG, Opus, MKV, WebM, AVI og WMV samt WebP- og AVIF-output kræver ffmpeg:

```bash
brew install ffmpeg
```

Bumlebee finder selv ffmpeg i `/opt/homebrew/bin`, `/usr/local/bin` og `/opt/local/bin`. Du kan også vælge stien under *Indstillinger*. Vil du have en app, der klarer sig helt selv, kan du bygge med en statisk ffmpeg indbygget:

```bash
FFMPEG_PATH=/sti/til/ffmpeg ./Scripts/build-app.sh
```

## Indstillinger

- Hvor nye filer gemmes: ved siden af originalen, i Overførsler eller i en mappe, du vælger. Eksisterende filer bliver aldrig overskrevet, og nye navne nummereres.
- Vis resultatet i Finder, og afspil en lyd, når et job er færdigt.
- Standardkvalitet for JPEG, HEIC og WebP.
- Start ved login, og sæt Bumlebee på pause.

## Sådan er den bygget

```
Sources/Bumlebee/
  App/       main, AppDelegate (menulinje), Actions (hjulvalg → job), Prefs
  Drag/      DragMonitor: globale musetræk + drag-pasteboardet + modifier-taster
  Wheel/     WheelController (gennemsigtigt panel, drop- og klikmål) og WheelView (SwiftUI)
  Model/     FileKind, Format, Tool, Catalog (hvad hjulet viser for hvilke filer)
  Jobs/      JobRunner (baggrundsjob, fremdriftsvindue, Vis i Finder), JobContext, Output (navngivning)
  Engines/   Image (ImageIO), Video (AVFoundation), Audio (AVAssetReader → AVAudioFile),
             PDF (PDFKit/Quartz), Document (AppKit), Subtitle, Archive (ditto/zip/tar),
             Metadata, Vision (baggrund, QR), FFmpeg (valgfrit)
  UI/        billed-editor, afspiller med klip, metadata, PDF-organisering, indstillinger, velkomst
```

Hjulet opdager et træk uden tilladelser til skærm- eller tastaturovervågning. Det bygger på tre signaler: globale `leftMouseDown`/`leftMouseDragged`-events, drag-pasteboardets `changeCount`, som stiger, når et nyt træk starter, og `NSEvent.modifierFlags`. Mens museknappen er nede, spørger en timer 30 gange i sekundet. Derfor virker det også, når du trykker ⇧ midt i et træk med stillestående mus.

## Begrænsninger

- Billeder kan ikke konverteres *til* SVG (vektorisering), og der kan ikke *laves* RAR-arkiver.
- Der er endnu ingen bip-censur af lyd og ingen beskæring af video.
- Når flere videoer samles, bruges den første videos format og orientering.
