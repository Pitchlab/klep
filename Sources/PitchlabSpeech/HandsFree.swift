/// Hands-free-bedrading: de lijm die audio-invoer, transcriptie, tekstuitvoer en de
/// luister-indicator aaneenknoopt tot één lopende keten. Tot deze taak riep de app
/// geen enkel onderdeel aan; hands-free aanzetten flipte alleen een boolean. Hier
/// wordt de keten echt gelegd.
///
/// Alle randen zijn protocollen zodat de keten met stubs te bewijzen is zonder
/// microfoon, model of Accessibility (de gate draait headless): een uiting erin
/// geeft tekst bij de uitvoerlaag, de indicator is zichtbaar tijdens het luisteren,
/// en een Return volgt alleen als auto-enter aan staat.
///  - `HandsFreeAudioSource` levert `HandsFreeEvent`s: niveaus voor de indicator en
///    afgeronde uitingen voor de transcriptie.
///  - `UtteranceTranscribing` houdt het model warm en transcribeert één uiting.
///  - `TranscriptEmitting` stuurt de tekst naar de bestemming(en), met of zonder Return.
///
/// De productie-implementaties (`MicrophoneCapture`, `WarmTranscriber`,
/// `TextOutputSink`) hangen de echte AVFoundation/FluidAudio/CGEvent-lagen eronder;
/// hun runtime is een mensentest, de bedrading zelf draait in de gate.

import Foundation

// MARK: - Audio-events

/// Wat een audiobron tijdens hands-free levert: het live niveau voor de indicator,
/// of een afgeronde uiting om te transcriberen.
public enum HandsFreeEvent: Sendable, Equatable {
    case level(Float)
    case utterance(Utterance)
}

// MARK: - Randen (injecteerbaar)

/// Bron van hands-free-audio. Start opnemen en levert niveaus + uitingen als één
/// stroom; stoppen sluit de stroom. Protocol zodat de tests een stub injecteren.
public protocol HandsFreeAudioSource: Sendable {
    /// Start opnemen op `device` (nil = systeemstandaard) en geef de eventstroom terug.
    func start(device: DeviceInfo?) throws -> AsyncStream<HandsFreeEvent>
    /// Stop opnemen; sluit de stroom (een uiting die nog liep wordt afgesloten).
    func stop() async
}

/// Transcribeert één uiting en houdt het model warm. Protocol zodat de tests een
/// stub injecteren die de load-teller volgt (warm blijven, niet per uiting laden).
public protocol UtteranceTranscribing: Sendable {
    /// Laad het model eenmalig. Idempotent: een tweede aanroep is een no-op.
    func warmUp() async throws
    /// Transcribeer één afgeronde uiting naar tekst.
    func transcribe(_ utterance: Utterance) async throws -> String
}

/// Stuurt een transcript naar de bestemming(en). `autoEnter` bepaalt of er na de
/// tekst een Return volgt. Protocol zodat de tests een recorder injecteren.
public protocol TranscriptEmitting: Sendable {
    func emit(_ text: String, autoEnter: Bool) throws
}

// MARK: - Coördinator

/// Knoopt de keten aaneen en draait hem. `run` warmt het model één keer, toont de
/// indicator, en verwerkt elke event: niveaus voeden de indicator, uitingen worden
/// getranscribeerd en (niet-leeg) naar de uitvoerlaag gestuurd. Een fout bij de
/// uitvoer (bv. ontbrekende Accessibility) valt niet stil: hij wordt bewaard in
/// `lastError` en via `onError` gemeld, en het luisteren loopt door.
public actor HandsFreeController {
    private let audio: HandsFreeAudioSource
    private let transcriber: UtteranceTranscribing
    private let sink: TranscriptEmitting
    private let indicator: ListeningIndicating
    /// Live gelezen zodat auto-enter mid-sessie aan/uit kan zonder herstart.
    private let autoEnter: @Sendable () -> Bool

    /// Draait de keten nu.
    public private(set) var isListening = false
    /// De laatste fout die de uitvoerlaag gaf, of nil. Voor het menu (geen stil falen).
    public private(set) var lastError: String?
    /// Gemeld bij een uitvoerfout, zodat de AppKit-laag het menu kan bijwerken.
    public var onError: (@Sendable (String) -> Void)?

    public init(
        audio: HandsFreeAudioSource,
        transcriber: UtteranceTranscribing,
        sink: TranscriptEmitting,
        indicator: ListeningIndicating,
        autoEnter: @escaping @Sendable () -> Bool
    ) {
        self.audio = audio
        self.transcriber = transcriber
        self.sink = sink
        self.indicator = indicator
        self.autoEnter = autoEnter
    }

    public func setOnError(_ handler: (@Sendable (String) -> Void)?) {
        onError = handler
    }

    /// Draai de keten tot de audiostroom sluit (hands-free uit → `stop()`), of tot
    /// de bron niet kon starten. Warmt het model één keer vóór de eerste uiting, dus
    /// niet per uiting. Toont de indicator zolang het loopt en verbergt hem daarna.
    public func run(device: DeviceInfo?) async {
        indicator.show()
        isListening = true
        defer {
            isListening = false
            indicator.hide()
        }
        do {
            try await transcriber.warmUp()
            let events = try audio.start(device: device)
            for await event in events {
                switch event {
                case .level(let level):
                    indicator.update(level: level)
                case .utterance(let utterance):
                    await handle(utterance)
                }
            }
        } catch {
            report(error)
        }
    }

    /// Vraag de audiobron te stoppen; dat sluit de stroom en laat `run` terugkeren.
    public func requestStop() async {
        await audio.stop()
    }

    private func handle(_ utterance: Utterance) async {
        do {
            let text = try await transcriber.transcribe(utterance)
            guard !text.isEmpty else { return }
            try sink.emit(text, autoEnter: autoEnter())
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        let message = String(describing: error)
        lastError = message
        onError?(message)
    }
}

// MARK: - Productie-adapters

/// Productie-transcriber: schrijft de samples van een uiting naar een tijdelijke
/// 16 kHz mono wav — de vorm die de bewezen `Transcriber` verwacht — en laat die
/// transcriberen. Het model blijft warm in de onderliggende actor.
public struct WarmTranscriber: UtteranceTranscribing {
    private let transcriber: Transcriber

    public init(_ transcriber: Transcriber = Transcriber()) {
        self.transcriber = transcriber
    }

    public func warmUp() async throws {
        try await transcriber.warmUp()
    }

    public func transcribe(_ utterance: Utterance) async throws -> String {
        let url = try Pipeline.writeTemporaryWav(utterance.samples)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await transcriber.transcribe(url)
    }
}

/// Productie-uitvoer: stuurt de tekst via `TextOutput` naar cursor + stdout en, als
/// auto-enter aan staat, een Return erachteraan. Ontbrekende Accessibility geeft een
/// `TextOutputError`, geen stille mislukking — de `HandsFreeController` vangt hem en
/// meldt hem in het menu.
public struct TextOutputSink: TranscriptEmitting {
    private let output: TextOutput
    private let destinations: TextDestinations

    public init(output: TextOutput = TextOutput(), to destinations: TextDestinations = .both) {
        self.output = output
        self.destinations = destinations
    }

    public func emit(_ text: String, autoEnter: Bool) throws {
        try output.emit(text, to: destinations, pressReturn: autoEnter)
    }
}
