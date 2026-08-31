import Testing
@testable import PitchlabSpeech

/// Tests voor de luister-indicator. Alleen de pure model-laag: de vertaling
/// niveau→stip-grootte en de positie-persistentie. Het non-activating `NSPanel`
/// (`ListeningIndicatorController`) vraagt een runloop en is een mensentest (PRD, R7).
///
/// Dit bestand importeert bewust géén Foundation: `import Testing` + `import
/// Foundation` triggert de cross-import overlay `_Testing_Foundation`, waarvan de
/// module-interface ontbreekt in de CLT-only toolchain. Het `UserDefaults`-werk voor
/// de persistentie-test staat in `ListeningIndicatorTestSupport.swift`.
@Suite struct ListeningIndicatorTests {

    // MARK: - Audioniveau (RMS)

    @Test func silenceIsZeroLevel() {
        #expect(AudioLevel.rms(of: []).value == 0)
        #expect(AudioLevel.rms(of: [Float](repeating: 0, count: 512)).value == 0)
    }

    @Test func louderSamplesGiveAHigherLevel() {
        let quiet = AudioLevel.rms(of: [Float](repeating: 0.01, count: 512))
        let loud = AudioLevel.rms(of: [Float](repeating: 0.2, count: 512))
        #expect(loud.value > quiet.value)
    }

    @Test func levelIsClampedToOne() {
        let deafening = AudioLevel.rms(of: [Float](repeating: 1.0, count: 512))
        #expect(deafening.value == 1)
    }

    @Test func meterHoldsTheLastMeasuredLevel() {
        let meter = AudioLevelMeter()
        #expect(meter.currentLevel.value == 0)
        meter.ingest([Float](repeating: 0.2, count: 512))
        let afterLoud = meter.currentLevel.value
        #expect(afterLoud > 0)
        meter.reset()
        #expect(meter.currentLevel.value == 0)
    }

    // MARK: - Niveau → grootte

    @Test func silenceMapsToTheMinimumDiameter() {
        let model = ListeningIndicatorModel(minDiameter: 14, maxDiameter: 42)
        #expect(model.diameter(for: .silent) == 14)
    }

    @Test func fullLevelMapsToTheMaximumDiameter() {
        let model = ListeningIndicatorModel(minDiameter: 14, maxDiameter: 42)
        #expect(model.diameter(for: AudioLevel(1)) == 42)
    }

    @Test func halfLevelMapsToTheMidpoint() {
        let model = ListeningIndicatorModel(minDiameter: 10, maxDiameter: 50)
        #expect(model.diameter(for: AudioLevel(0.5)) == 30)
    }

    @Test func diameterGrowsMonotonicallyWithLevel() {
        let model = ListeningIndicatorModel()
        let small = model.diameter(for: AudioLevel(0.2))
        let large = model.diameter(for: AudioLevel(0.8))
        #expect(large > small)
    }

    // MARK: - Interactie (klik-doorlaat / slepen)

    @Test func mouseIsCapturedOnlyWhileTheDragModifierIsHeld() {
        #expect(IndicatorInteraction.shouldCaptureMouse(dragModifierHeld: true) == true)
        #expect(IndicatorInteraction.shouldCaptureMouse(dragModifierHeld: false) == false)
    }

    // MARK: - Positie-persistentie (geheugen-store, geen Foundation)

    @Test func memoryStoreRoundTripsAPosition() {
        let store = MemoryIndicatorPositionStore()
        #expect(store.savedPosition() == nil)
        store.save(IndicatorPosition(x: 120, y: 340))
        let read = store.savedPosition()
        #expect(read?.x == 120)
        #expect(read?.y == 340)
    }

    // MARK: - Positie-persistentie tussen sessies (UserDefaults, via support)

    @Test func positionSurvivesAFreshStore() {
        let outcome = ListeningIndicatorTestSupport.runPositionPersistenceAcrossStores(x: 200, y: 88)
        #expect(outcome.readBackX == 200)
        #expect(outcome.readBackY == 88)
        #expect(outcome.emptyBeforeSave == true)
    }
}

/// In-geheugen `IndicatorPositionStore`: geen `UserDefaults`, maar overleeft binnen een
/// test wel een tweede lezer. Puur stdlib zodat dit testbestand geen Foundation hoeft.
final class MemoryIndicatorPositionStore: IndicatorPositionStore {
    private var position: IndicatorPosition?
    func savedPosition() -> IndicatorPosition? { position }
    func save(_ position: IndicatorPosition) { self.position = position }
}
