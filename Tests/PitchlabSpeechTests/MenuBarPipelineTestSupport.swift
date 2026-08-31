import Foundation
@testable import PitchlabSpeech

/// Foundation-hulp voor de hands-free-bedradingstests. Los van het testbestand omdat
/// `import Testing` samen met `import Foundation` in één bestand de cross-import
/// overlay `_Testing_Foundation` triggert, die ontbreekt in de CLT-only toolchain
/// (zie `Fixtures.swift`). De stubs bewijzen de keten zonder microfoon, model of
/// Accessibility: een uiting erin geeft tekst bij de uitvoerlaag, de indicator is
/// zichtbaar tijdens het luisteren, en een Return volgt alleen bij auto-enter aan.
enum MenuBarPipelineTestSupport {

    // MARK: - Stubs (injecteerbare randen)

    /// Audiobron-stub: levert vooraf bepaalde events en sluit dan de stroom, zodat
    /// `HandsFreeController.run` deterministisch tot het einde loopt.
    struct StubAudioSource: HandsFreeAudioSource {
        let events: [HandsFreeEvent]
        func start(device: DeviceInfo?) throws -> AsyncStream<HandsFreeEvent> {
            AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
        func stop() async {}
    }

    /// Transcriber-stub: telt hoe vaak geladen en getranscribeerd wordt. Een uiting
    /// zonder samples (stilte) geeft lege tekst, zodat de skip-route te testen is.
    final class StubTranscriber: UtteranceTranscribing, @unchecked Sendable {
        private let lock = NSLock()
        private var _warmUps = 0
        private var _transcribes = 0
        let text: String

        init(text: String) { self.text = text }

        var warmUpCount: Int { lock.withLock { _warmUps } }
        var transcribeCount: Int { lock.withLock { _transcribes } }

        func warmUp() async throws { lock.withLock { _warmUps += 1 } }

        func transcribe(_ utterance: Utterance) async throws -> String {
            lock.withLock { _transcribes += 1 }
            return utterance.samples.isEmpty ? "" : text
        }
    }

    /// Uitvoer-recorder: onthoudt elke (tekst, auto-enter). Kan ook gooien, zodat de
    /// "ontbrekende Accessibility faalt niet stil"-route te testen is.
    final class RecordingSink: TranscriptEmitting, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(text: String, autoEnter: Bool)] = []
        let failWith: TextOutputError?

        init(failWith: TextOutputError? = nil) { self.failWith = failWith }

        var calls: [(text: String, autoEnter: Bool)] { lock.withLock { _calls } }

        func emit(_ text: String, autoEnter: Bool) throws {
            if let failWith { throw failWith }
            lock.withLock { _calls.append((text, autoEnter)) }
        }
    }

    /// Inserter die de invoegingen én de Returns telt, zonder echte toetsaanslagen
    /// (die vragen Accessibility — ROE §2). Bewijst dat een Return alleen bij
    /// auto-enter aan op de echte `TextOutput`-laag komt.
    final class ReturnRecordingInserter: KeystrokeInserter, @unchecked Sendable {
        let isAuthorized: Bool
        private let lock = NSLock()
        private var _inserted: [String] = []
        private var _returns = 0

        init(authorized: Bool = true) { self.isAuthorized = authorized }

        var inserted: [String] { lock.withLock { _inserted } }
        var returns: Int { lock.withLock { _returns } }

        func insert(_ text: String) throws {
            guard isAuthorized else { throw TextOutputError.accessibilityNotAuthorized }
            lock.withLock { _inserted.append(text) }
        }

        func insertReturn() throws {
            guard isAuthorized else { throw TextOutputError.accessibilityNotAuthorized }
            lock.withLock { _returns += 1 }
        }
    }

    /// Threadveilige verzamelaar voor de stdout-closure.
    private final class StdoutBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        var value: String { lock.withLock { buffer } }
        func append(_ text: String) { lock.withLock { buffer += text } }
    }

    // MARK: - Drivers

    /// Wat één hands-free-run door de stub-keten opleverde.
    struct WiringResult {
        let sinkCalls: [(text: String, autoEnter: Bool)]
        let warmUpCount: Int
        let transcribeCount: Int
        let indicatorShowCount: Int
        let indicatorHideCount: Int
        let levelsWhileVisible: [Float]
        let lastError: String?
        let isListeningAfter: Bool
    }

    /// Draait `HandsFreeController.run` op de stub-audiobron tot de stroom sluit en
    /// rapporteert wat de indicator, transcriber en uitvoerlaag zagen.
    static func runWiring(
        events: [HandsFreeEvent],
        transcript: String = "hallo wereld",
        autoEnter: Bool,
        sinkFailsWith: TextOutputError? = nil
    ) async -> WiringResult {
        let transcriber = StubTranscriber(text: transcript)
        let sink = RecordingSink(failWith: sinkFailsWith)
        let indicator = ListeningIndicator()
        let controller = HandsFreeController(
            audio: StubAudioSource(events: events),
            transcriber: transcriber,
            sink: sink,
            indicator: indicator,
            autoEnter: { autoEnter })
        await controller.run(device: nil)
        return WiringResult(
            sinkCalls: sink.calls,
            warmUpCount: transcriber.warmUpCount,
            transcribeCount: transcriber.transcribeCount,
            indicatorShowCount: indicator.showCount,
            indicatorHideCount: indicator.hideCount,
            levelsWhileVisible: indicator.levelsWhileVisible,
            lastError: await controller.lastError,
            isListeningAfter: await controller.isListening)
    }

    /// Bouwt een uiting-event uit samples.
    static func utterance(_ samples: [Float]) -> HandsFreeEvent {
        .utterance(Utterance(samples: samples))
    }

    /// Bouwt een niveau-event.
    static func level(_ value: Float) -> HandsFreeEvent { .level(value) }

    /// Wat de echte `TextOutput`-laag via `TextOutputSink` deed.
    struct OutputResult {
        let inserted: [String]
        let returns: Int
        let stdout: String
    }

    /// Stuurt één tekst door de echte `TextOutputSink` (cursor + stdout) met een
    /// geïnjecteerde inserter, zodat de Return-vlag op de echte laag te meten is.
    static func runTextOutputSink(text: String, autoEnter: Bool) throws -> OutputResult {
        let inserter = ReturnRecordingInserter(authorized: true)
        let box = StdoutBox()
        let output = TextOutput(inserter: inserter, writeStandardOutput: { box.append($0) })
        let sink = TextOutputSink(output: output, to: .both)
        try sink.emit(text, autoEnter: autoEnter)
        return OutputResult(inserted: inserter.inserted, returns: inserter.returns, stdout: box.value)
    }
}
