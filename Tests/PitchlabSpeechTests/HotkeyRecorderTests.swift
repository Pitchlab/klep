import Testing
@testable import PitchlabSpeech

/// Tests voor het opnemen van een sneltoets: het opname-state-machine
/// (`HotkeyRecorder`) en de conflict-check bij toewijzen (`HotkeyStore.assign`).
/// Alleen de pure model-laag — het echte venster met opnamevelden
/// (`HotkeySettingsWindowController`) vraagt een NSApplication-runloop en is een
/// mensentest.
///
/// Geen `import Foundation` hier: dat triggert samen met `import Testing` de
/// cross-import overlay `_Testing_Foundation`, waarvan de module-interface ontbreekt
/// in de CLT-only toolchain. De store-helper staat in `HotkeysTestSupport.swift`.
@Suite struct HotkeyRecorderTests {

    // MARK: - Gewone keycode-combo opnemen

    @Test func recordsAPlainKeycodeCombo() {
        let r = HotkeyRecorder()
        // Een gewone toets met modifiers rondt de opname meteen af (⌃⌥H).
        let combo = r.process(.key(keyCode: 4, modifiers: [.control, .option]))
        #expect(combo == KeyCombo(keyCode: 4, modifiers: [.control, .option]))
        #expect(r.recorded == combo)
        #expect(combo?.isModifierOnly == false)
    }

    @Test func recordedComboUsesTheExistingGlyphDisplay() {
        // De weergave komt uit de bestaande glyph-logica (`KeyCombo.display`), niet
        // opnieuw gebouwd.
        let r = HotkeyRecorder()
        _ = r.process(.key(keyCode: 4, modifiers: [.control, .option]))
        #expect(r.recorded?.display == "⌃⌥H")
    }

    @Test func recordsAnUnmodifiedKey() {
        let r = HotkeyRecorder()
        #expect(r.process(.key(keyCode: 49, modifiers: [])) == KeyCombo(keyCode: 49, modifiers: []))
    }

    // MARK: - Kale modifier opnemen (rechter cmd) — anders dan een gewoon opnameveld

    @Test func recordsABareModifierAsModifierOnly() {
        // Rechter cmd omlaag en weer omhoog, niets ertussen: een kale-modifier-combo.
        // Een gewoon opnameveld negeert dit juist; hier is het geldig (PL-732-default).
        let r = HotkeyRecorder()
        #expect(r.process(.modifier(keyCode: 54, isDown: true, activeModifiers: [.command])) == nil)
        let combo = r.process(.modifier(keyCode: 54, isDown: false, activeModifiers: []))
        #expect(combo == KeyCombo(keyCode: ModifierKey.rightCommand, modifiers: []))
        #expect(combo?.isModifierOnly == true)
    }

    @Test func recordsShiftPlusBareRightCommand() {
        // Shift vast, dan rechter cmd erbij en weer los: ⇧ + rechter cmd, modifier-only.
        let r = HotkeyRecorder()
        _ = r.process(.modifier(keyCode: 56, isDown: true, activeModifiers: [.shift]))
        _ = r.process(.modifier(keyCode: 54, isDown: true, activeModifiers: [.command, .shift]))
        let combo = r.process(.modifier(keyCode: 54, isDown: false, activeModifiers: [.shift]))
        #expect(combo == KeyCombo(keyCode: ModifierKey.rightCommand, modifiers: [.shift]))
        #expect(combo?.isModifierOnly == true)
    }

    @Test func modifierFollowedByARealKeyIsAPlainCombo() {
        // Rechter cmd omlaag en dán een gewone toets: dat is ⌘A, geen kale modifier.
        let r = HotkeyRecorder()
        _ = r.process(.modifier(keyCode: 54, isDown: true, activeModifiers: [.command]))
        let combo = r.process(.key(keyCode: 0, modifiers: [.command]))
        #expect(combo == KeyCombo(keyCode: 0, modifiers: [.command]))
        #expect(combo?.isModifierOnly == false)
    }

    @Test func releaseOfADifferentModifierRecordsNothing() {
        let r = HotkeyRecorder()
        _ = r.process(.modifier(keyCode: 54, isDown: true, activeModifiers: [.command]))
        // Een ándere modifier omhoog maakt geen tik af.
        #expect(r.process(.modifier(keyCode: 56, isDown: false, activeModifiers: [.command])) == nil)
        #expect(r.recorded == nil)
    }

    @Test func nonModifierInAModifierEventIsIgnored() {
        let r = HotkeyRecorder()
        #expect(r.process(.modifier(keyCode: 4, isDown: true, activeModifiers: [])) == nil)
        #expect(r.recorded == nil)
    }

    // MARK: - Afronden en opnieuw opnemen

    @Test func furtherEventsAreIgnoredAfterAComplete() {
        let r = HotkeyRecorder()
        _ = r.process(.key(keyCode: 4, modifiers: [.control]))
        // Een tweede toets overschrijft de eerste opname niet.
        _ = r.process(.key(keyCode: 14, modifiers: [.option]))
        #expect(r.recorded == KeyCombo(keyCode: 4, modifiers: [.control]))
    }

    @Test func resetAllowsRecordingAgain() {
        let r = HotkeyRecorder()
        _ = r.process(.key(keyCode: 4, modifiers: [.control]))
        r.reset()
        #expect(r.recorded == nil)
        _ = r.process(.key(keyCode: 14, modifiers: [.option]))
        #expect(r.recorded == KeyCombo(keyCode: 14, modifiers: [.option]))
    }

    // MARK: - Toewijzen: weiger een combinatie die de andere actie al gebruikt

    @Test func assignsAFreeComboAndPersistsIt() {
        let store = HotkeysTestSupport.makeStore()
        let combo = KeyCombo(keyCode: 49, modifiers: [.command, .shift])
        #expect(store.assign(combo, to: .handsFree) == nil)
        #expect(store.combo(for: .handsFree) == combo)
    }

    @Test func refusesAComboTheOtherActionAlreadyUses() {
        let store = HotkeysTestSupport.makeStore()
        // Auto-enter staat op zijn default (⇧ + rechter cmd). Datzelfde aan hands-free
        // toewijzen moet weigeren en de botsende actie teruggeven.
        let taken = KeyCombo.default(for: .autoEnter)
        #expect(store.assign(taken, to: .handsFree) == .autoEnter)
        // En de store is niet gewijzigd: hands-free houdt zijn eigen default.
        #expect(store.combo(for: .handsFree) == KeyCombo.default(for: .handsFree))
    }

    @Test func reassigningAnActionsOwnComboIsNotAConflict() {
        let store = HotkeysTestSupport.makeStore()
        let same = store.combo(for: .handsFree)
        #expect(store.conflictingAction(for: same, assigning: .handsFree) == nil)
        #expect(store.assign(same, to: .handsFree) == nil)
    }

    @Test func defaultsDoNotConflictWithEachOther() {
        let store = HotkeysTestSupport.makeStore()
        // Rechter cmd en ⇧ + rechter cmd verschillen in modifier, dus geen botsing.
        #expect(store.conflictingAction(
            for: KeyCombo.default(for: .handsFree), assigning: .handsFree) == nil)
    }

    // MARK: - Reset naar default, ook conflict-bewaakt

    @Test func resetRestoresTheDefault() {
        let store = HotkeysTestSupport.makeStore()
        store.setCombo(KeyCombo(keyCode: 49, modifiers: [.command]), for: .handsFree)
        #expect(store.resetToDefault(for: .handsFree) == nil)
        #expect(store.combo(for: .handsFree) == KeyCombo.default(for: .handsFree))
    }

    @Test func resetRefusesWhenItWouldClashWithTheOtherAction() {
        let store = HotkeysTestSupport.makeStore()
        // Zet auto-enter weg van zijn default en geef hands-free die default (⇧+R⌘)
        // rechtstreeks. Auto-enter terugzetten zou nu botsen met hands-free.
        store.setCombo(KeyCombo(keyCode: 49, modifiers: []), for: .autoEnter)
        store.setCombo(KeyCombo.default(for: .autoEnter), for: .handsFree)
        #expect(store.resetToDefault(for: .autoEnter) == .handsFree)
        // Auto-enter blijft ongewijzigd op de eigen instelling.
        #expect(store.combo(for: .autoEnter) == KeyCombo(keyCode: 49, modifiers: []))
    }

    // MARK: - Melding

    @Test func conflictMessageNamesTheComboAndTheOtherAction() {
        let combo = KeyCombo(keyCode: 4, modifiers: [.control, .option])
        let msg = HotkeyConflict.message(combo: combo, inUseBy: .autoEnter)
        #expect(msg.contains("⌃⌥H"))
        #expect(msg.contains(HotkeyAction.autoEnter.title))
    }
}
