# PRD — Klep

Status: draft. Branch `feat/speech`. Owner: Erik. HQ: `pitchlab/pitchlab-speech`, doel `PL-689`.

## Waarom

SpeechButton is de dicteer-app die in gebruik was: push-to-talk, hotkey vasthouden, tekst verschijnt bij de cursor, hands-free modus met auto-enter na stilte. Hun server is down, dus de app is niet meer te installeren of te heractiveren. Klep is de vervanger, volledig lokaal en zonder server die uit kan vallen — geen licentie-check, geen cloud-STT, geen account.

## Doel

Een macOS-app die spraak omzet in tekst op de plek waar je aan het typen bent, aangestuurd vanaf het toetsenbord, met een lokaal STT-model. Werkt zonder netwerk.

## Niet-doelen

- Geen cloud-STT en geen telemetrie. Audio verlaat de machine niet.
- Geen AI-transformatie van transcripten (SpeechButtons "channels" met per-hotkey LLM-pipelines). Dictatie is de scope; routeren naar agents is een latere vraag.
- Geen iOS, geen Intel-Macs. Apple Silicon.
- Geen App Store-distributie.

## Requirements

MoSCoW. Elke requirement is een uitkomst, niet een implementatie.

### Must

**R1 — Status bar menu.** De app draait als menubalk-item zonder Dock-icoon (`LSUIElement`). Het menu toont de huidige staat (luistert / uit / bezig met transcriberen), de actieve microfoon, en de ingestelde hotkeys. Vanuit het menu zijn instellingen en afsluiten bereikbaar.

**R2 — Auto-start bij inloggen.** De app start mee met de gebruikerssessie, aan/uit te zetten binnen de app zelf (`SMAppService`). Standaard aan na eerste setup.

**R3 — Twee losse toetsenbord-toggles.** Globale hotkeys, werken vanuit elke app:
- **Hands-free aan/uit** — zet continu luisteren aan of uit. In hands-free bepaalt voice activity detection wanneer een uiting begint en eindigt.
- **Auto-enter aan/uit** — bepaalt of er na een afgeronde uiting een Return wordt gestuurd. Los te schakelen van hands-free, want in een chatvenster wil je hem aan en in een editor niet.

Beide hotkeys zijn herdefinieerbaar. De actuele staat van elke toggle is af te lezen in de menubalk zonder het menu te openen.

**R4 — Lokale STT via Parakeet.** Transcriptie draait op een lokaal Parakeet-model op Apple Silicon. Geen netwerkverkeer tijdens transcriberen; de app werkt volledig offline zodra het model op schijf staat. Het model is `parakeet-tdt-0.6b-v3` tenzij een meting een ander model aanwijst.

**R5 — Twee uitvoerbestemmingen.** Een afgerond transcript gaat naar:
- **De cursor** — de tekst wordt ingevoegd in het venster dat focus heeft, in elke app.
- **stdout** — een CLI-modus schrijft transcripten naar standaarduitvoer, zodat spraak in een pipe past.

Welke bestemming actief is, is een instelling; beide tegelijk mag.

**R6 — Microfoonkeuze.** De invoerbron is te kiezen uit de aangesloten apparaten, via het menubalk-menu. De keuze blijft bewaard tussen sessies. Verdwijnt het gekozen apparaat (AirPods uit), dan valt de app terug op de systeemstandaard en meldt dat.

### Should

**R7 — Zichtbare opnamestaat.** Tijdens luisteren is buiten het menu zichtbaar dat de microfoon open staat, inclusief een niveau-indicatie. Een dicteer-app die stilletjes meeluistert zonder dat je het ziet, is de reden dat mensen hem uitzetten.

**R8 — Eerste woord niet afkappen.** Opname begint vóór het moment waarop de gebruiker denkt te beginnen (rolling pre-roll buffer), zodat het eerste woord na een hotkey compleet is. SpeechButton noemt 20 ms capture-latency als hun onderscheid ten opzichte van macOS Dictation (~500 ms).

**R9 — Permissies expliciet.** De app vraagt Microfoon, Accessibility (of Input Monitoring) gericht, legt per permissie uit waarvoor die dient, en toont in het menu wat er ontbreekt. Zonder Accessibility werkt R5 niet en dat moet de app zeggen in plaats van stil te falen.

### Could

**R10 — Transcripten opslaan en doorzoeken.** Optioneel — expliciet gemarkeerd als zodanig. Afgeronde transcripten worden lokaal bewaard met tijdstip, duur, en de app die focus had, en zijn full-text doorzoekbaar. Opslag is standaard **uit**; aanzetten is een bewuste keuze. Een bewaard transcript is te verwijderen en de hele geschiedenis is in één handeling te wissen.

## Technische context

Gemeten op deze machine, niet aangenomen:

| Wat | Staat |
|---|---|
| Architectuur | `arm64`, macOS 26 |
| Swift | 6.2.4 |
| Xcode | Niet geïnstalleerd — alleen Command Line Tools, en dat is **genoeg** (twee spikes) |
| STT | **FluidAudio 0.15.6**, Parakeet TDT 0.6b v3 als CoreML op de Neural Engine |
| Model op schijf | 473 MB, in `~/Library/Application Support/FluidAudio/Models/` |
| Python | **Niet gebruikt.** Zie de beslissing hieronder. |

## Spike: Xcode is niet nodig — 2026-08-31

Gemeten, niet aangenomen. Met alleen Command Line Tools compileerde `swiftc` een AppKit-menubalk-app die alle systeem-API's aanraakt die de must-requirements nodig hebben:

| API | Requirement | Framework |
|---|---|---|
| `NSStatusItem` | R1 menubalk | AppKit |
| `SMAppService.mainApp.register()` | R2 auto-start | ServiceManagement |
| `RegisterEventHotKey` | R3 globale hotkeys | Carbon.HIToolbox |
| `AVCaptureDevice.DiscoverySession` | R6 microfoonlijst | AVFoundation |
| `CGEvent(keyboardEventSource:)` | R5 typen bij de cursor | CoreGraphics |

De CLT-SDK op `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` bevat 295 frameworks, inclusief AppKit, Cocoa, AVFoundation, ServiceManagement en Carbon. De binary is daarna handmatig als `.app` gebundeld met een `Info.plist` met `LSUIElement`, en ad-hoc getekend met `codesign` — signatuur geverifieerd. `notarytool` zit óók in de CLT, op `/Library/Developer/CommandLineTools/usr/bin/notarytool`, dus zelfs notariseren voor distributie vraagt geen Xcode.

Wat Xcode wél zou toevoegen: Interface Builder, `.xcodeproj`, simulators en previews. Geen daarvan is nodig voor een menubalk-app zonder vensters. **Niet installeren, ~15 GB bespaard.**

## Spike 2: Parakeet in Python gemeten — 2026-08-31

Historisch. Deze meting was correct maar leidde tot een verkeerde conclusie; ze staat hier omdat de vergelijking met spike 3 het ontwerp bepaalt.

`parakeet-mlx` 0.5.2, model `parakeet-tdt-0.6b-v3` uit de HF-cache, met `HF_HUB_OFFLINE=1`. Testaudio via `say -v Xander`, 16 kHz mono. Het meetscript is verwijderd samen met de rest van het Python-werk; deze tabel is wat ervan bewaard is.

| Meting | Waarde |
|---|---|
| import `parakeet_mlx` | 0,34 s |
| model laden | 5,71 s |
| eerste transcriptie (2,6 s audio) | 3,43 s |
| **koude start totaal** | **9,5 s** |
| warme transcriptie, 2,6 s audio | 0,14 s |
| warme transcriptie, 8,7 s audio | 0,23 s — **38× realtime** |
| streaming, 0,5 s-chunks | mediaan 199 ms, max 431 ms |
| piek-geheugen | 1,35 GB |

Twee dingen hieruit staan nog overeind:

- **VAD-gesegmenteerde batch verslaat streaming.** Een hele uiting van 8,7 s transcriberen kost 0,23 s — sneller dan de 3,7 s die streaming over dezelfde audio doet, en nauwkeuriger: streaming maakte er "dekteer" en "PitglabSpeeds" van waar batch "dicteer" en "Pitglab Speech" gaf. Streaming is alleen nodig als je tekst wilt zien terwijl je nog praat. **Default is batch-per-uiting.**
- Nederlands komt er goed uit; eigennamen niet ("Pitglab" voor "PitchLab"). Te verwachten, geen blocker.

Wat er níét uit volgde, hoewel het hier wel is geconcludeerd: dat de app Python moest worden.

## Spike 3: Parakeet native in Swift — 2026-08-31

`PL-715` / `PIT-847`, uitgevoerd door de Paperclip Task Runner en nagedraaid door het board. Project: `spikes/swift-parakeet/`, verslag: `docs/spike-swift-parakeet.md`.

**FluidAudio 0.15.6** resolvet als SwiftPM-dependency en compileert met alleen Command Line Tools. Het laadt Parakeet TDT 0.6b v3 als CoreML op de Neural Engine — hetzelfde model, andere runtime.

| Meting (2,6 s audio) | Swift + CoreML | Python + MLX |
|---|---|---|
| koude start (model gecacht) | **0,47 s** | 9,5 s |
| warme transcriptie | **0,12 s** | 0,14 s |
| piek-geheugen | **79 MB** | 1,35 GB |
| model op schijf | **473 MB** | 2,3 GB |

Transcript: `Zet handsfree modus aan en typ dit bij de cursor.` Correct. Met een dode HTTPS-proxy draait hij door, dus offline werkt na de eenmalige modeldownload.

FluidAudio bevat ook **VAD**, die R8 en de uiting-segmentatie nodig hebben. Die bouwen we dus niet zelf.

Niet bewezen in deze spike: streaming-latency per chunk, gedrag op echte spraak met ruis, en inbedding in een `.app` met signing.

## Beslist: puur Swift — 2026-08-31

**De app is Swift. Geen Python.** SwiftPM, AppKit voor de menubalk, AVFoundation voor audio, Carbon voor de hotkeys, FluidAudio voor STT en VAD.

De eerdere uitkomst all-Python is ingetrokken. Die redeneerde: het model moet warm blijven, `parakeet-mlx` is Python, dus het langlevende proces is Python, dus Swift levert niets op. Die keten klopt alleen als `parakeet-mlx` de enige manier is om Parakeet te draaien, en dat was een aanname die niet is getoetst. Spike 3 weerlegt hem: Swift is 24× sneller op koude start en gebruikt 17× minder geheugen, met dezelfde nauwkeurigheid.

Het Python-werk is verwijderd — uit de integratiebranch, uit de losse branches en uit de history. Er is geen Python meer in dit project. Loopt FluidAudio ooit vast, dan is het terugvalpad Python als backend met een Swift-UI, met PCM erin en tekst eruit als enige brug; dat wordt dan opnieuw gebouwd, want er ligt niets meer om terug te halen. Gezien de meetwaarden hierboven is dat pad theoretisch.

## Open beslissingen

De taalkeuze stond hier als nummer 1 en is beslist: puur Swift, zie hierboven.

1. **Invoegen bij de cursor: `CGEvent`-toetsaanslagen of pasteboard + Cmd-V.** Toetsaanslagen laten het plakbord met rust maar zijn traag bij lange tekst; plakken is direct maar overschrijft wat de gebruiker gekopieerd had. Bepaalt mede welke permissie R9 moet vragen. HQ: `PL-702`.
2. **Wat "afgeronde uiting" is in hands-free.** Stiltedrempel in seconden, en of die instelbaar moet zijn. SpeechButton gebruikt 3 s voor auto-enter. Nu FluidAudio de VAD levert, is de vraag welke van zijn parameters we blootstellen.
3. **Model-download bij eerste start.** 473 MB. Meeleveren kan niet; ophalen bij eerste start is de enige netwerkafhankelijkheid die de app heeft en moet als zodanig gepresenteerd worden.
4. **Streaming voor live partials.** Batch-per-uiting is de default. FluidAudio heeft een streaming-API (`StreamingUnifiedAsrManager`) die niet gemeten is. Pas oppakken als tekst-terwijl-je-praat gewenst blijkt.

## Definition of done

- Menubalk-app start mee met inloggen, zonder Dock-icoon.
- Hands-free en auto-enter zijn los te schakelen met een hotkey vanuit elke app, en de staat is afleesbaar zonder het menu te openen.
- Gesproken tekst verschijnt bij de cursor in minstens drie verschillende apps (browser, terminal, editor), met het eerste woord compleet.
- CLI-modus schrijft hetzelfde transcript naar stdout en is in een pipe te gebruiken.
- Microfoon is te kiezen, de keuze overleeft een herstart, en loskoppelen geeft een melding in plaats van stilte.
- Transcriberen werkt met het netwerk uit.
- R10 is af of expliciet geschrapt; niet half.
