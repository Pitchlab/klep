import Testing
@testable import Klep

/// Tests voor de audio-invoer (PL-701). Importeert bewust géén Foundation: de
/// fixture-samples en de transcriptie komen uit `AudioTestSupport`, zodat de
/// cross-import overlay `_Testing_Foundation` niet getriggerd wordt (zie dat bestand).

// MARK: - Microfoonkeuze, bewaren en terugval (R6)

@Suite struct MicrophoneSelectionTests {
    private func selector(
        devices: [DeviceInfo], systemDefault: DeviceInfo?, store: AudioTestSupport.MemoryStore
    ) -> MicrophoneSelector {
        MicrophoneSelector(
            enumerator: AudioTestSupport.FakeEnumerator(devices: devices, systemDefault: systemDefault),
            store: store)
    }

    @Test func usesSystemDefaultWhenNothingSelected() {
        let store = AudioTestSupport.MemoryStore()
        let sut = selector(
            devices: [AudioTestSupport.deviceA, AudioTestSupport.deviceB],
            systemDefault: AudioTestSupport.deviceA, store: store)

        let resolution = sut.resolve()
        #expect(resolution.device == AudioTestSupport.deviceA)
        #expect(resolution.notice == nil)
    }

    @Test func persistedSelectionSurvivesReload() {
        let store = AudioTestSupport.MemoryStore()
        selector(
            devices: [AudioTestSupport.deviceA, AudioTestSupport.deviceB],
            systemDefault: AudioTestSupport.deviceA, store: store)
            .select(AudioTestSupport.deviceB)

        // Verse selector op dezelfde store = zelfde app na een herstart.
        let afterRestart = selector(
            devices: [AudioTestSupport.deviceA, AudioTestSupport.deviceB],
            systemDefault: AudioTestSupport.deviceA, store: store)
        #expect(afterRestart.selectedDeviceID == AudioTestSupport.deviceB.uniqueID)
        #expect(afterRestart.resolve().device == AudioTestSupport.deviceB)
        #expect(afterRestart.resolve().notice == nil)
    }

    @Test func fallsBackWithNoticeWhenSelectedDeviceGone() {
        let store = AudioTestSupport.MemoryStore()
        selector(
            devices: [AudioTestSupport.deviceA, AudioTestSupport.deviceB],
            systemDefault: AudioTestSupport.deviceA, store: store)
            .select(AudioTestSupport.deviceB)

        // deviceB losgekoppeld: alleen A is er nog, A is de systeemstandaard.
        let afterUnplug = selector(
            devices: [AudioTestSupport.deviceA],
            systemDefault: AudioTestSupport.deviceA, store: store)
        let resolution = afterUnplug.resolve()
        #expect(resolution.device == AudioTestSupport.deviceA)
        #expect(resolution.notice == .selectedDeviceUnavailable(
            selectedID: AudioTestSupport.deviceB.uniqueID, fellBackTo: AudioTestSupport.deviceA))
    }
}

// MARK: - Rolling pre-roll (R8)

@Suite struct PreRollBufferTests {
    @Test func retainsMostRecentSamplesUpToCapacity() {
        var buffer = PreRollBuffer(capacity: 4)
        buffer.append([1, 2, 3])
        buffer.append([4, 5, 6])
        #expect(buffer.snapshot() == [3, 4, 5, 6])
        #expect(buffer.count == 4)
    }

    @Test func emptyUntilFed() {
        let buffer = PreRollBuffer(capacity: 8)
        #expect(buffer.snapshot().isEmpty)
        #expect(buffer.count == 0)
    }

    @Test func secondsInitializerSizesToSampleRate() {
        var buffer = PreRollBuffer(seconds: 0.3, sampleRate: 16_000)
        #expect(buffer.capacity == 4_800)
        buffer.append(Array(repeating: 0.5, count: 5_000))
        #expect(buffer.count == 4_800)
    }
}

// MARK: - Uiting-segmentatie via FluidAudio-VAD

@Suite struct UtteranceSegmentationTests {
    /// De VAD vindt begin en eind van de fixture-uiting. Draait offline zodra het
    /// VAD-model in de FluidAudio-cache staat.
    @Test func segmentsFixtureIntoAtLeastOneUtterance() async throws {
        let samples = AudioTestSupport.dutchSamples()
        #expect(samples.count > 16_000)  // ruim een seconde spraak

        let segmenter = UtteranceSegmenter(preRollSeconds: 0.3)
        var utterances = try await segmenter.feed(samples)
        if let tail = try await segmenter.finish() { utterances.append(tail) }

        #expect(!utterances.isEmpty)
        let captured = utterances.reduce(0) { $0 + $1.sampleCount }
        // Minstens de helft van de spraak is als uiting teruggekomen.
        #expect(captured >= samples.count / 2)
    }

    /// Een gesegmenteerde uiting behoudt het eerste én laatste woord: pre-roll kapt
    /// de kop niet af (R8) en de VAD sluit pas na het laatste woord af.
    @Test func capturedUtteranceKeepsFirstAndLastWord() async throws {
        let samples = AudioTestSupport.dutchSamples()
        let segmenter = UtteranceSegmenter(preRollSeconds: 0.3)
        var utterances = try await segmenter.feed(samples)
        if let tail = try await segmenter.finish() { utterances.append(tail) }
        #expect(!utterances.isEmpty)

        let joined = utterances.flatMap { $0.samples }
        let text = try await AudioTestSupport.transcribe(joined).lowercased()
        #expect(text.contains("zet"))     // eerste woord, bewijst pre-roll
        #expect(text.contains("cursor"))  // laatste woord, bewijst het eind
    }
}
