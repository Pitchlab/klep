import Testing
@testable import Klep

/// Tests voor de menubalk-app buiten het paneel: de `SpeechState` (de statusbalk-glyph
/// en -tekst) en de LaunchAgent-plist die auto-start bij inloggen backt (PL-691). De
/// paneelteksten, standen en de statusstip-kleur staan in `MenuBarPanelTests`; het
/// vroegere `MenuModel` (menu-teksten, checkmarks) is met het `NSMenu` verdwenen en de
/// tests erop zijn mee opgeruimd — ze draaiden op code die niets meer aanstuurde. De
/// AppKit-laag (`MenuBarController`, `runMenuBarApp`) vraagt een runloop en is een
/// mensentest (PRD, ROE §2).
///
/// Dit bestand importeert bewust géén Foundation: `import Testing` + `import
/// Foundation` triggert de cross-import overlay `_Testing_Foundation`, waarvan de
/// module-interface ontbreekt in de CLT-only toolchain. Foundation-werk staat in
/// `MenuBarTestSupport.swift`.
@Suite struct MenuBarTests {

    // MARK: - Staat (statusbalk-glyph en -tekst)

    @Test func stateLabelsMatchTheStatus() {
        #expect(SpeechState.idle.menuLabel == "Status: gereed")
        #expect(SpeechState.listening.menuLabel == "Status: luistert…")
        #expect(SpeechState.transcribing.menuLabel == "Status: transcribeert…")
    }

    @Test func stateHasADistinctSymbolPerStatus() {
        let symbols = Set([
            SpeechState.idle.symbolName,
            SpeechState.listening.symbolName,
            SpeechState.transcribing.symbolName,
        ])
        #expect(symbols.count == 3)
    }

    // MARK: - LaunchAgent-plist (backt auto-start, PL-691)

    @Test func plistCarriesLabelRunAtLoadAndTheExecutable() {
        let path = "/Applications/Klep.app/Contents/MacOS/Klep"
        let plist = MenuBarTestSupport.launchAgentPlistString(executablePath: path)
        #expect(plist.contains("nl.pitchlab.klep"))
        #expect(plist.contains("RunAtLoad"))
        #expect(plist.contains(path))
    }

    // MARK: - LaunchAgent-levenscyclus (schrijft en verwijdert)

    @Test func enableWritesAndDisableRemovesThePlist() {
        let life = MenuBarTestSupport.runLaunchAgentLifecycle()
        #expect(life.enabledBeforeWrite == false)
        #expect(life.enabledAfterEnable == true)
        #expect(life.plistExistsOnDisk == true)
        #expect(life.enabledAfterDisable == false)
        #expect(life.doubleDisableThrew == false)
        #expect(life.plistPathEndsWithLabel == true)
    }

    @Test func toggleFlipsAutoStartBothWays() {
        let result = MenuBarTestSupport.runToggleTwice()
        #expect(result.afterFirst == true)
        #expect(result.afterSecond == false)
    }
}
