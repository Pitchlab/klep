import Foundation
@testable import PitchlabSpeech

/// Foundation-hulp voor `DiagnosticsTests`. Los van het testbestand omdat `import
/// Testing` samen met `import Foundation` in één bestand de cross-import overlay
/// `_Testing_Foundation` triggert, die ontbreekt in de CLT-only toolchain (zie
/// `Fixtures.swift`). Levert een spy-afvoer, een tijdelijk logbestand en een driver die
/// de echte `HandsFreeController` door één uiting laat lopen, zodat de gate de bedrading
/// meet zonder microfoon of `~/.pitchlab` aan te raken.
enum DiagnosticsTestSupport {

    // MARK: - Spy-afvoer

    /// Onthoudt elke gelogde gebeurtenis in volgorde, threadveilig zodat de actor-keten
    /// er vanuit meerdere contexten in mag schrijven.
    final class SpySink: DiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [DiagnosticEvent] = []

        var events: [DiagnosticEvent] { lock.withLock { _events } }

        func log(_ event: DiagnosticEvent) {
            lock.withLock { _events.append(event) }
        }
    }

    // MARK: - Ketenstubs

    /// Audiobron die eerst een niveau en dan één afgeronde uiting levert, en daarna de
    /// stroom sluit zodat `run` deterministisch terugkeert.
    final class OneUtteranceAudio: HandsFreeAudioSource, @unchecked Sendable {
        let utterance: Utterance
        init(utterance: Utterance) { self.utterance = utterance }

        func start(device: DeviceInfo?) throws -> AsyncStream<HandsFreeEvent> {
            let utterance = self.utterance
            return AsyncStream { continuation in
                continuation.yield(.level(0.5))
                continuation.yield(.utterance(utterance))
                continuation.finish()
            }
        }

        func stop() async {}
    }

    /// Transcriber die een vaste tekst teruggeeft, zodat de lengte-logregel meetbaar is.
    struct FixedTranscriber: UtteranceTranscribing {
        let text: String
        func warmUp() async throws {}
        func transcribe(_ utterance: Utterance) async throws -> String { text }
    }

    /// Uitvoerlaag die slaagt (of gooit, om de mislukt-route te meten).
    struct FixedSink: TranscriptEmitting {
        let error: Error?
        func emit(_ text: String, autoEnter: Bool) throws {
            if let error { throw error }
        }
    }

    /// Toestemmingsstub: vaste stand, geen echte TCC.
    struct FixedPermission: MicrophonePermission {
        let status: MicrophoneAuthorization
        func authorizationStatus() -> MicrophoneAuthorization { status }
        func requestAccess() async -> Bool { false }
    }

    // MARK: - Drivers

    /// Draait de echte `HandsFreeController` door één uiting op een geïnjecteerde
    /// spy-afvoer en geeft de gelogde gebeurtenissen in volgorde terug. `emitFails`
    /// schakelt de uitvoer naar de mislukt-route.
    static func chainEvents(
        transcript: String = "hallo daar",
        emitFails: Bool = false,
        status: MicrophoneAuthorization = .authorized
    ) async -> [DiagnosticEvent] {
        let spy = SpySink()
        let audio = OneUtteranceAudio(
            utterance: Utterance(samples: [Float](repeating: 0, count: 3200)))  // 200 ms
        let sinkError: Error? = emitFails ? TextOutputError.accessibilityNotAuthorized : nil
        let controller = HandsFreeController(
            audio: audio,
            transcriber: FixedTranscriber(text: transcript),
            sink: FixedSink(error: sinkError),
            indicator: ListeningIndicator(),
            permission: FixedPermission(status: status),
            diagnostics: spy,
            autoEnter: { false })
        _ = await controller.run(device: nil)
        return spy.events
    }

    // MARK: - Logbestand op schijf

    /// Een tijdelijk logbestand, uniek per aanroep zodat parallelle tests elkaar niet raken.
    static func tempLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("klep-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("klep.log")
    }

    /// Logt de gebeurtenissen naar een vers tijdelijk bestand en geeft de inhoud terug.
    static func writeAndRead(
        _ events: [DiagnosticEvent], maxBytes: Int = 512_000
    ) -> String {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = DiagnosticLog(fileURL: url, maxBytes: maxBytes, mirrorToStderr: false)
        for event in events { log.log(event) }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Wat na een rotatie op schijf staat: het aantal regels in het huidige bestand en of
    /// het geroteerde `.1`-bestand bestaat.
    struct RotationResult {
        let currentLineCount: Int
        let rotatedExists: Bool
    }

    /// Logt genoeg regels om de `maxBytes`-drempel te overschrijden en meet de rotatie:
    /// het huidige bestand is dan afgekapt (weinig regels) en `.1` bestaat.
    static func rotate(lineCount: Int, maxBytes: Int) -> RotationResult {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = DiagnosticLog(fileURL: url, maxBytes: maxBytes, mirrorToStderr: false)
        for i in 0..<lineCount {
            log.log(.failure(origin: "test", message: "regel \(i)"))
        }
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = current.split(separator: "\n", omittingEmptySubsequences: true).count
        let rotated = FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path)
        return RotationResult(currentLineCount: lines, rotatedExists: rotated)
    }
}
