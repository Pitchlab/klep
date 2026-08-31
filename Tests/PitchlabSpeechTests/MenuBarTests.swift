import Testing
@testable import PitchlabSpeech

/// Tests voor de menubalk-app. Alleen de pure model-laag: menu-teksten, checkmarks
/// en de LaunchAgent-plist. De AppKit-laag (`MenuBarController`, `runMenuBarApp`)
/// vraagt een runloop en een echte sessie en is een mensentest (PRD, ROE §2).
///
/// Dit bestand importeert bewust géén Foundation: `import Testing` + `import
/// Foundation` triggert de cross-import overlay `_Testing_Foundation`, waarvan de
/// module-interface ontbreekt in de CLT-only toolchain. Foundation-werk staat in
/// `MenuBarTestSupport.swift`.
@Suite struct MenuBarTests {

    // MARK: - Staat

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

    // MARK: - Hotkey-toggles

    @Test func toggleRowTitleShowsNameWithShortcutHint() {
        let row = HotkeyToggleRow(
            action: .handsFree, title: "Hands-free", isOn: false, shortcut: "⌃⌥H")
        #expect(row.menuTitle == "Hands-free  ⌃⌥H")
    }

    @Test func toggleRowsComeFromTheStoreNotAHardcodedList() {
        let rows = hotkeyToggleRows(store: HotkeysTestSupport.makeStore())
        #expect(rows.map(\.action) == [.handsFree, .autoEnter])
        #expect(rows.map(\.title) == ["Hands-free", "Auto-enter"])
        // De ingestelde sneltoetsen uit de store, niet de vroegere push-to-talk.
        // Deze literals volgen de defaults in Hotkeys.swift: sinds PL-732 is dat
        // rechter ⌘ voor hands-free en ⇧ + rechter ⌘ voor auto-enter. Wijzigen de
        // defaults, dan faalt deze test — dat is de bedoeling, want dan verandert
        // ook wat de gebruiker in het menu leest.
        #expect(rows.map(\.shortcut) == ["R⌘", "⇧R⌘"])
        #expect(!rows.contains(where: { $0.shortcut.contains("Space") }))
    }

    @Test func toggleRowReflectsTheStoredOnOffState() {
        let store = HotkeysTestSupport.makeStore()
        store.setOn(true, for: .handsFree)
        let rows = hotkeyToggleRows(store: store)
        #expect(rows[0].isOn == true)
        #expect(rows[1].isOn == false)
    }

    // MARK: - Menu-model

    @Test func microphoneLineShowsActiveDevice() {
        let model = MenuModel(activeMicrophone: "AirPods")
        #expect(model.microphoneLine == "Microfoon: AirPods")
    }

    @Test func microphoneLineFallsBackWhenNone() {
        let model = MenuModel(activeMicrophone: nil)
        #expect(model.microphoneLine == "Microfoon: (geen)")
    }

    @Test func headerShowsStateAndMicrophoneWithoutHotkeyLines() {
        let model = MenuModel(
            state: .listening,
            activeMicrophone: "Ingebouwde microfoon")
        let header = model.headerLines()
        #expect(header.first == "Status: luistert…")
        #expect(header.contains("Microfoon: Ingebouwde microfoon"))
        // De hotkeys staan nu als klikbare toggles onder de header, niet als tekst
        // erin — en de push-to-talk-regel is weg.
        #expect(!header.contains(where: { $0.contains("push-to-talk") }))
        #expect(!header.contains(where: { $0.contains("Space") }))
    }

    @Test func headerShowsFallbackNoticeWhenPresent() {
        let model = MenuModel(fallbackNotice: "Gekozen microfoon is losgekoppeld.")
        #expect(model.headerLines().contains("⚠︎ Gekozen microfoon is losgekoppeld."))
    }

    @Test func headerOmitsFallbackNoticeWhenAbsent() {
        let model = MenuModel(fallbackNotice: nil)
        #expect(!model.headerLines().contains(where: { $0.hasPrefix("⚠︎") }))
    }

    @Test func deviceItemsMarkTheSelectedOne() {
        let devices = [
            DeviceInfo(uniqueID: "mic-A", localizedName: "Ingebouwde microfoon"),
            DeviceInfo(uniqueID: "mic-B", localizedName: "AirPods"),
        ]
        let model = MenuModel(devices: devices, selectedDeviceID: "mic-B")
        let items = model.deviceItems()
        #expect(items.count == 2)
        #expect(items[0].title == "Ingebouwde microfoon")
        #expect(items[0].isSelected == false)
        #expect(items[1].title == "AirPods")
        #expect(items[1].isSelected == true)
    }

    @Test func autoStartTitleIsStable() {
        #expect(MenuModel().autoStartTitle == "Start automatisch bij inloggen")
    }

    // MARK: - LaunchAgent-plist

    @Test func plistCarriesLabelRunAtLoadAndTheExecutable() {
        let path = "/Applications/PitchlabSpeech.app/Contents/MacOS/PitchlabSpeech"
        let plist = MenuBarTestSupport.launchAgentPlistString(executablePath: path)
        #expect(plist.contains("nl.pitchlab.speech"))
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
