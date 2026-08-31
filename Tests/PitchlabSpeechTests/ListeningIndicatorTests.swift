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

    // MARK: - Relatieve positie (fractie, geklemd)

    @Test func positionClampsFractionsToUnitRange() {
        let low = IndicatorPosition(fractionX: -0.3, fractionY: 2.0)
        #expect(low.fractionX == 0)
        #expect(low.fractionY == 1)
    }

    @Test func centerIsHalfOnBothAxes() {
        #expect(IndicatorPosition.center.fractionX == 0.5)
        #expect(IndicatorPosition.center.fractionY == 0.5)
    }

    // MARK: - Geometrie (fractie ↔ venster-oorsprong, op-scherm geklemd)

    @Test func centerFractionPlacesTheDotInTheMiddleOfTheVisibleFrame() {
        // Zichtbare frame 0…1000 breed, venster 56 breed: het midden van het venster
        // ligt op 500, dus de oorsprong op 500 − 28 = 472.
        let origin = IndicatorGeometry.origin(
            fraction: 0.5, visibleMin: 0, visibleLength: 1000, panelLength: 56)
        #expect(origin == 472)
    }

    @Test func originStaysFullyOnScreenAtTheEdges() {
        // Fractie 1 (uiterst rechts) mag het venster niet buiten de frame duwen: de
        // oorsprong wordt geklemd op visibleMin + visibleLength − panelLength.
        let right = IndicatorGeometry.origin(
            fraction: 1, visibleMin: 0, visibleLength: 1000, panelLength: 56)
        #expect(right == 944)
        // Fractie 0 (uiterst links) klemt op visibleMin.
        let left = IndicatorGeometry.origin(
            fraction: 0, visibleMin: 0, visibleLength: 1000, panelLength: 56)
        #expect(left == 0)
    }

    @Test func savedFractionStaysVisibleOnASmallerScreen() {
        // Een positie dicht bij de rand, bewaard op een breed scherm, blijft zichtbaar
        // op een smaller scherm (resolutieverandering / losgekoppelde monitor): het
        // venster valt nooit buiten de zichtbare frame.
        let origin = IndicatorGeometry.origin(
            fraction: 0.95, visibleMin: 0, visibleLength: 400, panelLength: 56)
        #expect(origin <= 400 - 56)
        #expect(origin >= 0)
    }

    @Test func originAndFractionRoundTrip() {
        let origin = IndicatorGeometry.origin(
            fraction: 0.3, visibleMin: 100, visibleLength: 800, panelLength: 56)
        let fraction = IndicatorGeometry.fraction(
            origin: origin, visibleMin: 100, visibleLength: 800, panelLength: 56)
        #expect(abs(fraction - 0.3) < 1e-9)
    }

    // MARK: - Positie-persistentie (geheugen-store, geen Foundation)

    @Test func memoryStoreRoundTripsARelativePosition() {
        let store = MemoryIndicatorPositionStore()
        #expect(store.savedPosition() == nil)
        store.save(IndicatorPosition(fractionX: 0.25, fractionY: 0.75))
        let read = store.savedPosition()
        #expect(read?.fractionX == 0.25)
        #expect(read?.fractionY == 0.75)
    }

    @Test func resettingToCenterSavesTheCenterFraction() {
        // Wat het "terug naar het midden"-menu-item doet: bewaar het midden, zodat de
        // stip er ook na een herstart in het midden verschijnt.
        let store = MemoryIndicatorPositionStore()
        store.save(IndicatorPosition(fractionX: 0.02, fractionY: 0.98))
        store.save(.center)
        #expect(store.savedPosition() == IndicatorPosition.center)
    }

    // MARK: - Positie-persistentie tussen sessies (UserDefaults, via support)

    @Test func positionSurvivesAFreshStore() {
        let outcome = ListeningIndicatorTestSupport.runPositionPersistenceAcrossStores(
            fractionX: 0.2, fractionY: 0.88)
        #expect(outcome.readBackX == 0.2)
        #expect(outcome.readBackY == 0.88)
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
