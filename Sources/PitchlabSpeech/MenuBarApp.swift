/// Menubalk-app: statusitem zonder Dock-icoon, een menu dat de staat, de actieve
/// microfoon en de ingestelde hotkeys toont en microfoonkeuze biedt, plus
/// auto-start via een LaunchAgent die de app zelf schrijft en verwijdert.
///
/// Twee lagen, gescheiden zodat de logica zonder AppKit-runloop te testen is:
///  - Pure model-laag (`SpeechState`, `HotkeyToggleRow`, `MenuModel`, `LaunchAgent`,
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

// MARK: - Hotkey-toggles

/// Eén klikbare toggle-regel in het menu: welke actie, of hij aanstaat (voor de
/// checkmark) en de ingestelde sneltoets die het menu ernaast als hint toont. Puur,
/// zodat de test de titel, de stand en de hint kan nalopen zonder NSMenu.
public struct HotkeyToggleRow: Sendable, Equatable {
    public let action: HotkeyAction
    /// De leesbare naam van de toggle, bv. "Hands-free".
    public let title: String
    /// Of de toggle aanstaat — bepaalt de checkmark.
    public let isOn: Bool
    /// De ingestelde sneltoets als leesbare hint, bv. "⌃⌥H".
    public let shortcut: String

    public init(action: HotkeyAction, title: String, isOn: Bool, shortcut: String) {
        self.action = action
        self.title = title
        self.isOn = isOn
        self.shortcut = shortcut
    }

    /// De menutitel: de naam met de sneltoets als hint ernaast. De stand komt van de
    /// checkmark (`isOn`), niet uit de tekst.
    public var menuTitle: String { "\(title)  \(shortcut)" }
}

/// De twee klikbare toggle-regels met hun stand en ingestelde sneltoets uit de
/// hotkey-store — precies wat er echt geldt. Vervangt de vroegere hardgecodeerde
/// push-to-talk-regels: geen verzonnen toetsen meer, alleen wat de store draagt.
public func hotkeyToggleRows(store: HotkeyStore) -> [HotkeyToggleRow] {
    HotkeyAction.allCases.map { action in
        HotkeyToggleRow(
            action: action,
            title: action.title,
            isOn: store.isOn(action),
            shortcut: store.combo(for: action).display)
    }
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
    /// De keuzelijst voor de microfoon-submenu.
    public var devices: [DeviceInfo]
    /// De id van het gekozen apparaat, voor de checkmark in het submenu.
    public var selectedDeviceID: String?
    public var autoStartEnabled: Bool

    public init(
        state: SpeechState = .idle,
        activeMicrophone: String? = nil,
        fallbackNotice: String? = nil,
        devices: [DeviceInfo] = [],
        selectedDeviceID: String? = nil,
        autoStartEnabled: Bool = false
    ) {
        self.state = state
        self.activeMicrophone = activeMicrophone
        self.fallbackNotice = fallbackNotice
        self.devices = devices
        self.selectedDeviceID = selectedDeviceID
        self.autoStartEnabled = autoStartEnabled
    }

    /// De regel die de actieve microfoon toont.
    public var microphoneLine: String {
        if let activeMicrophone { return "Microfoon: \(activeMicrophone)" }
        return "Microfoon: (geen)"
    }

    /// De titel van de auto-start-schakelaar (de checkmark komt van `autoStartEnabled`).
    public var autoStartTitle: String { "Start automatisch bij inloggen" }

    /// Het microfoon-submenu als paren titel + of hij aangevinkt is.
    public func deviceItems() -> [(title: String, isSelected: Bool)] {
        devices.map { ($0.localizedName, $0.uniqueID == selectedDeviceID) }
    }

    /// De statische regels van bovenaf, in menuvolgorde: staat, microfoon en
    /// eventueel de terugval-melding. De hotkey-toggles komen daaronder als eigen
    /// klikbare items (`hotkeyToggleRows`), niet als tekst hier.
    public func headerLines() -> [String] {
        var lines = [state.menuLabel, microphoneLine]
        if let fallbackNotice { lines.append("⚠︎ \(fallbackNotice)") }
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
    private var model: MenuModel

    public init(
        selector: MicrophoneSelector = MicrophoneSelector(),
        launchAgent: LaunchAgentManager,
        hotkeys: HotkeyStore = HotkeyStore(defaults: UserDefaults.standard)
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.selector = selector
        self.launchAgent = launchAgent
        self.hotkeys = hotkeys
        self.model = MenuModel()
        super.init()
        refresh()
    }

    /// De statusbalk-titel die beide hotkey-standen samenvat, bv. "HF● AE○".
    private var hotkeyStatusTitle: String { hotkeys.status().statusItemTitle }

    /// Tekent icoon plus hotkey-standen op de statusbalk-knop. Beide toggles zijn
    /// zo afleesbaar zonder het menu te openen (spec PL-704).
    private func drawStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: model.state.symbolName,
            accessibilityDescription: model.state.menuLabel)
        button.imagePosition = .imageLeading
        button.title = " " + hotkeyStatusTitle
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

        // De twee globale toggles als klikbare items: klikken wisselt dezelfde stand
        // als de sneltoets, de checkmark toont de stand, de sneltoets staat ernaast
        // als hint.
        for row in hotkeyToggleRows(store: hotkeys) {
            let item = NSMenuItem(
                title: row.menuTitle, action: #selector(toggleHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row.action.rawValue
            item.state = row.isOn ? .on : .off
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

    /// Wisselt de aangeklikte hotkey-toggle — dezelfde `HotkeyStore.toggle` die de
    /// globale sneltoets aanroept — en hertekent het menu zodat de checkmark en de
    /// statusbalk de nieuwe stand tonen.
    @objc private func toggleHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = HotkeyAction(rawValue: raw) else { return }
        hotkeys.toggle(action)
        refreshHotkeyState()
    }

    @objc private func toggleAutoStart() {
        _ = try? launchAgent.toggle()
        refresh()
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

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let executablePath = Bundle.main.executablePath
            ?? CommandLine.arguments.first
            ?? ""
        let launchAgent = LaunchAgentManager(
            agent: LaunchAgent(executablePath: executablePath))
        let hotkeys = HotkeyStore(defaults: UserDefaults.standard)
        let controller = MenuBarController(launchAgent: launchAgent, hotkeys: hotkeys)
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
