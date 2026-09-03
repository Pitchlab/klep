import Foundation
@testable import Klep

/// Foundation-hulp voor de microfoontoestemmingstests. Los van het testbestand omdat
/// `import Testing` samen met `import Foundation` in één bestand de cross-import overlay
/// `_Testing_Foundation` triggert, die ontbreekt in de CLT-only toolchain (zie
/// `Fixtures.swift`). De stubs bewijzen de gate zonder echte TCC: een geïnjecteerde
/// toestemmingsstand bepaalt of de keten start en of de audiobron wordt aangesproken.
enum MicrophonePermissionTestSupport {

    // MARK: - Stubs (injecteerbare randen)

    /// Toestemmingsstub: vaste status, telbare `requestAccess`, met een instelbaar
    /// antwoord op de prompt zodat de `.notDetermined`-tak beide kanten op te testen is.
    final class StubPermission: MicrophonePermission, @unchecked Sendable {
        private let lock = NSLock()
        private let status: MicrophoneAuthorization
        private let grantOnRequest: Bool
        private var _requestCount = 0

        init(status: MicrophoneAuthorization, grantOnRequest: Bool = false) {
            self.status = status
            self.grantOnRequest = grantOnRequest
        }

        var requestCount: Int { lock.withLock { _requestCount } }

        func authorizationStatus() -> MicrophoneAuthorization { status }

        func requestAccess() async -> Bool {
            lock.withLock { _requestCount += 1 }
            return grantOnRequest
        }
    }

    /// Audiobron-spy: onthoudt of `start` is aangeroepen en levert daarna een lege,
    /// meteen gesloten stroom zodat `run` deterministisch terugkeert.
    final class SpyAudioSource: HandsFreeAudioSource, @unchecked Sendable {
        private let lock = NSLock()
        private var _startCalled = false

        var startCalled: Bool { lock.withLock { _startCalled } }

        func start(device: DeviceInfo?) throws -> AsyncStream<HandsFreeEvent> {
            lock.withLock { _startCalled = true }
            return AsyncStream { $0.finish() }
        }

        func stop() async {}
    }

    /// No-op transcriber en uitvoerlaag: de gate-tests raken deze niet, maar de keten
    /// heeft ze nodig om samengesteld te worden.
    struct NoopTranscriber: UtteranceTranscribing {
        func warmUp() async throws {}
        func transcribe(_ utterance: Utterance) async throws -> String { "" }
    }

    struct NoopSink: TranscriptEmitting {
        func emit(_ text: String, autoEnter: Bool) throws {}
        func emitReturn() throws {}
    }

    // MARK: - Driver

    /// Wat één gate-run opleverde.
    struct GateResult {
        let started: Bool
        let audioStarted: Bool
        let requestCount: Int
        let lastError: String?
        let indicatorShowCount: Int
    }

    /// Draait `HandsFreeController.run` met een geïnjecteerde toestemmingsstub en meet
    /// of de keten startte, of de audiobron werd aangesproken, of de prompt werd
    /// aangevraagd, en of er een melding kwam.
    static func runGate(
        status: MicrophoneAuthorization,
        grantOnRequest: Bool = false
    ) async -> GateResult {
        let audio = SpyAudioSource()
        let permission = StubPermission(status: status, grantOnRequest: grantOnRequest)
        let indicator = ListeningIndicator()
        let controller = HandsFreeController(
            audio: audio,
            transcriber: NoopTranscriber(),
            sink: NoopSink(),
            indicator: indicator,
            permission: permission,
            autoEnter: { false })
        let started = await controller.run(device: nil)
        return GateResult(
            started: started,
            audioStarted: audio.startCalled,
            requestCount: permission.requestCount,
            lastError: await controller.lastError,
            indicatorShowCount: indicator.showCount)
    }

    /// Draait alleen de beslissingslogica van de toestemmingslaag (`ensureAccess`) op
    /// een geïnjecteerde stand, los van de keten.
    static func outcome(
        status: MicrophoneAuthorization,
        grantOnRequest: Bool = false
    ) async -> MicrophonePermissionOutcome {
        await StubPermission(status: status, grantOnRequest: grantOnRequest).ensureAccess()
    }
}
