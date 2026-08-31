# pitchlab-speech

Lokale dicteer-app voor macOS (Apple Silicon), vervanger van SpeechButton. Spraak → tekst bij de cursor, aangestuurd vanaf het toetsenbord, STT lokaal via Parakeet (FluidAudio/CoreML). Geen server, geen cloud, geen account. Scope en requirements: `docs/prd.md`.

Puur Swift, SwiftPM. **Command Line Tools only — Xcode is niet geïnstalleerd en komt er niet** (`docs/prd.md`, spike PL-715).

## Bouwen en testen (de gate)

```
make gate        # = make build + make test
```

of los:

```
make build       # swift build -c release
make test        # swift test met de framework-flag (zie hieronder)
```

`make gate` is de minimale check voor elke vervolgtaak.

### Waarom niet kaal `swift test`

`swift test` zónder flag draait op een CLT-only Mac **geen** tests. XCTest ontbreekt volledig in de Command Line Tools; alleen Swift Testing (`Testing.framework`) is aanwezig, en die staat niet op het standaard framework-zoekpad. Zonder `-F` bouwt SwiftPM de test-bundle, kan `swiftpm-testing-helper` `Testing.framework` niet laden, en eindigt het commando met exit 0 terwijl er nul tests draaien — een false green.

De werkende vorm is:

```
swift test -Xswiftc -F -Xswiftc "$(xcode-select -p)/Library/Developer/Frameworks"
```

De runtime-rpath naar dat pad zit in `Package.swift` (op het test-target). `make test` bundelt deze aanroep zodat vervolgtaken één stabiel commando hebben.

## Installeren

```
./scripts/build-app.sh                    # bouwt en signeert .build/PitchlabSpeech.app
cp -R .build/PitchlabSpeech.app /Applications/
```

Eerste keer starten vraagt macOS om Microfoon, Toegankelijkheid en Invoerbewaking. Geef die één keer via Systeeminstellingen → Privacy en beveiliging.

### Waarom een herbouw je toestemming kan resetten

macOS TCC koppelt die toestemmingen aan de *designated requirement* van de app-code, niet aan het pad. Bij **ad-hoc** signeren (identiteit `-`) is die requirement de exacte CDHash, en die verandert bij elke build — dus elke herinstallatie is voor macOS een nieuwe app en je moet Microfoon, Toegankelijkheid en Invoerbewaking opnieuw geven.

`build-app.sh` signeert daarom met een **stabiele self-signed identiteit** uit de keychain (standaard `PitchLab Local Code Signing`). Dan is de requirement `identifier "nl.pitchlab.speech" and certificate root = H"…"` — gelijk over builds zolang bundle-id en certificaat gelijk blijven. De CDHash verandert nog steeds per build, maar de toestemming blijft geldig. Het script meldt na afloop de CDHash, of die veranderd is, en of je iets opnieuw moet geven.

Een echte Developer ID zou hetzelfde geven zonder handmatige keychain-stap, maar die is er niet en is buiten scope; self-signed is de minste wrijving voor lokaal gebruik.

### De stabiele identiteit aanmaken (eenmalig, als die ontbreekt)

Bestaat `PitchLab Local Code Signing` nog niet in je login-keychain, dan valt het script terug op ad-hoc en waarschuwt het. Maak de identiteit dan aan via **Keychain Access → Certificate Assistant → Create a Certificate…**: naam `PitchLab Local Code Signing`, Identity Type *Self-Signed Root*, Certificate Type *Code Signing*. Daarna vindt `build-app.sh` de identiteit automatisch. Override met `PITCHLAB_SIGN_IDENTITY=<naam>` als je een andere identiteit wilt.

## Structuur

- `Package.swift` — SwiftPM-manifest, target `PitchlabSpeech` (library) + `PitchlabSpeechTests`.
- `Sources/PitchlabSpeech/` — de library. Nu alleen een scaffold-symbool.
- `Tests/PitchlabSpeechTests/` — Swift Testing smoke-test.
- `docs/prd.md` — PRD, requirements, spikes.
