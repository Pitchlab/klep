import Testing
@testable import PitchlabSpeech

/// Tests voor de opstartstand (PL-742). Vóór deze taak paste `applicationDidFinish-
/// Launching` de bewaarde hands-free-stand niet toe: het menu toonde "aan" terwijl er
/// geen sessie liep — de interface loog. `LaunchState` legt keuze (b) vast: hands-free
/// begint altijd uit en het menu toont dat ook, auto-enter blijft zoals bewaard.
///
/// Puur, dus zonder runloop te testen. Dit bestand importeert bewust géén Foundation
/// (dat triggert de cross-import overlay `_Testing_Foundation`, die ontbreekt in de
/// CLT-only toolchain); de store-hulp staat in `HotkeysTestSupport.swift`.
@Suite struct LaunchStateTests {

    // MARK: - Hands-free: keuze (b), altijd uit

    @Test func handsFreeIgnoresTheSavedOnStateAndBeginsOff() {
        let state = LaunchState(savedHandsFree: true, savedAutoEnter: false)
        // De bewaarde stand stond aan; keuze (b) negeert hem.
        #expect(state.startHandsFree == false)
        #expect(state.handsFreeOn == false)
    }

    @Test func handsFreeStaysOffWhenSavedOff() {
        let state = LaunchState(savedHandsFree: false, savedAutoEnter: false)
        #expect(state.startHandsFree == false)
        #expect(state.handsFreeOn == false)
    }

    /// De kern van de bug: menu-stand en werkelijke sessie-stand moeten na een
    /// herstart overeenkomen. `handsFreeOn` voedt het menu, `startHandsFree` de keten;
    /// staan die gelijk, dan kan het menu niet liegen — voor beide bewaarde standen.
    @Test func menuStateAndSessionStateMatchForEitherSavedValue() {
        for saved in [true, false] {
            let state = LaunchState(savedHandsFree: saved, savedAutoEnter: false)
            #expect(state.handsFreeOn == state.startHandsFree)
        }
    }

    // MARK: - Auto-enter: keuze (a), bewaarde stand blijft

    @Test func autoEnterKeepsTheSavedOnState() {
        let state = LaunchState(savedHandsFree: false, savedAutoEnter: true)
        #expect(state.autoEnterOn == true)
    }

    @Test func autoEnterKeepsTheSavedOffState() {
        let state = LaunchState(savedHandsFree: false, savedAutoEnter: false)
        #expect(state.autoEnterOn == false)
    }

    // MARK: - Toepassen op de store (de herstart-route)

    /// Bootst na wat het opstarten doet: een store waarin hands-free aan stond, de
    /// opstartstand afleiden en toepassen. Daarna leest de store — en dus het menu —
    /// hands-free uit, terwijl auto-enter blijft staan.
    @Test func applyingLaunchStateForcesHandsFreeOffInTheStoreAndKeepsAutoEnter() {
        let store = HotkeysTestSupport.makeStore()
        store.setOn(true, for: .handsFree)
        store.setOn(true, for: .autoEnter)

        let state = LaunchState(
            savedHandsFree: store.isOn(.handsFree),
            savedAutoEnter: store.isOn(.autoEnter))
        store.setOn(state.handsFreeOn, for: .handsFree)
        store.setOn(state.autoEnterOn, for: .autoEnter)

        #expect(store.isOn(.handsFree) == false)
        #expect(store.isOn(.autoEnter) == true)
    }
}
