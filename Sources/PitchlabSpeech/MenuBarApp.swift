/// Menubalk-app: statusitem zonder Dock-icoon, een menu dat de staat, de actieve
/// microfoon en de ingestelde hotkeys toont en microfoonkeuze biedt, plus
/// auto-start via een LaunchAgent die de app zelf schrijft en verwijdert.
///
/// Twee lagen, gescheiden zodat de logica zonder AppKit-runloop te testen is:
///  - Pure model-laag (`SpeechState`, `HotkeyBinding`, `MenuModel`, `LaunchAgent`,
///    `LaunchAgentManager`): de menu-teksten, de checkmarks en de LaunchAgent-plist
///    worden hier bepaald. Geen `NSStatusItem`, geen runloop — direct te testen.
///  - AppKit-laag (`MenuBarController`, `runMenuBarApp`), onder `#if canImport(AppKit)`:
///    de lijm die het model op een echte `NSStatusItem` + `NSMenu` tekent en de
///    acties aan `MicrophoneSelector` en `LaunchAgentManager` hangt. Compileert in
///    de gate; het echt tonen van een statusitem is een mensentest (PRD).
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

// MARK: - Hotkeys

/// Eén ingestelde sneltoets zoals het menu hem toont. De echte hotkey-afvang is
/// een latere taak; hier draagt het model alleen de weergave, zodat het menu de
/// ingestelde toetsen laat zien (spec) en de tekst te testen is.
public struct HotkeyBinding: Sendable, Equatable {
    /// Wat de toets doet, bv. "Dicteren (push-to-talk)".
    public let action: String
    /// De toetscombinatie als leesbare tekens, bv. "⌥Space".
    public let keys: String

    public init(action: String, keys: String) {
        self.action = action
        self.keys = keys
    }

    /// De menuregel: actie plus toetsen.
    public var menuLine: String { "\(action): \(keys)" }

    /// De sneltoetsen zoals de app ze standaard toont tot een hotkey-taak ze
    /// instelbaar maakt. Push-to-talk op ⌥Space, wisselen op ⌥⇧Space.
    public static let defaults: [HotkeyBinding] = [
        HotkeyBinding(action: "Dicteren (push-to-talk)", keys: "⌥Space"),
        HotkeyBinding(action: "Dicteren aan/uit", keys: "⌥⇧Space"),
    ]
}

// MARK: - Menu-model

/// Het volledige menu als data. Levert per onderdeel de tekst en de checkmarks,
/// zodat de AppKit-laag alleen nog `NSMenuItem`s hoeft te maken en de tests de
/// teksten direct kunnen nalopen zonder runloop.
public struct MenuModel: Sendable, Equatable {
    public var state: SpeechState
    /// De naam van de microfoon die nu gebruikt wordt, of nil als er geen is.
    public var activeMicrophone: String?
    /// Melding als de gekozen microfoon verdween en de app terugviel (R6), of nil.
    public var fallbackNotice: String?
    public var hotkeys: [HotkeyBinding]
    /// De keuzelijst voor de microfoon-submenu.
    public var devices: [DeviceInfo]
    /// De id van het gekozen apparaat, voor de checkmark in het submenu.
    public var selectedDeviceID: String?
    public var autoStartEnabled: Bool

    public init(
        state: SpeechState = .idle,
        activeMicrophone: String? = nil,
        fallbackNotice: String? = nil,
        hotkeys: [HotkeyBinding] = HotkeyBinding.defaults,
        devices: [DeviceInfo] = [],
        selectedDeviceID: String? = nil,
        autoStartEnabled: Bool = false
    ) {
        self.state = state
        self.activeMicrophone = activeMicrophone
        self.fallbackNotice = fallbackNotice
        self.hotkeys = hotkeys
        self.devices = devices
        self.selectedDeviceID = selectedDeviceID
        self.autoStartEnabled = autoStartEnabled
    }

    /// De regel die de actieve microfoon toont.
    public var microphoneLine: String {
        if let activeMicrophone { return "Microfoon: \(activeMicrophone)" }
        return "Microfoon: (geen)"
    }

    /// De hotkey-regels, één per binding.
    public var hotkeyLines: [String] { hotkeys.map(\.menuLine) }

    /// De titel van de auto-start-schakelaar (de checkmark komt van `autoStartEnabled`).
    public var autoStartTitle: String { "Start automatisch bij inloggen" }

    /// Het microfoon-submenu als paren titel + of hij aangevinkt is.
    public func deviceItems() -> [(title: String, isSelected: Bool)] {
        devices.map { ($0.localizedName, $0.uniqueID == selectedDeviceID) }
    }

    /// De statische regels van bovenaf, in menuvolgorde: staat, microfoon,
    /// eventueel de terugval-melding, dan de hotkeys. Handig voor de test die de
    /// hele bovenkant in één keer nakijkt.
    public func headerLines() -> [String] {
        var lines = [state.menuLabel, microphoneLine]
        if let fallbackNotice { lines.append("⚠︎ \(fallbackNotice)") }
        lines.append(contentsOf: hotkeyLines)
        return lines
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

#if canImport(AppKit)
import AppKit

// MARK: - AppKit-laag (mensentest)

/// Tekent het `MenuModel` op een echt `NSStatusItem` + `NSMenu` en hangt de acties
/// aan `MicrophoneSelector` en `LaunchAgentManager`. Runtime niet gedekt door de
/// unit-tests: een statusitem tonen vraagt een NSApplication-runloop en is een
/// mensentest. De testbare logica zit in `MenuModel` en `LaunchAgent(Manager)`.
@MainActor
public final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let selector: MicrophoneSelector
    private let launchAgent: LaunchAgentManager
    /// De persistente stand van de twee globale hotkeys (hands-free, auto-enter),
    /// zodat het statusitem beide standen toont zonder dat het menu open hoeft.
    private let hotkeys: HotkeyStore
    /// De luister-stip, als die er is. Het menu biedt "terug naar het midden" alleen
    /// als de stip gekoppeld is, zodat een dood item nooit verschijnt.
    private let listeningIndicator: ListeningIndicatorController?
    private var model: MenuModel

    public init(
        selector: MicrophoneSelector = MicrophoneSelector(),
        launchAgent: LaunchAgentManager,
        hotkeys: HotkeyStore = HotkeyStore(defaults: UserDefaults.standard),
        listeningIndicator: ListeningIndicatorController? = nil
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.selector = selector
        self.launchAgent = launchAgent
        self.hotkeys = hotkeys
        self.listeningIndicator = listeningIndicator
        self.model = MenuModel()
        super.init()
        refresh()
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

    /// Hertekent na een hotkey-toggle, zodat de balk de nieuwe stand meteen toont.
    public func refreshHotkeyState() {
        rebuildMenu()
    }

    /// Herbouwt het model uit de huidige microfoon-resolutie en auto-start-stand,
    /// en tekent het menu opnieuw.
    public func refresh() {
        let resolution = selector.resolve()
        model = MenuModel(
            state: model.state,
            activeMicrophone: resolution.device?.localizedName,
            fallbackNotice: resolution.notice?.message,
            hotkeys: HotkeyBinding.defaults,
            devices: selector.availableDevices(),
            selectedDeviceID: resolution.device?.uniqueID ?? selector.selectedDeviceID,
            autoStartEnabled: launchAgent.isEnabled())
        rebuildMenu()
    }

    /// Werkt de getoonde staat bij (aangeroepen door de capture-pijplijn in een
    /// latere taak) en tekent het icoon en de eerste menuregel opnieuw.
    public func update(state: SpeechState) {
        model.state = state
        drawStatusButton()
        rebuildMenu()
    }

    private func rebuildMenu() {
        drawStatusButton()
        let menu = NSMenu()

        for line in model.headerLines() {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        // De twee globale toggles voluit, onder de dicteer-sneltoetsen.
        for line in hotkeys.status().menuLines() {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let micMenu = NSMenu()
        for device in model.devices {
            let item = NSMenuItem(
                title: device.localizedName, action: #selector(chooseDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uniqueID
            item.state = (device.uniqueID == model.selectedDeviceID) ? .on : .off
            micMenu.addItem(item)
        }
        if model.devices.isEmpty {
            let empty = NSMenuItem(title: "(geen microfoons gevonden)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            micMenu.addItem(empty)
        }
        let micItem = NSMenuItem(title: "Kies microfoon", action: nil, keyEquivalent: "")
        micItem.submenu = micMenu
        menu.addItem(micItem)

        let autoStart = NSMenuItem(
            title: model.autoStartTitle, action: #selector(toggleAutoStart), keyEquivalent: "")
        autoStart.target = self
        autoStart.state = model.autoStartEnabled ? .on : .off
        menu.addItem(autoStart)

        // Terughaalknop voor de stip: alleen tonen als er een stip gekoppeld is.
        if listeningIndicator != nil {
            let recenter = NSMenuItem(
                title: "Zet luister-stip terug naar het midden",
                action: #selector(recenterIndicator), keyEquivalent: "")
            recenter.target = self
            menu.addItem(recenter)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Stop pitchlab-speech", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func chooseDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let device = model.devices.first(where: { $0.uniqueID == id }) else { return }
        selector.select(device)
        refresh()
    }

    @objc private func toggleAutoStart() {
        _ = try? launchAgent.toggle()
        refresh()
    }

    @objc private func recenterIndicator() {
        listeningIndicator?.resetToCenter()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// De app-delegate: houdt de controller vast en zet de activatiepolicy op
/// `.accessory` zodat er geen Dock-icoon verschijnt, ook niet bij los starten.
public final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?
    private var hotkeyManager: GlobalHotkeyManager?
    private var listeningIndicator: ListeningIndicatorController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let executablePath = Bundle.main.executablePath
            ?? CommandLine.arguments.first
            ?? ""
        let launchAgent = LaunchAgentManager(
            agent: LaunchAgent(executablePath: executablePath))
        let hotkeys = HotkeyStore(defaults: UserDefaults.standard)
        // De luister-stip alvast koppelen zodat het "terug naar het midden"-menu-item
        // werkt; het tonen/verbergen op luister-staat blijft aan de integratie.
        let indicator = ListeningIndicatorController(levelSource: AudioLevelMeter())
        self.listeningIndicator = indicator
        let controller = MenuBarController(
            launchAgent: launchAgent, hotkeys: hotkeys, listeningIndicator: indicator)
        self.controller = controller

        // De twee globale hotkeys registreren en het statusitem hertekenen bij een
        // toggle. Ontbreekt Input Monitoring, dan zet `start()` een expliciete
        // melding klaar in plaats van stil te falen (spec PL-704).
        let manager = GlobalHotkeyManager(store: hotkeys)
        manager.onToggle = { [weak controller] _, _ in
            controller?.refreshHotkeyState()
        }
        if !manager.start(), let notice = manager.permissionNotice {
            let alert = NSAlert()
            alert.messageText = "Sneltoetsen uitgeschakeld"
            alert.informativeText = notice
            alert.runModal()
        }
        self.hotkeyManager = manager
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
