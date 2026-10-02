# Spike: draait Parakeet native in Swift?

Experiment voor de taalkeuze: geen Python in de app. Vraag: kan de app puur Swift zijn, of blijft Python als backend nodig?

**Conclusie: ja, puur Swift werkt.** FluidAudio resolvet als SwiftPM-dependency, compileert met alleen Command Line Tools, laadt het Parakeet TDT 0.6b v3 CoreML-model en transcribeert een Nederlandse fixture correct. Op alle gemeten assen (koude start, warme transcriptie, piek-geheugen) is Swift+CoreML beter dan de Python/MLX-baseline. Python is niet nodig.

Dit is een wegwerp-spike, geen productiecode.

## Opzet

- Spike-project: `spikes/swift-parakeet/` — SwiftPM executable `parakeet-spike`.
- Toolchain: Apple Swift 6.2.4, `xcode-select -p` = `/Library/Developer/CommandLineTools`. **Xcode is niet geïnstalleerd.** Build via `swift build -c release`.
- Machine: Apple Silicon, macOS 26.
- Fixture: `say -v Xander -o f.aiff 'Zet hands free modus aan en typ dit bij de cursor.'` → ffmpeg naar 16 kHz mono PCM wav (`fixture.wav`, 2.59 s).

## Wat bewezen is

**1. FluidAudio resolvet + compileert met alleen Command Line Tools.**
`.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")` resolvet naar **0.15.6**. `swift build -c release` slaagt (114 s eerste build, cold cache). Geen Xcode nodig.

Kanttekening: FluidAudio 0.15.6 trekt een binair artifact `NemoTextProcessing.xcframework` (Rust, `text-processing-rs` v0.3.0) voor inverse text normalization. SwiftPM haalt dat automatisch bij resolve; het zit als prebuilt xcframework in de package, dus geen Rust-toolchain nodig.

**2. Het Parakeet TDT 0.6b v3 CoreML-model laadt.**
Model-repo `FluidInference/parakeet-tdt-0.6b-v3-coreml`, gedownload naar `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/`. Vier CoreML `.mlmodelc`-bundles + vocab:

| Component | Grootte |
|---|---|
| Encoder.mlmodelc (int8) | 425 MB |
| Decoder.mlmodelc | 23 MB |
| JointDecision(v3).mlmodelc | 2× 12 MB |
| Preprocessor.mlmodelc | 0.5 MB |
| vocab json | 2× 148 KB |
| **totaal op schijf** | **473 MB** |

**3. Nederlandse fixture → herkenbare tekst.**
Input: "Zet hands free modus aan en typ dit bij de cursor."
Output: `Zet handsfree modus aan en typ dit bij de cursor.`
Correct (ITN plakt "handsfree" aaneen). De CHECK grep't op `cursor` en slaagt.

**4. Offline na eenmalige download.**
Tweede run laadt in 0.24 s zonder netwerk (download zou seconden kosten; `AsrModels.modelsExist` short-circuit't de netwerkpad). Run met dode HTTPS-proxy (`HTTPS_PROXY=http://127.0.0.1:1`) transcribeert ongestoord. Alleen de eerste model-download heeft netwerk nodig.

## Meetwaarden (2.59 s audio, Apple Silicon)

Koude start = procesopstart tot eerste transcript, met model al in cache (eerlijke vergelijking met de Python-cijfers, die ook een gecachet model gebruikten).

| Metriek | Swift + CoreML (FluidAudio) | Python + MLX (baseline) |
|---|---|---|
| Koude start (cache warm) | **0.39 s** | 9.5 s |
| Warme transcriptie | **0.12 s** | 0.14 s (op 2.6 s audio) |
| Model-load (van schijf) | 0.26 s | — |
| Piek-RSS | **80 MB** | 1.35 GB |
| Model op schijf | 473 MB | — |

Piek-geheugen via `getrusage(RUSAGE_SELF).ru_maxrss` — zelfde formule als de Python-spike.

De koude start is ~24× sneller en het piek-geheugen ~17× lager. De warme transcriptie is vergelijkbaar (0.12 vs 0.14 s). Swift+CoreML wint op elke gemeten as; er is geen meetwaarde die richting Python wijst.

## Wat NIET bewezen is

- **Streaming.** Alleen batch-transcriptie van een heel bestand gemeten. FluidAudio heeft een streaming-API (`StreamingUnifiedAsrManager`), maar de per-chunk latency onder realtime is hier niet getest. De Python-spike deed dat wel (streaming chunk-latency). Voor hands-free dictaat is dit de volgende te bewijzen as.
- **Clean cold-download-tijd.** De eerste run downloadde slechts het ontbrekende `JointDecisionv3.mlmodelc`; de rest zat al in de cache van een eerdere poging. De 54 s van die run is dus geen schone volledige-download-meting. De download is eenmalig en niet relevant voor de runtime-vraag.
- **Langere / ruisige / accent-audio.** Eén schone TTS-fixture van 2.6 s. Geen WER-meting, geen echte spraak, geen achtergrondgeluid.
- **mweinbach/parakeet-coreml-swift** is niet geprobeerd — niet nodig, FluidAudio slaagde meteen.
- **Xcode-project-integratie.** Alleen SwiftPM CLI-build getest, niet inbedding in een .app-bundle met signing/entitlements.

## Reproduceren

```bash
cd pitchlab-speech/spikes/swift-parakeet
swift build -c release
./.build/release/parakeet-spike fixture.wav
```

Eerste run downloadt het model (netwerk, ~473 MB); daarna offline.
