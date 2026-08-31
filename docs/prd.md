# PRD — pitchlab-speech

Status: draft. Branch `feat/speech`. Owner: Erik. HQ: `pitchlab/pitchlab-speech`, doel `PL-689`.

## Waarom

SpeechButton is de dicteer-app die in gebruik was: push-to-talk, hotkey vasthouden, tekst verschijnt bij de cursor, hands-free modus met auto-enter na stilte. Hun server is down, dus de app is niet meer te installeren of te heractiveren. `pitchlab-speech` is de vervanger, volledig lokaal en zonder server die uit kan vallen — geen licentie-check, geen cloud-STT, geen account.

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
| Xcode | Niet geïnstalleerd — alleen Command Line Tools, en dat is **genoeg** (zie spike) |
| MLX | `mlx` + `mlx-metal` 0.32.0 |
| Parakeet-model | `mlx-community/parakeet-tdt-0.6b-v3` staat al in de HF-cache |
| `parakeet-mlx` CLI | niet geïnstalleerd |

Twee dingen die de architectuur bepalen:

`parakeet-mlx` 0.5.2 **heeft** streaming: `transcribe_stream()` levert een `StreamingParakeet` met `add_audio()` en een doorlopend `.result`. Een eerdere versie van deze PRD beweerde het tegendeel op gezag van een blogpost. De geïnstalleerde package telt.

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

Wat dit niet oplost: dat `parakeet-mlx` Python is. Zie de meting hieronder.

## Spike: Parakeet gemeten — 2026-08-31

`parakeet-mlx` 0.5.2, model `parakeet-tdt-0.6b-v3` uit de HF-cache, met `HF_HUB_OFFLINE=1`. Script: `spikes/measure_parakeet.py`. Testaudio via `say -v Xander`, 16 kHz mono.

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

Drie dingen volgen hieruit, en ze bepalen het ontwerp:

- **Het model moet warm blijven.** 9,5 s koude start tegen 0,14 s warm is een factor 68. Een proces per uiting starten is uitgesloten; er moet een langlevend proces zijn dat het model vasthoudt, in elk ontwerp, en dat proces kost 1,35 GB.
- **VAD-gesegmenteerde batch verslaat streaming.** Een hele uiting van 8,7 s transcriberen kost 0,23 s — sneller dan de 3,7 s die streaming over dezelfde audio doet, en nauwkeuriger: streaming maakte er "dekteer" en "PitglabSpeeds" van waar batch "dicteer" en "Pitglab Speech" gaf. Streaming is alleen nodig als je tekst wilt zien terwijl je nog praat. **Default wordt batch-per-uiting**; streaming blijft beschikbaar voor live partials.
- **Streaming heeft weinig marge.** 431 ms verwerken per 500 ms audio is 14 % speling in het slechtste stuk. Haalbaar, maar niet iets om hands-free op te bouwen zolang batch 38× realtime haalt.

Nederlands komt er goed uit; eigennamen niet ("Pitglab" voor "PitchLab"). Dat is te verwachten en is geen blocker.

## Beslist: all-Python — 2026-08-31

`PL-690` is hiermee gesloten. **De app wordt Python: `rumps` + `pyobjc` voor de menubalk en de systeem-API's, `parakeet-mlx` voor STT, in één langlevend proces.**

De meting maakt de keuze eenzijdig. Omdat het model hoe dan ook warm moet blijven in een langlevend Python-proces, vermijdt een Swift-schil geen enkel probleem: je moet Python tóch meebundelen, en je krijgt er een IPC-laag en een tweede taal bovenop. Swift-native zou alleen winnen door `parakeet-mlx` te laten vallen voor een CoreML- of MLX-Swift-port van Parakeet, en dat is een project op zich met een onbewezen uitkomst.

De prijs: bundelen tot één `.app` is lastiger in Python. Dat is te dragen, want de spike toonde dat een `.app` niets meer is dan een map met een `Info.plist` en een uitvoerbaar bestand, en auto-start kan ook via een LaunchAgent in plaats van `SMAppService`.

## Open beslissingen
2. **Invoegen bij de cursor: `CGEvent`-toetsaanslagen of pasteboard + Cmd-V.** Toetsaanslagen laten het plakbord met rust maar zijn traag bij lange tekst; plakken is direct maar overschrijft wat de gebruiker gekopieerd had. Bepaalt mede welke permissie R9 moet vragen.
3. **Wat "afgeronde uiting" is in hands-free.** Stiltedrempel in seconden, en of die instelbaar moet zijn. SpeechButton gebruikt 3 s voor auto-enter.
4. **Model-download bij eerste start.** Het model is ~2,5 GB. Meeleveren kan niet; ophalen bij eerste start is de enige netwerkafhankelijkheid die de app heeft en moet als zodanig gepresenteerd worden.

## Definition of done

- Menubalk-app start mee met inloggen, zonder Dock-icoon.
- Hands-free en auto-enter zijn los te schakelen met een hotkey vanuit elke app, en de staat is afleesbaar zonder het menu te openen.
- Gesproken tekst verschijnt bij de cursor in minstens drie verschillende apps (browser, terminal, editor), met het eerste woord compleet.
- CLI-modus schrijft hetzelfde transcript naar stdout en is in een pipe te gebruiken.
- Microfoon is te kiezen, de keuze overleeft een herstart, en loskoppelen geeft een melding in plaats van stilte.
- Transcriberen werkt met het netwerk uit.
- R10 is af of expliciet geschrapt; niet half.
