import Testing
@testable import Klep

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

    @Test func defaultsAreModifierOnlyRightCommand() {
        let hf = KeyCombo.default(for: .handsFree)
        let ae = KeyCombo.default(for: .autoEnter)
        #expect(hf != ae)
        // Hands-free = kale rechter cmd; auto-enter = ⇧ + rechter cmd.
        #expect(hf.keyCode == ModifierKey.rightCommand)
        #expect(hf.modifiers == [])
        #expect(hf.isModifierOnly)
        #expect(ae.keyCode == ModifierKey.rightCommand)
        #expect(ae.modifiers == [.shift])
        #expect(ae.isModifierOnly)
    }

    @Test func regularKeycodeComboIsNotModifierOnly() {
        #expect(KeyCombo(keyCode: 4, modifiers: [.control, .option]).isModifierOnly == false)
        #expect(KeyCombo(keyCode: 49, modifiers: []).isModifierOnly == false)  // Space
    }

    // MARK: - Persistentie: één formaat voor beide soorten

    @Test func modifierOnlyComboPersistsInTheSameFormat() {
        // ⇧ = 1<<3 = 8, rechter cmd = 54.
        let ae = KeyCombo.default(for: .autoEnter)
        #expect(ae.persistString == "8:54")
        #expect(KeyCombo.default(for: .handsFree).persistString == "0:54")
        // En het leest ongewijzigd terug, mét zijn modifier-only aard.
        let restored = KeyCombo(persistString: ae.persistString)
        #expect(restored == ae)
        #expect(restored?.isModifierOnly == true)
    }

    // MARK: - Modifier-toetsen: links/rechts en device-bits

    @Test func modifierKeyLogicalMapping() {
        #expect(ModifierKey.logicalModifier(for: 54) == .command)   // rechter cmd
        #expect(ModifierKey.logicalModifier(for: 55) == .command)   // linker cmd
        #expect(ModifierKey.logicalModifier(for: 56) == .shift)
        #expect(ModifierKey.logicalModifier(for: 4) == nil)         // gewone toets
    }

    @Test func deviceMaskDistinguishesLeftFromRightCommand() {
        // Rechter cmd omlaag: het rechter device-bit (0x10) staat aan, links niet.
        #expect(ModifierKey.isKeyDown(keyCode: 54, deviceFlags: 0x10) == true)
        #expect(ModifierKey.isKeyDown(keyCode: 55, deviceFlags: 0x10) == false)
        // Alles uit: beide omhoog.
        #expect(ModifierKey.isKeyDown(keyCode: 54, deviceFlags: 0x0) == false)
    }

    // MARK: - Modifier-tik-detectie (CGEventTap-model)

    private func rightCommandDetector() -> ModifierTapDetector {
        ModifierTapDetector(bindings: [
            .init(action: .handsFree, keyCode: 54, requiredModifiers: []),
            .init(action: .autoEnter, keyCode: 54, requiredModifiers: [.shift]),
        ])
    }

    @Test func tapOnRightCommandFiresHandsFree() {
        let d = rightCommandDetector()
        #expect(d.process(.modifier(keyCode: 54, isDown: true, activeModifiers: [.command]), now: 0) == nil)
        #expect(d.process(.modifier(keyCode: 54, isDown: false, activeModifiers: []), now: 0.1) == .handsFree)
    }

    @Test func tapOnShiftRightCommandFiresAutoEnter() {
        let d = rightCommandDetector()
        // Shift eerst vast, dan rechter cmd erbij: een tik mét shift.
        _ = d.process(.modifier(keyCode: 56, isDown: true, activeModifiers: [.shift]), now: 0)
        _ = d.process(.modifier(keyCode: 54, isDown: true, activeModifiers: [.command, .shift]), now: 0.05)
        #expect(d.process(.modifier(keyCode: 54, isDown: false, activeModifiers: [.shift]), now: 0.1) == .autoEnter)
    }

    @Test func plainRightCommandTapDoesNotFireAutoEnter() {
        // Zonder shift mag alleen hands-free vuren, niet auto-enter.
        let d = rightCommandDetector()
        _ = d.process(.modifier(keyCode: 54, isDown: true, activeModifiers: [.command]), now: 0)
        #expect(d.process(.modifier(keyCode: 54, isDown: false, activeModifiers: []), now: 0.1) == .handsFree)
    }

    @Test func commandShortcutDoesNotToggle() {
        // Rechter cmd ingedrukt houden met een gewone toets erbij (cmd-C) is een
        // snelkoppeling, geen tik: de toggle mag NIET vuren.
        let d = rightCommandDetector()
        _ = d.process(.modifier(keyCode: 54, isDown: true, activeModifiers: [.command]), now: 0)
        _ = d.process(.otherKey, now: 0.02)
        #expect(d.process(.modifier(keyCode: 54, isDown: false, activeModifiers: []), now: 0.05) == nil)
    }

    @Test func longHoldWithoutOtherKeyDoesNotToggle() {
        // Langer dan de maximale tik-tijd vastgehouden → geen toggle.
        let d = rightCommandDetector()
        _ = d.process(.modifier(keyCode: 54, isDown: true, activeModifiers: [.command]), now: 0)
        #expect(d.process(.modifier(keyCode: 54, isDown: false, activeModifiers: []), now: 1.0) == nil)
    }

    @Test func leftCommandTapIsIgnored() {
        // Alleen rechter cmd (54) is gebonden; linker cmd (55) doet niets.
        let d = rightCommandDetector()
        _ = d.process(.modifier(keyCode: 55, isDown: true, activeModifiers: [.command]), now: 0)
        #expect(d.process(.modifier(keyCode: 55, isDown: false, activeModifiers: []), now: 0.1) == nil)
    }

    @Test func releaseWithoutMatchingDownIsIgnored() {
        let d = rightCommandDetector()
        #expect(d.process(.modifier(keyCode: 54, isDown: false, activeModifiers: []), now: 0) == nil)
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
