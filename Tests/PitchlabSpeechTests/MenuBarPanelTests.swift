import Testing
@testable import PitchlabSpeech

/// Tests voor het menubalk-paneel. Alleen de pure model-laag: de paneelteksten, de
/// statusstip-kleur (de statusomzetting), de getalnotatie en de standen. De AppKit-laag
/// (`MenuBarPanelController`) vraagt een runloop en is een mensentest (PRD, ROE §2).
///
/// Net als `MenuBarTests` importeert dit bestand bewust géén Foundation: `import
/// Testing` + `import Foundation` triggert de cross-import overlay `_Testing_Foundation`,
/// waarvan de module-interface ontbreekt in de CLT-only toolchain.
@Suite struct MenuBarPanelTests {

    // MARK: - Statusomzetting (stipkleur per staat)

    @Test func statusColorMapsEachState() {
        #expect(SpeechState.idle.statusColor == .ready)
        #expect(SpeechState.listening.statusColor == .listening)
        #expect(SpeechState.transcribing.statusColor == .working)
    }

    @Test func statusColorIsDistinctPerState() {
        let colors = Set([
            SpeechState.idle.statusColor,
            SpeechState.listening.statusColor,
            SpeechState.transcribing.statusColor,
        ])
        #expect(colors.count == 3)
    }

    @Test func statusIndicatorCarriesColorAndLabel() {
        let indicator = StatusIndicator(state: .listening)
        #expect(indicator.color == .listening)
        #expect(indicator.label == "Status: luistert…")
    }

    // MARK: - Getalnotatie (valkuil: één NumberFormatter, overal)

    @Test func secondsUseCommaAndTwoDecimals() {
        #expect(SpeechFormat.seconds(1.0) == "1,00s")
        #expect(SpeechFormat.seconds(0.5) == "0,50s")
    }

    // MARK: - Kop: versie en toetsenchip

    @Test func versionLabelHasVPrefix() {
        let model = MenuBarPanelModel(version: "0.3.0")
        #expect(model.versionLabel == "v0.3.0")
    }

    @Test func shortcutChipShowsHandsFreeShortcut() {
        let model = MenuBarPanelModel(handsFreeShortcut: "R⌘")
        #expect(model.shortcutChip == "R⌘")
    }

    // MARK: - Hands-free: toggle + hint

    @Test func handsFreeHintNamesTheShortcut() {
        let model = MenuBarPanelModel(handsFreeShortcut: "R⌘")
        #expect(model.handsFreeHint == "Omschakelen met R⌘")
    }

    // MARK: - Microfoon-dropdown

    @Test func microphoneItemsMarkTheSelectedOne() {
        let devices = [
            DeviceInfo(uniqueID: "mic-A", localizedName: "Ingebouwde microfoon"),
            DeviceInfo(uniqueID: "mic-B", localizedName: "AirPods"),
        ]
        let model = MenuBarPanelModel(devices: devices, selectedDeviceID: "mic-B")
        let items = model.microphoneItems()
        #expect(items.count == 2)
        #expect(items[0].title == "Ingebouwde microfoon")
        #expect(items[0].isSelected == false)
        #expect(items[1].title == "AirPods")
        #expect(items[1].isSelected == true)
        #expect(model.selectedMicrophoneName == "AirPods")
    }

    @Test func microphonePlaceholderIsStable() {
        #expect(MenuBarPanelModel().microphonePlaceholder == "(geen microfoons gevonden)")
    }

    // MARK: - Meldingen (R6/R9): geen stille mislukking

    @Test func noticeLinesShowFallbackAndError() {
        let model = MenuBarPanelModel(
            fallbackNotice: "Gekozen microfoon is losgekoppeld.",
            errorNotice: "Tekst kon niet ingevoegd worden.")
        let lines = model.noticeLines()
        #expect(lines.contains("⚠︎ Gekozen microfoon is losgekoppeld."))
        #expect(lines.contains("⚠︎ Tekst kon niet ingevoegd worden."))
    }

    @Test func noticeLinesEmptyWhenNoneSet() {
        #expect(MenuBarPanelModel().noticeLines().isEmpty)
    }

    // MARK: - Voetrij

    @Test func footerHasThreeActionsWithHistoryDisabled() {
        let buttons = MenuBarPanelModel().footerButtons()
        #expect(buttons.map(\.action) == [.settings, .history, .quit])
        #expect(buttons.map(\.title) == ["Instellingen", "Geschiedenis", "Stoppen"])
        // Geschiedenis staat uit tot PL-757 de inhoud levert.
        let history = buttons.first { $0.action == .history }
        #expect(history?.isEnabled == false)
        #expect(buttons.first { $0.action == .settings }?.isEnabled == true)
        #expect(buttons.first { $0.action == .quit }?.isEnabled == true)
    }
}
