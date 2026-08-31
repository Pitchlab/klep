import Testing
@testable import PitchlabSpeech

/// Integratietest voor de STT-core. Transcribeert de Nederlandse fixture uit
/// spike PL-715 en controleert dat er herkenbare tekst uitkomt. Draait offline
/// zodra het Parakeet-model in de FluidAudio-cache staat.
///
/// Dit bestand importeert bewust géén Foundation (zie `Fixtures.swift`): de
/// fixture-URL komt uit `Fixtures` en wordt hier alleen doorgegeven, nooit bij
/// type genoemd.
@Suite struct TranscriberTests {
    @Test func transcribesDutchFixture() async throws {
        let transcriber = Transcriber()
        let text = try await transcriber.transcribe(Fixtures.dutchUtterance)
        #expect(text.lowercased().contains("cursor"))
        #expect(text.lowercased().contains("modus"))
    }

    @Test func staysWarmAcrossUtterances() async throws {
        let transcriber = Transcriber()
        try await transcriber.warmUp()
        #expect(await transcriber.isWarm)

        // Tweede uiting hergebruikt het warme model; beide leveren dezelfde tekst.
        let first = try await transcriber.transcribe(Fixtures.dutchUtterance)
        let second = try await transcriber.transcribe(Fixtures.dutchUtterance)
        #expect(!first.isEmpty)
        #expect(first == second)
    }
}
