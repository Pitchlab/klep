import Testing
@testable import Klep

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

    // MARK: - Toggle-labels dragen hun sneltoets

    /// De toets staat tussen haakjes achter de naam, op één regel. Er stond eerst een
    /// aparte "Sneltoets"-regel én een hint eronder — twee keer dezelfde toets.
    @Test func toggleLabelsCarryTheirShortcutInBrackets() {
        let model = MenuBarPanelModel(handsFreeShortcut: "R⌘", autoEnterShortcut: "⇧R⌘")
        #expect(model.handsFreeLabel == "Hands-free (R⌘)")
        #expect(model.autoEnterLabel == "Auto-enter (⇧R⌘)")
    }

    /// Zonder ingestelde toets geen leeg haakjespaar.
    @Test func toggleLabelsOmitEmptyBrackets() {
        let model = MenuBarPanelModel()
        #expect(model.handsFreeLabel == "Hands-free")
        #expect(model.autoEnterLabel == "Auto-enter")
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

    // MARK: - Permissie-bannertje (de volledige sectie staat in instellingen, PL-788)

    @Test func permissionBannerIsAbsentWhenNothingMissing() {
        #expect(MenuBarPanelModel().permissionBanner == nil)
    }

    @Test func permissionBannerShowsWhatIsMissing() {
        let model = MenuBarPanelModel(permissionBanner: "Toegankelijkheid ontbreekt.")
        #expect(model.permissionBanner == "Toegankelijkheid ontbreekt.")
    }

    // MARK: - Geschiedenis

    /// Sinds PL-757 de geschiedenis vult, is de knop aanklikbaar en draagt hij geen
    /// uitleg meer waarom hij uit staat. Die tooltip zei "worden nog niet bewaard" en
    /// dat was onwaar geworden.
    @Test func historyIsReachable() {
        let history = MenuBarPanelModel().footerButtons().first { $0.action == .history }
        #expect(history?.isEnabled == true)
        #expect(history?.disabledHint == nil)
    }

    @Test func everyFooterButtonIsEnabledAndCarriesNoHint() {
        let buttons = MenuBarPanelModel().footerButtons()
        #expect(buttons.allSatisfy { $0.isEnabled })
        #expect(buttons.allSatisfy { $0.disabledHint == nil })
    }

    // MARK: - Stip terug naar het midden (PL-737)

    @Test func recenterTitleIsStable() {
        #expect(MenuBarPanelModel().recenterTitle == "Stip naar het midden")
    }

    @Test func canRecenterReflectsWhetherTheDotIsWired() {
        // Alleen met een gekoppelde stip biedt het paneel de knop; anders zou hij dood zijn.
        #expect(MenuBarPanelModel(canRecenter: true).canRecenter == true)
        #expect(MenuBarPanelModel(canRecenter: false).canRecenter == false)
        #expect(MenuBarPanelModel().canRecenter == false)
    }

    // MARK: - Voetrij

    @Test func footerHasThreeUsableActions() {
        let buttons = MenuBarPanelModel().footerButtons()
        #expect(buttons.map(\.action) == [.settings, .history, .quit])
        #expect(buttons.map(\.title) == ["Instellingen", "Geschiedenis", "Stoppen"])
        #expect(buttons.first { $0.action == .history }?.isEnabled == true)
        #expect(buttons.first { $0.action == .settings }?.isEnabled == true)
        #expect(buttons.first { $0.action == .quit }?.isEnabled == true)
    }
}
