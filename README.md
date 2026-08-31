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

## Structuur

- `Package.swift` — SwiftPM-manifest, target `PitchlabSpeech` (library) + `PitchlabSpeechTests`.
- `Sources/PitchlabSpeech/` — de library. Nu alleen een scaffold-symbool.
- `Tests/PitchlabSpeechTests/` — Swift Testing smoke-test.
- `docs/prd.md` — PRD, requirements, spikes.
