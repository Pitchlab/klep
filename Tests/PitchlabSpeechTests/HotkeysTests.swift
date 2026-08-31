import Testing
@testable import PitchlabSpeech

/// Tests voor de twee globale hotkeys. Alleen de pure model-laag: de
/// toetscombinatie-weergave en -persistentie, de twee onafhankelijke toggles, de
/// statusitem-tekst en de permissie-melding. De Carbon/AppKit-laag
/// (`GlobalHotkeyManager`) vraagt een runloop en de Input Monitoring-permissie en
/// is een mensentest (PRD, ROE §2).
///
/// Geen `import Foundation` hier: dat triggert samen met `import Testing` de
/// cross-import overlay `_Testing_Foundation`, waarvan de module-interface
/// ontbreekt in de CLT-only toolchain. Foundation-werk staat in
/// `HotkeysTestSupport.swift`.
@Suite struct HotkeysTests {

    // MARK: - Acties

    @Test func actionsAreTwoIndependentToggles() {
        #expect(HotkeyAction.allCases.count == 2)
        #expect(HotkeyAction.handsFree.hotkeyID != HotkeyAction.autoEnter.hotkeyID)
        #expect(HotkeyAction.handsFree.comboKey != HotkeyAction.autoEnter.comboKey)
        #expect(HotkeyAction.handsFree.stateKey != HotkeyAction.autoEnter.stateKey)
    }

    @Test func hotkeyIDRoundTrips() {
        for action in HotkeyAction.allCases {
            #expect(HotkeyAction(hotkeyID: action.hotkeyID) == action)
        }
        #expect(HotkeyAction(hotkeyID: 99) == nil)
    }

    // MARK: - Toetscombinatie: weergave

    @Test func modifierGlyphsFollowMacOrder() {
        let combo = KeyCombo(keyCode: 49, modifiers: [.command, .shift, .option, .control])
        #expect(combo.modifierGlyphs == "⌃⌥⇧⌘")
    }

    @Test func displayJoinsGlyphsAndKeyName() {
        let combo = KeyCombo(keyCode: 4, modifiers: [.control, .option])
        #expect(combo.display == "⌃⌥H")
    }

    @Test func unknownKeyFallsBackToRawCode() {
        let combo = KeyCombo(keyCode: 200, modifiers: [])
        #expect(combo.display == "key 200")
    }

    // MARK: - Toetscombinatie: persistentie

    @Test func comboRoundTripsThroughPersistString() {
        let combo = KeyCombo(keyCode: 14, modifiers: [.control, .option])
        let restored = KeyCombo(persistString: combo.persistString)
        #expect(restored == combo)
    }

    @Test func brokenPersistStringReturnsNil() {
        #expect(KeyCombo(persistString: "not-a-combo") == nil)
        #expect(KeyCombo(persistString: "1") == nil)
        #expect(KeyCombo(persistString: "x:y") == nil)
    }

    // MARK: - Toetscombinatie: Carbon-maskers

    @Test func carbonModifiersMapToCarbonMasks() {
        #expect(KeyCombo(keyCode: 0, modifiers: [.command]).carbonModifiers == 256)
        #expect(KeyCombo(keyCode: 0, modifiers: [.shift]).carbonModifiers == 512)
        #expect(KeyCombo(keyCode: 0, modifiers: [.option]).carbonModifiers == 2048)
        #expect(KeyCombo(keyCode: 0, modifiers: [.control]).carbonModifiers == 4096)
        #expect(KeyCombo(keyCode: 0, modifiers: [.control, .option]).carbonModifiers == 4096 + 2048)
    }

    @Test func defaultsDifferPerAction() {
        let hf = KeyCombo.default(for: .handsFree)
        let ae = KeyCombo.default(for: .autoEnter)
        #expect(hf != ae)
        #expect(hf.modifiers == [.control, .option])
        #expect(ae.modifiers == [.control, .option])
    }

    // MARK: - Store: standaard en herdefinitie

    @Test func storeReturnsDefaultComboWhenNothingSaved() {
        let store = HotkeysTestSupport.makeStore()
        #expect(store.combo(for: .handsFree) == KeyCombo.default(for: .handsFree))
        #expect(store.combo(for: .autoEnter) == KeyCombo.default(for: .autoEnter))
    }

    @Test func storePersistsARedefinedCombo() {
        let store = HotkeysTestSupport.makeStore()
        let custom = KeyCombo(keyCode: 49, modifiers: [.command, .shift])
        store.setCombo(custom, for: .handsFree)
        #expect(store.combo(for: .handsFree) == custom)
        // De andere actie blijft op zijn standaard: de toggles zijn onafhankelijk.
        #expect(store.combo(for: .autoEnter) == KeyCombo.default(for: .autoEnter))
    }

    // MARK: - Store: onafhankelijke toggles

    @Test func togglesDefaultOff() {
        let store = HotkeysTestSupport.makeStore()
        #expect(store.isOn(.handsFree) == false)
        #expect(store.isOn(.autoEnter) == false)
    }

    @Test func toggleFlipsOnlyItsOwnAction() {
        let store = HotkeysTestSupport.makeStore()
        let after = store.toggle(.handsFree)
        #expect(after == true)
        #expect(store.isOn(.handsFree) == true)
        // Auto-enter blijft ongemoeid: twee onafhankelijke toggles.
        #expect(store.isOn(.autoEnter) == false)
    }

    @Test func toggleFlipsBackAndForth() {
        let store = HotkeysTestSupport.makeStore()
        #expect(store.toggle(.autoEnter) == true)
        #expect(store.toggle(.autoEnter) == false)
    }

    // MARK: - Statusitem-weergave

    @Test func statusTitleShowsBothStatesAtAGlance() {
        #expect(HotkeyStatus(handsFree: false, autoEnter: false).statusItemTitle == "HF○ AE○")
        #expect(HotkeyStatus(handsFree: true, autoEnter: false).statusItemTitle == "HF● AE○")
        #expect(HotkeyStatus(handsFree: true, autoEnter: true).statusItemTitle == "HF● AE●")
    }

    @Test func storeStatusReflectsToggledState() {
        let store = HotkeysTestSupport.makeStore()
        store.setOn(true, for: .autoEnter)
        let status = store.status()
        #expect(status.handsFree == false)
        #expect(status.autoEnter == true)
        #expect(status.statusItemTitle == "HF○ AE●")
    }

    @Test func statusSymbolsDistinguishAllFourCombos() {
        let combos: [(Bool, Bool)] = [(false, false), (true, false), (false, true), (true, true)]
        var seen = Set<[String]>()
        for (hf, ae) in combos {
            let names = HotkeyStatus(handsFree: hf, autoEnter: ae).statusSymbols().map(\.systemName)
            #expect(names.count == 2)
            seen.insert(names)
        }
        // Elk van de vier standen levert een unieke symbool-combinatie op.
        #expect(seen.count == 4)
    }

    @Test func statusSymbolsCarryAccessibilityLabels() {
        let symbols = HotkeyStatus(handsFree: true, autoEnter: false).statusSymbols()
        #expect(symbols.first?.accessibilityLabel == "Hands-free aan")
        #expect(symbols.last?.accessibilityLabel == "Auto-enter uit")
        #expect(HotkeyStatus(handsFree: true, autoEnter: false).accessibilityLabel
            == "Hands-free aan, Auto-enter uit")
    }

    @Test func statusMenuLinesSpellOutBothToggles() {
        let lines = HotkeyStatus(handsFree: true, autoEnter: false).menuLines()
        #expect(lines.contains("Hands-free: aan"))
        #expect(lines.contains("Auto-enter: uit"))
    }

    // MARK: - Input Monitoring-permissie

    @Test func missingPermissionGivesAnExplicitNotice() {
        let notice = InputMonitoring.notice(granted: false)
        #expect(notice != nil)
        #expect(notice?.contains("Invoercontrole") == true)
        #expect(notice?.contains("Input Monitoring") == true)
    }

    @Test func grantedPermissionGivesNoNotice() {
        #expect(InputMonitoring.notice(granted: true) == nil)
    }
}
