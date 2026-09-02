/// Menubalk-app: statusitem zonder Dock-icoon dat het bedieningspaneel
/// (`MenuBarPanel.swift`) uit de balk klapt, plus auto-start via een LaunchAgent die
/// de app zelf schrijft en verwijdert. Het vroegere `NSMenu` is weg — een menu kan
/// geen schuifregelaar met een zichtbare waarde dragen; de rijen staan nu als gewone
/// views in een `NSPopover`.
///
/// Twee lagen, gescheiden zodat de logica zonder AppKit-runloop te testen is:
///  - Pure model-laag (`SpeechState`, `LaunchAgent`, `LaunchAgentManager`): de
///    statustekst, de LaunchAgent-plist en de opstartstand worden hier bepaald. Geen
///    `NSStatusItem`, geen runloop — direct te testen. De paneelteksten en -standen
///    zitten in `MenuBarPanelModel` (`MenuBarPanel.swift`).
///  - AppKit-laag (`MenuBarController`, `runMenuBarApp`), onder `#if canImport(AppKit)`:
///    de lijm die het paneel op een echte `NSStatusItem` + `NSPopover` tekent en de
///    acties aan `MicrophoneSelector`, `LaunchAgentManager` en de luister-stip hangt.
///    Compileert in de gate; het echt tonen van een statusitem is een mensentest (PRD).
///
/// Het Dock-icoon blijft weg langs twee kanten: `LSUIElement` in de Info.plist van
/// de .app (zie `scripts/build-app.sh`) en `setActivationPolicy(.accessory)` in de
/// runtime, zodat ook een los gestart proces geen Dock-icoon toont.

import Foundation

// MARK: - Staat

/// Wat de app nu doet. Het menu toont dit als eerste regel.
public enum SpeechState: Sendable, Equatable {
    case idle
    case listening
    case transcribing

    /// De regel bovenaan het menu.
    public var menuLabel: String {
        switch self {
        case .idle: return "Status: gereed"
        case .listening: return "Status: luistert…"
        case .transcribing: return "Status: transcribeert…"
        }
    }

    /// SF Symbol voor het statusitem-icoon, zodat de balk de staat laat zien
    /// zonder het menu te openen.
    public var symbolName: String {
        switch self {
        case .idle: return "mic"
        case .listening: return "mic.fill"
        case .transcribing: return "waveform"
        }
    }
}

// MARK: - LaunchAgent

/// Beschrijft de LaunchAgent die de app bij inloggen start. `plistData` levert de
/// property-list die in `~/Library/LaunchAgents` geschreven wordt.
public struct LaunchAgent: Sendable, Equatable {
    /// Het launchd-label, tevens de bestandsnaam (`<label>.plist`).
    public let label: String
    /// Het pad naar de uitvoerbare binary die launchd start (in de .app-bundel).
    public let executablePath: String

    public init(label: String = "nl.pitchlab.speech", executablePath: String) {
        self.label = label
        self.executablePath = executablePath
    }

    /// De property-list voor launchd: start bij inloggen, één programma-argument
    /// (het pad naar de binary). `KeepAlive` staat uit — de gebruiker mag de app
    /// afsluiten zonder dat launchd hem meteen herstart.
    public func plistData() throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
    }

    /// De plist als tekst, voor logging en tests.
    public func plistString() -> String? {
        guard let data = try? plistData() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Schrijft en verwijdert de LaunchAgent-plist en laadt hem in launchd. De
/// bestandskant (`enable`/`disable`/`isEnabled`) is puur en getest; het echt in
/// launchd laden (`activate`/`deactivate`, via `launchctl`) raakt de sessie en is
/// een mensentest — auto-start na uitloggen/inloggen (PRD).
public struct LaunchAgentManager {
    public let agent: LaunchAgent
    /// De map met LaunchAgents. In productie `~/Library/LaunchAgents`; de tests
    /// injecteren een tijdelijke map zodat ze de echte niet aanraken.
    public let directory: URL

    public init(agent: LaunchAgent, directory: URL? = nil) {
        self.agent = agent
        self.directory = directory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    /// Het pad van de plist: `<directory>/<label>.plist`.
    public var plistURL: URL {
        directory.appendingPathComponent("\(agent.label).plist")
    }

    /// True als de plist bestaat — dan start de app automatisch bij inloggen.
    public func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Zet auto-start aan: schrijf de plist. Maakt de map zo nodig aan.
    public func enable() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try agent.plistData().write(to: plistURL, options: .atomic)
    }

    /// Zet auto-start uit: verwijder de plist. Geen fout als hij er al niet was.
    public func disable() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    /// Schakelt auto-start om en geeft de nieuwe stand terug.
    @discardableResult
    public func toggle() throws -> Bool {
        if isEnabled() {
            try disable()
            return false
        }
        try enable()
        return true
    }
}

// MARK: - Opstartstand

/// Waar de toggles op staan zodra de app op is. Puur — geen AppKit, geen
/// UserDefaults — zodat het zonder runloop te testen is.
///
/// Hands-free begint altijd uit. Hij opent een live microfoon en de app start mee
/// met inloggen, dus aangaan zonder dat iemand erop klikte is een verrassing die je
/// niet wilt. Vóór PL-742 werd de bewaarde stand wél getoond maar niet toegepast:
/// het menu zei "aan" terwijl er niets luisterde, en eruit komen kostte twee
/// toggles. Daarom wordt de stand hier ook in de store op uit gezet — menu-stand en
/// sessie-stand horen hetzelfde te zeggen.
///
/// Erik 2026-09-01: de bewaarde hands-free-stand is geschrapt in plaats van
/// herstelbaar gemaakt. Je wilt nooit dat je computer aangaat en meteen meeluistert,
/// dus een schakelaar om dat wél te doen is werk voor een geval dat niet bestaat.
///
/// Auto-enter houdt zijn bewaarde stand. Die opent niets — hij bepaalt alleen of een
/// uiting met een Return wordt afgesloten — dus is er geen verrassing om tegen te
/// beschermen.
public struct LaunchState: Sendable, Equatable {
    /// De stand waarop de hands-free-toggle (en dus het menu) gezet wordt: altijd uit.
    public let handsFreeOn: Bool
    /// De stand waarop de auto-enter-toggle gezet wordt: de bewaarde stand.
    public let autoEnterOn: Bool

    public init(savedAutoEnter: Bool) {
        self.handsFreeOn = false
        self.autoEnterOn = savedAutoEnter
    }
}

#if canImport(AppKit)
import AppKit

// MARK: - AppKit-laag (mensentest)

/// De interne staat die de controller uit microfoon-, hotkey- en foutbronnen
/// samenstelt en aan het paneel doorgeeft. Geen menu meer: puur de velden die
/// `MenuBarPanelModel` nodig heeft, dus geen presentatie-teksten hier — die zitten in
/// `MenuBarPanelModel`.
private struct ControllerState {
    var state: SpeechState = .idle
    var fallbackNotice: String?
    var errorNotice: String?
    var devices: [DeviceInfo] = []
    var selectedDeviceID: String?
    var autoStartEnabled = false
}

/// Tekent het bedieningspaneel op een echt `NSStatusItem` + `NSPopover` en hangt de
/// acties aan `MicrophoneSelector`, `LaunchAgentManager` en de luister-stip. Runtime
/// niet gedekt door de unit-tests: een statusitem tonen vraagt een NSApplication-
/// runloop en is een mensentest. De testbare logica zit in `MenuBarPanelModel` en
/// `LaunchAgent(Manager)`.
@MainActor
public final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let selector: MicrophoneSelector
    private let launchAgent: LaunchAgentManager
    /// De persistente stand van de twee globale hotkeys (hands-free, auto-enter),
    /// zodat het statusitem beide standen toont zonder dat het paneel open hoeft.
    private let hotkeys: HotkeyStore
    /// De luister-stip, als die er is. Het paneel biedt "terug naar het midden" alleen
    /// als de stip gekoppeld is, zodat een dood knopje nooit verschijnt.
    private let listeningIndicator: ListeningIndicatorController?
    private var model = ControllerState()
    /// De laatste uitvoerfout, bewaard los van `model` zodat `refresh()` (die het
    /// model herbouwt uit microfoon + auto-start) de melding niet wist (R9).
    private var errorNotice: String?
    /// De popover die het bedieningspaneel toont, geankerd aan de statusitem-knop, en
    /// de controller die het model erin tekent. Vervangt het vroegere `NSMenu`: een menu
    /// kan geen schuifregelaar met een zichtbare waarde dragen (zie `MenuBarPanel.swift`).
    private let popover = NSPopover()
    private let panel = MenuBarPanelController()
    /// Leest de drie permissiestatussen live (PL-729); cachet niets, zodat een omgezet
    /// vinkje klopt zonder herstart.
    private let permissionsProbe: PermissionsProbe
    /// Of er nu een permissie ontbreekt; het statusitem toont dat dan zonder het menu.
    private var permissionsMissing = false
    /// De korte permissie-melding voor het paneel, of nil als alles er is.
    private var permissionBanner: String?
    /// Aangeroepen als de hands-free-toggle via het paneel wisselt, met de nieuwe stand.
    /// De delegate hangt hier het starten/stoppen van de luister-keten aan, zodat de
    /// paneel-klik dezelfde keten start als de globale sneltoets (niet enkel een boolean).
    public var onHandsFreeChanged: ((Bool) -> Void)?

    public init(
        selector: MicrophoneSelector = MicrophoneSelector(),
        launchAgent: LaunchAgentManager,
        hotkeys: HotkeyStore = HotkeyStore(defaults: UserDefaults.standard),
        listeningIndicator: ListeningIndicatorController? = nil,
        permissionsProbe: PermissionsProbe = PermissionsProbe()
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.selector = selector
        self.launchAgent = launchAgent
        self.hotkeys = hotkeys
        self.listeningIndicator = listeningIndicator
        self.permissionsProbe = permissionsProbe
        self.model = ControllerState()
        super.init()
        configurePopover()
        refresh()
    }

    /// Zet de popover op, wire de paneel-callbacks naar dezelfde acties die het menu
    /// vroeger had, en laat een klik op de statusitem-knop het paneel openen/sluiten.
    private func configurePopover() {
        popover.behavior = .transient
        popover.contentViewController = panel

        panel.onToggleHandsFree = { [weak self] isOn in
            guard let self else { return }
            // Dezelfde stand die de globale sneltoets zet; daarna de balk hertekenen en
            // de luister-keten starten/stoppen (niet enkel de boolean wisselen).
            self.hotkeys.setOn(isOn, for: .handsFree)
            self.refreshHotkeyState()
            self.onHandsFreeChanged?(isOn)
        }
        panel.onToggleAutoEnter = { [weak self] isOn in
            self?.hotkeys.setOn(isOn, for: .autoEnter)
            self?.refreshHotkeyState()
        }
        // Terug naar het midden: zet de luister-stip terug (PL-737). Alleen gekoppeld
        // als er een stip is; de knop verschijnt anders niet (`canRecenter`).
        panel.onRecenter = { [weak self] in self?.listeningIndicator?.resetToCenter() }
        panel.onSelectDevice = { [weak self] id in
            guard let self,
                  let device = self.model.devices.first(where: { $0.uniqueID == id }) else { return }
            self.selector.select(device)
            self.refresh()
        }
        panel.onFooterAction = { [weak self] action in
            switch action {
            case .settings: self?.openHotkeySettings()
            case .history: break   // uit tot PL-757 de inhoud levert
            case .quit: self?.quit()
            }
        }

        refreshPermissions()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
        }
    }

    /// Opent of sluit het bedieningspaneel onder de statusitem-knop. Leest de
    /// permissiestatus vers vóór het tonen, zodat een omgezet vinkje klopt zonder herstart.
    @objc private func togglePanel(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            refreshPermissions()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Opent het bedieningspaneel — gebruikt om de permissie-sectie bij de eerste start
    /// aan te bieden (PL-729), wanneer het gat het grootst is.
    public func openPanel() {
        guard let button = statusItem.button, !popover.isShown else { return }
        refreshPermissions()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Leest de drie permissiestatussen live en bewaart wat het paneel ervan toont.
    ///
    /// De volledige sectie staat sinds PL-788 in het instellingenvenster; hier blijft
    /// alleen een bannertje plus de waarschuwingsdriehoek op het statusitem. Die twee
    /// samen zijn de enige melding die je ziet als je nooit iets opent, en dat was de
    /// eis die bij de verhuizing niet mocht sneuvelen.
    private func refreshPermissions() {
        let snapshot = permissionsProbe.snapshot()
        permissionsMissing = snapshot.anyMissing
        permissionBanner = snapshot.bannerText
        drawStatusButton()
    }

    /// Opent het juiste Systeeminstellingen-paneel voor de permissie (mensentest; niet in
    /// de suite aangeroepen). De URL en zijn twee kandidaat-varianten staan in
    /// `PermissionKind.settingsURLString`.
    private func openPrivacySettings(for kind: PermissionKind) {
        guard let url = URL(string: kind.settingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Hoogte van de samengestelde statusbalk-glyph in punten; de menubalk schaalt
    /// een template-`NSImage` naar zijn dikte, dit bepaalt de tekenresolutie.
    private static let statusGlyphHeight: CGFloat = 18

    /// Tekent de staat plus beide hotkey-standen als één rij SF Symbols op de
    /// statusbalk-knop, zonder tekstlabel — de vroegere "HF● AE○"-tekst is nu
    /// `mic.fill`/`mic.slash` (hands-free) en `arrow.turn.down.left(.circle)`
    /// (auto-enter), zie `HotkeyStatus.statusSymbols()` (PL-730). Beide toggles
    /// blijven zo afleesbaar zonder het menu te openen (R3, spec PL-704). De hele
    /// knop krijgt een VoiceOver-samenvatting via `accessibilityLabel`.
    private func drawStatusButton() {
        guard let button = statusItem.button else { return }
        let status = hotkeys.status()
        var symbols: [(name: String, active: Bool, label: String)] = [
            (model.state.symbolName, true, model.state.menuLabel)
        ]
        symbols += status.statusSymbols().map { ($0.systemName, $0.isActive, $0.accessibilityLabel) }
        // Ontbrekende permissie zichtbaar zonder het paneel te openen: een waarschuwings-
        // glyph vooraan (PL-729). Zo zag Erik de uitgezette Toegankelijkheid meteen.
        if permissionsMissing {
            symbols.insert(
                ("exclamationmark.triangle.fill", true, "Er ontbreekt een permissie"),
                at: 0)
        }

        button.image = Self.composedStatusImage(from: symbols)
        button.imagePosition = .imageOnly
        button.title = ""
        button.setAccessibilityLabel(status.accessibilityLabel)
    }

    /// Zet een rij symbolen om in één template-`NSImage`: elk symbool naast elkaar,
    /// actieve vol en inactieve gedimd voor extra contrast. Template-rendering laat
    /// de balk zelf tinten, zodat de glyph in licht en donker meekleurt. Een ontbrekend
    /// SF Symbol wordt overgeslagen zodat de knop nooit leeg blijft.
    private static func composedStatusImage(
        from symbols: [(name: String, active: Bool, label: String)]
    ) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: statusGlyphHeight, weight: .regular)
        let images: [(NSImage, Bool)] = symbols.compactMap { spec in
            guard let base = NSImage(systemSymbolName: spec.name, accessibilityDescription: spec.label),
                  let img = base.withSymbolConfiguration(config) else { return nil }
            return (img, spec.active)
        }
        let gap: CGFloat = 3
        let width = images.reduce(0) { $0 + $1.0.size.width } + gap * CGFloat(max(images.count - 1, 0))
        let height = images.map(\.0.size.height).max() ?? statusGlyphHeight
        let canvas = NSImage(size: NSSize(width: max(width, 1), height: max(height, 1)))
        canvas.lockFocus()
        var x: CGFloat = 0
        for (img, active) in images {
            let y = (height - img.size.height) / 2
            img.draw(
                at: NSPoint(x: x, y: y), from: .zero,
                operation: .sourceOver, fraction: active ? 1.0 : 0.35)
            x += img.size.width + gap
        }
        canvas.unlockFocus()
        canvas.isTemplate = true
        return canvas
    }

    /// Hertekent na een hotkey-toggle, zodat de balk en het paneel de nieuwe stand
    /// meteen tonen.
    public func refreshHotkeyState() {
        rebuildPanel()
    }

    /// Gezet door de delegate, die de live hotkey-manager kent om een opnieuw
    /// ingestelde combinatie meteen te registreren. Krijgt de actie en de nieuwe
    /// combinatie zodra het instellingenvenster er een toewijst.
    public var onRebindHotkey: ((HotkeyAction, KeyCombo) -> Void)?
    private var hotkeySettings: HotkeySettingsWindowController?

    /// Opent het sneltoets-instellingenvenster (per actie een opnameveld + reset-knop).
    /// De store is dezelfde als het statusitem gebruikt, dus een nieuwe combinatie is
    /// meteen elders zichtbaar; `onRebindHotkey` registreert hem live.
    /// Bouwt het instellingenvenster: sneltoetsen, auto-start en de permissiesectie
    /// (PL-788). Het venster opent zelf geen Systeeminstellingen — die knop komt hierheen
    /// terug, zodat het echt openen een mensentest blijft (ROE §2). Een schrijffout bij
    /// auto-start landt zichtbaar in de statusregel in plaats van stil te verdwijnen (R9).
    private func makeSettingsWindow() -> HotkeySettingsWindowController {
        let controller = HotkeySettingsWindowController(
            store: hotkeys,
            permissionsProbe: permissionsProbe,
            launchAgent: launchAgent,
            onRebind: { [weak self] action, combo in
                self?.onRebindHotkey?(action, combo)
                self?.refreshHotkeyState()
            })
        controller.onOpenPrivacySettings = { [weak self] kind in
            self?.openPrivacySettings(for: kind)
        }
        controller.onAutoStartError = { [weak self] message in self?.showError(message) }
        return controller
    }

    @objc private func openHotkeySettings() {
        let controller = hotkeySettings ?? makeSettingsWindow()
        hotkeySettings = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Herbouwt het model uit de huidige microfoon-resolutie en auto-start-stand,
    /// en tekent het paneel opnieuw.
    public func refresh() {
        let resolution = selector.resolve()
        model = ControllerState(
            state: model.state,
            fallbackNotice: resolution.notice?.message,
            errorNotice: errorNotice,
            devices: selector.availableDevices(),
            selectedDeviceID: resolution.device?.uniqueID ?? selector.selectedDeviceID,
            autoStartEnabled: launchAgent.isEnabled())
        rebuildPanel()
    }

    /// Het apparaat dat nu gebruikt wordt (of nil = systeemstandaard), zodat de
    /// hands-free-keten op dezelfde microfoon opneemt als het menu toont.
    public func resolvedDevice() -> DeviceInfo? {
        selector.resolve().device
    }

    /// Toont (of wist met nil) een uitvoerfout in de statusregel en tekent opnieuw.
    /// Geen stille mislukking: een falende TextOutput (bv. ontbrekende Accessibility)
    /// wordt zo zichtbaar (R9).
    public func showError(_ message: String?) {
        errorNotice = message
        model.errorNotice = message
        rebuildPanel()
    }

    /// Werkt de getoonde staat bij (aangeroepen door de capture-pijplijn in een
    /// latere taak) en tekent het icoon en het paneel opnieuw.
    public func update(state: SpeechState) {
        model.state = state
        rebuildPanel()
    }

    /// Bouwt het paneel-model uit de huidige microfoon-, hotkey- en versiegegevens en
    /// tekent het paneel opnieuw. De statusbalk-glyph gaat mee (`drawStatusButton`).
    /// Het versienummer komt uit de bundel (`CFBundleShortVersionString`, gezet door
    /// `scripts/build-app.sh`); los gestart zonder bundel valt het terug op `0.0.0`.
    private func rebuildPanel() {
        drawStatusButton()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.0.0"
        panel.apply(MenuBarPanelModel(
            state: model.state,
            version: version,
            handsFreeOn: hotkeys.isOn(.handsFree),
            handsFreeShortcut: hotkeys.combo(for: .handsFree).display,
            autoEnterOn: hotkeys.isOn(.autoEnter),
            autoEnterShortcut: hotkeys.combo(for: .autoEnter).display,
            permissionBanner: permissionBanner,
            devices: model.devices,
            selectedDeviceID: model.selectedDeviceID,
            fallbackNotice: model.fallbackNotice,
            errorNotice: model.errorNotice,
            canRecenter: listeningIndicator != nil))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// De app-delegate: knoopt de hele keten aaneen. Houdt de paneel-controller,
/// hotkey-manager, warm-gehouden transcriber en de luister-stip vast, en start/stopt
/// de hands-free-keten op de toggle (sneltoets én paneel). `@MainActor` omdat alle
/// AppKit-raakvlakken op de hoofdthread horen; zet de activatiepolicy op `.accessory`
/// zodat er geen Dock-icoon verschijnt, ook niet bij los starten.
@MainActor
public final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?
    private var hotkeyManager: GlobalHotkeyManager?
    /// De hotkey-store, vastgehouden zodat een geweigerde microfoontoestemming de
    /// hands-free-toggle kan terugzetten (de keten start dan niet).
    private var hotkeys: HotkeyStore?
    private var listeningIndicator: ListeningIndicatorController?
    /// De meter die de stip pollt; de keten voedt hem met het echte audioniveau.
    private var levelMeter: AudioLevelMeter?

    /// Warm gehouden over sessies heen: het transcriptie-model laadt bij de eerste
    /// keer aanzetten, niet per uiting (koud 0,47 s, warm 0,12 s).
    private let transcriber = WarmTranscriber()
    /// Het echte logbestand (`~/.pitchlab/klep/klep.log.jsonl`), gedeeld door de keten en de
    /// toggle-route zodat de app een spoor achterlaat in plaats van blind te draaien.
    private let diagnostics = DiagnosticLog()
    /// De keten van de huidige luister-sessie plus de taak die hem draait. Vers per
    /// hands-free-aan, opgeruimd bij uit; het model blijft warm in `transcriber`.
    private var session: HandsFreeController?
    private var runTask: Task<Void, Never>?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let executablePath = Bundle.main.executablePath
            ?? CommandLine.arguments.first
            ?? ""
        let launchAgent = LaunchAgentManager(
            agent: LaunchAgent(executablePath: executablePath))
        let hotkeys = HotkeyStore(defaults: UserDefaults.standard)
        self.hotkeys = hotkeys
        // De toggles op hun opstartstand zetten, niet alleen tonen (PL-742). Hands-free
        // gaat hard op uit zodat het menu de werkelijke, niet-luisterende stand toont;
        // de keten wordt hier niet gestart. Auto-enter blijft zoals bewaard.
        diagnostics.log(.handsFreeRestored(on: hotkeys.isOn(.handsFree)))
        let launchState = LaunchState(savedAutoEnter: hotkeys.isOn(.autoEnter))
        hotkeys.setOn(launchState.handsFreeOn, for: .handsFree)
        hotkeys.setOn(launchState.autoEnterOn, for: .autoEnter)
        // Eén stip-controller met de meter die de keten voedt: het paneel koppelt hem
        // voor "terug naar het midden", de keten toont/verbergt hem op luister-staat.
        let meter = AudioLevelMeter()
        let indicator = ListeningIndicatorController(levelSource: meter)
        self.levelMeter = meter
        self.listeningIndicator = indicator
        let controller = MenuBarController(
            launchAgent: launchAgent, hotkeys: hotkeys, listeningIndicator: indicator)
        self.controller = controller

        // De twee globale hotkeys registreren, het statusitem hertekenen bij een
        // toggle, en de hands-free-toggle de keten laten starten/stoppen. Ontbreekt
        // Input Monitoring, dan zet `start()` een expliciete melding klaar in plaats
        // van stil te falen (spec PL-704).
        let manager = GlobalHotkeyManager(store: hotkeys)
        manager.onToggle = { [weak self] action, isOn in
            guard let self else { return }
            self.controller?.refreshHotkeyState()
            if action == .handsFree { self.setHandsFree(isOn, reason: "sneltoets") }
        }
        // Dezelfde keten starten/stoppen als de hands-free-toggle via het paneel wisselt.
        controller.onHandsFreeChanged = { [weak self] isOn in
            self?.setHandsFree(isOn, reason: "paneel")
        }
        // Een in het instellingenvenster opnieuw ingestelde combinatie meteen live
        // registreren, zodat de nieuwe sneltoets werkt zonder de app te herstarten.
        controller.onRebindHotkey = { [weak manager] action, combo in
            manager?.rebind(action, to: combo)
        }
        if !manager.start(), let notice = manager.permissionNotice {
            let alert = NSAlert()
            alert.messageText = "Sneltoetsen uitgeschakeld"
            alert.informativeText = notice
            alert.runModal()
        }
        self.hotkeyManager = manager

        // Bied de permissie-sectie aan bij de eerste start (PL-729): dan is het gat het
        // grootst en staan de drie permissies meestal nog uit. Eén keer, daarna niet meer.
        let launchedKey = "pitchlab-speech.hasLaunchedBefore"
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: launchedKey)
        if FirstRunGate.shouldOffer(hasLaunchedBefore: hasLaunchedBefore) {
            UserDefaults.standard.set(true, forKey: launchedKey)
            controller.openPanel()
        }
    }

    /// Start of stop hands-free op basis van de nieuwe toggle-stand. `reason` is de
    /// bron (sneltoets of menu) en landt in de log zodat een aan/uit-flip een spoor heeft.
    private func setHandsFree(_ isOn: Bool, reason: String) {
        diagnostics.log(isOn ? .handsFreeOn(reason: reason) : .handsFreeOff(reason: reason))
        if isOn { startHandsFree() } else { stopHandsFree() }
    }

    /// Hands-free aan: wis een oude fout, toon de luister-staat en draai een verse
    /// keten op het gekozen apparaat. De `HandsFreeController` toont de stip (via de
    /// bridge), warmt het model één keer en stuurt elke uiting naar de uitvoerlaag; een
    /// uitvoerfout landt in het paneel in plaats van stil te falen (R9). Auto-enter wordt
    /// live uit de bewaarde stand gelezen zodat hij mid-sessie aan/uit kan.
    private func startHandsFree() {
        guard session == nil, let controller, let indicator = listeningIndicator,
              let meter = levelMeter else { return }
        controller.showError(nil)
        controller.update(state: .listening)
        let device = controller.resolvedDevice()

        let handsFree = HandsFreeController(
            audio: MicrophoneCapture(),
            transcriber: transcriber,
            sink: TextOutputSink(),
            indicator: MainActorListeningIndicator(controller: indicator, meter: meter),
            permission: AVCaptureMicrophonePermission(),
            diagnostics: diagnostics,
            autoEnter: { UserDefaults.standard.bool(forKey: HotkeyAction.autoEnter.stateKey) })
        self.session = handsFree

        runTask = Task { [weak self, weak controller] in
            await handsFree.setOnError { message in
                Task { @MainActor in controller?.showError(message) }
            }
            let started = await handsFree.run(device: device)
            if !started {
                // Toestemming geweigerd: de reden staat al in het paneel (via onError →
                // showError). Zet de toggle terug en ruim de sessie op, anders lijkt
                // hands-free aan te staan terwijl er niets luistert.
                await MainActor.run { self?.handsFreeStartDenied() }
            }
        }
    }

    /// Ruimt op nadat de keten niet kon starten (microfoontoestemming geweigerd): zet
    /// de hands-free-toggle terug, wis de sessie en zet de staat op gereed.
    private func handsFreeStartDenied() {
        session = nil
        runTask = nil
        hotkeys?.setOn(false, for: .handsFree)
        controller?.update(state: .idle)
        controller?.refreshHotkeyState()
    }

    /// Hands-free uit: stop de opname (de stream sluit, de keten verbergt de stip),
    /// zet de staat terug. Het model blijft warm in `transcriber`.
    private func stopHandsFree() {
        guard let handsFree = session else { return }
        controller?.update(state: .idle)
        session = nil
        runTask = nil
        Task { await handsFree.requestStop() }
    }
}

/// Startpunt voor de executable-target: bouwt een NSApplication zonder Dock-icoon
/// en draait de runloop. Mensentest — vraagt een echte sessie.
@MainActor
public func runMenuBarApp() -> Never {
    let app = NSApplication.shared
    let delegate = MenuBarAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    // NSApplication.run keert niet terug; deze regel houdt de Never-belofte.
    exit(0)
}
#endif
