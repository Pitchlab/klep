import Testing
@testable import PitchlabSpeech

/// Integratietest voor de end-to-end pipeline (PL-705). Draait `Pipeline.runOnce`
/// op de fixture-wav — dezelfde route als `pitchlab-speech --once` — en controleert
/// dat het transcript op de gevraagde bestemming(en) terechtkomt. Draait offline
/// zodra het Parakeet-model in de FluidAudio-cache staat, zonder microfoon of
/// Accessibility (de cursor-laag is geïnjecteerd).
///
/// Importeert bewust géén Foundation: fixture, stubs en captures komen uit
/// `PipelineTestSupport` (zie `Fixtures.swift` voor de reden).
@Suite struct PipelineTests {

    /// De stdout-route: het transcript van de fixture bevat "cursor". Dit is exact
    /// wat de CLI-gate op stdout greept.
    @Test func runOnceWritesTranscriptToStdout() async throws {
        let capture = try await PipelineTestSupport.runOnceFixture(to: .standardOutput)
        #expect(capture.stdout.lowercased().contains("cursor"))
        #expect(capture.returned == capture.stdout)
        #expect(capture.cursor.isEmpty)  // cursor-route niet gevraagd
    }

    /// Beide bestemmingen tegelijk: hetzelfde transcript gaat naar stdout én naar de
    /// (geïnjecteerde) cursor-laag. Bewijst dat de pipeline `TextOutput` op beide
    /// routes voedt.
    @Test func runOnceFeedsBothDestinations() async throws {
        let capture = try await PipelineTestSupport.runOnceFixture(to: .both, authorized: true)
        #expect(capture.stdout.lowercased().contains("cursor"))
        #expect(capture.cursor.count == 1)
        #expect(capture.cursor.first == capture.returned)
    }

    /// Zonder Accessibility gooit de cursor-route expliciet, nooit stil falen — maar
    /// stdout is dan al geschreven (stdout gaat eerst en heeft geen toestemming nodig).
    @Test func runOnceThrowsWhenCursorUnauthorized() async throws {
        await #expect(throws: TextOutputError.accessibilityNotAuthorized) {
            _ = try await PipelineTestSupport.runOnceFixture(to: .both, authorized: false)
        }
    }
}
