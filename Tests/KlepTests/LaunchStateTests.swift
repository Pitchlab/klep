import Testing
@testable import Klep

/// Tests voor de opstartstand (PL-742). Vóór deze taak paste `applicationDidFinish-
/// Launching` de bewaarde hands-free-stand niet toe: het menu toonde "aan" terwijl er
/// geen sessie liep — de interface loog. `LaunchState` legt vast dat hands-free altijd
/// uit begint en dat het menu dat ook toont; auto-enter houdt zijn bewaarde stand.
///
/// Puur, dus zonder runloop te testen. Dit bestand importeert bewust géén Foundation
/// (dat triggert de cross-import overlay `_Testing_Foundation`, die ontbreekt in de
/// CLT-only toolchain); de store-hulp staat in `HotkeysTestSupport.swift`.
@Suite struct LaunchStateTests {

    // MARK: - Hands-free: altijd uit

    @Test func handsFreeBeginsOff() {
        #expect(LaunchState(savedAutoEnter: false).handsFreeOn == false)
        #expect(LaunchState(savedAutoEnter: true).handsFreeOn == false)
    }

    // MARK: - Auto-enter: bewaarde stand blijft

    @Test func autoEnterKeepsTheSavedOnState() {
        #expect(LaunchState(savedAutoEnter: true).autoEnterOn == true)
    }

    @Test func autoEnterKeepsTheSavedOffState() {
        #expect(LaunchState(savedAutoEnter: false).autoEnterOn == false)
    }

    // MARK: - Toepassen op de store (de herstart-route)

    /// De kern van de bug, langs de route die hem veroorzaakte: een store waarin
    /// hands-free aan stond, de opstartstand toepassen, en dan leest de store — en dus
    /// het menu — hands-free uit. Auto-enter blijft staan.
    @Test func applyingLaunchStateForcesHandsFreeOffInTheStoreAndKeepsAutoEnter() {
        let store = HotkeysTestSupport.makeStore()
        store.setOn(true, for: .handsFree)
        store.setOn(true, for: .autoEnter)

        let state = LaunchState(savedAutoEnter: store.isOn(.autoEnter))
        store.setOn(state.handsFreeOn, for: .handsFree)
        store.setOn(state.autoEnterOn, for: .autoEnter)

        #expect(store.isOn(.handsFree) == false)
        #expect(store.isOn(.autoEnter) == true)
    }

    /// Ook na twee herstarts achter elkaar blijft hands-free uit: de bewaarde stand
    /// wordt niet ergens anders alsnog teruggezet.
    @Test func handsFreeStaysOffAcrossRepeatedLaunches() {
        let store = HotkeysTestSupport.makeStore()
        store.setOn(true, for: .handsFree)
        for _ in 0..<2 {
            let state = LaunchState(savedAutoEnter: store.isOn(.autoEnter))
            store.setOn(state.handsFreeOn, for: .handsFree)
        }
        #expect(store.isOn(.handsFree) == false)
    }
}
