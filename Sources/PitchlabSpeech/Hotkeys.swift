/// Twee globale sneltoetsen die vanuit elke app werken: hands-free aan/uit en
/// auto-enter aan/uit. Twee onafhankelijke toggles, elk herdefinieerbaar en
/// persistent, met hun stand afleesbaar in het statusitem zonder het menu te
/// openen. Ontbreekt de Input Monitoring-permissie, dan geeft de app een
/// expliciete melding in plaats van stil te falen.
///
/// Twee lagen, net als `MenuBarApp.swift`, zodat de logica zonder Carbon of een
/// runloop te testen is:
///  - Pure model-laag (`HotkeyAction`, `KeyCombo`, `HotkeyStore`, `HotkeyStatus`,
///    `InputMonitoring.notice`): de toetscombinatie-weergave, het persisteren, de
///    twee toggle-standen, de statusbalk-tekst en de permissie-melding worden hier
///    bepaald. Geen Carbon, geen `NSStatusItem` — direct te testen (`HotkeysTests`).
///  - Carbon/AppKit-laag (`GlobalHotkeyManager`, onder `#if canImport(Carbon)`):
///    `RegisterEventHotKey`, de C-event-handler en de Input Monitoring-check via
///    `IOHIDCheckAccess`. Compileert in de gate; het echt afvangen van een globale
///    toets en het verlenen van de permissie is een mensentest (PRD, ROE §2).

import Foundation

// MARK: - Acties

/// De twee globale toggles. Elk is onafhankelijk: een eigen sneltoets, een eigen
/// persistente aan/uit-stand.
public enum HotkeyAction: String, CaseIterable, Sendable {
    case handsFree
    case autoEnter

    /// De leesbare naam, voor het menu.
    public var title: String {
        switch self {
        case .handsFree: return "Hands-free"
        case .autoEnter: return "Auto-enter"
        }
    }

    /// Korte code voor het statusitem, zodat de balk beide standen toont zonder
    /// dat het menu open hoeft.
    public var badge: String {
        switch self {
        case .handsFree: return "HF"
        case .autoEnter: return "AE"
        }
    }

    /// Sleutel waaronder de ingestelde combinatie bewaard wordt.
    var comboKey: String { "hotkey.combo.\(rawValue)" }
    /// Sleutel waaronder de aan/uit-stand bewaard wordt.
    var stateKey: String { "hotkey.state.\(rawValue)" }

    /// Stabiele numerieke id voor de Carbon-registratie (`EventHotKeyID.id`).
    var hotkeyID: UInt32 {
        switch self {
        case .handsFree: return 1
        case .autoEnter: return 2
        }
    }

    init?(hotkeyID: UInt32) {
        switch hotkeyID {
        case 1: self = .handsFree
        case 2: self = .autoEnter
        default: return nil
        }
    }
}

// MARK: - Toetscombinatie

/// Eén sneltoets: een virtuele toetscode plus modifiers. Puur genoeg om te testen
/// en te persisteren zonder Carbon; de Carbon-maskers zijn stabiele constanten.
public struct KeyCombo: Sendable, Equatable {
    /// De virtuele toetscode (Carbon `kVK_*`), bv. 49 voor Spatie.
    public let keyCode: UInt32
    public let modifiers: Modifiers

    /// De vier modifier-toetsen als set. Rauwe waarden staan los van Carbon zodat
    /// dit type in de tests bruikbaar is zonder de Carbon-headers.
    public struct Modifiers: OptionSet, Sendable, Equatable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// De modifiers als glyphs in de vaste macOS-volgorde ⌃⌥⇧⌘.
    public var modifierGlyphs: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s
    }

    /// De combinatie als leesbare tekst, bv. "⌃⌥H".
    public var display: String { modifierGlyphs + KeyCombo.keyName(for: keyCode) }

    /// De combinatie als string voor persistentie: "<modifiers>:<keyCode>".
    public var persistString: String { "\(modifiers.rawValue):\(keyCode)" }

    /// Leest een combinatie terug uit `persistString`. Nil bij een kapotte string.
    public init?(persistString: String) {
        let parts = persistString.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let mods = UInt32(parts[0]),
              let code = UInt32(parts[1]) else { return nil }
        self.init(keyCode: code, modifiers: Modifiers(rawValue: mods))
    }

    /// De Carbon-modifier-maskers (`cmdKey`/`optionKey`/`controlKey`/`shiftKey`),
    /// als rauwe waarden zodat dit zonder de Carbon-headers te berekenen en te
    /// testen is. De waarden zijn stabiel: cmd=256, shift=512, option=2048,
    /// control=4096 (Carbon `Events.h`).
    public var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= 256 }
        if modifiers.contains(.shift) { m |= 512 }
        if modifiers.contains(.option) { m |= 2048 }
        if modifiers.contains(.control) { m |= 4096 }
        return m
    }

    /// De standaardcombinatie per actie, tot de gebruiker ze herdefinieert.
    /// Hands-free op ⌃⌥H, auto-enter op ⌃⌥E — buiten de dicteer-sneltoetsen die
    /// het menu al toont (⌥Space / ⌥⇧Space).
    public static func `default`(for action: HotkeyAction) -> KeyCombo {
        switch action {
        case .handsFree: return KeyCombo(keyCode: 4, modifiers: [.control, .option])   // H
        case .autoEnter: return KeyCombo(keyCode: 14, modifiers: [.control, .option])  // E
        }
    }

    /// Naam voor een handvol veelgebruikte toetsen; anders de rauwe code. Volledig
    /// benoemen vraagt de toetsindeling en is niet nodig voor de standaardtoetsen.
    static func keyName(for keyCode: UInt32) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "↩"
        case 53: return "⎋"
        case 4: return "H"
        case 14: return "E"
        case 0: return "A"
        case 8: return "C"
        case 2: return "D"
        default: return "key \(keyCode)"
        }
    }
}

// MARK: - Persistentie

/// Minimale sleutel/waarde-opslag voor de hotkeys, zodat de store getest kan
/// worden met een geheugen-implementatie in plaats van de echte `UserDefaults`.
public protocol HotkeyDefaults: AnyObject {
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: HotkeyDefaults {}

/// De persistente kant van de hotkeys: de ingestelde combinatie en de aan/uit-stand
/// per actie. Puur — geen Carbon, geen runloop — en dus volledig getest.
public final class HotkeyStore {
    private let defaults: HotkeyDefaults

    public init(defaults: HotkeyDefaults) {
        self.defaults = defaults
    }

    /// De ingestelde combinatie, of de standaard als er niets bewaard is of de
    /// bewaarde string kapot is.
    public func combo(for action: HotkeyAction) -> KeyCombo {
        if let s = defaults.string(forKey: action.comboKey),
           let combo = KeyCombo(persistString: s) {
            return combo
        }
        return KeyCombo.default(for: action)
    }

    /// Herdefinieert de sneltoets voor een actie en bewaart hem.
    public func setCombo(_ combo: KeyCombo, for action: HotkeyAction) {
        defaults.set(combo.persistString, forKey: action.comboKey)
    }

    /// De huidige aan/uit-stand (default uit).
    public func isOn(_ action: HotkeyAction) -> Bool {
        defaults.bool(forKey: action.stateKey)
    }

    /// Zet de stand hard.
    public func setOn(_ on: Bool, for action: HotkeyAction) {
        defaults.set(on, forKey: action.stateKey)
    }

    /// Wisselt de stand en geeft de nieuwe terug.
    @discardableResult
    public func toggle(_ action: HotkeyAction) -> Bool {
        let next = !isOn(action)
        setOn(next, for: action)
        return next
    }

    /// De stand van beide toggles, voor het statusitem.
    public func status() -> HotkeyStatus {
        HotkeyStatus(handsFree: isOn(.handsFree), autoEnter: isOn(.autoEnter))
    }
}

// MARK: - Statusitem-weergave

/// De stand van beide toggles, met de tekst die het statusitem toont zodat de
/// balk beide standen laat zien zonder dat het menu open hoeft (spec).
public struct HotkeyStatus: Sendable, Equatable {
    public var handsFree: Bool
    public var autoEnter: Bool

    public init(handsFree: Bool, autoEnter: Bool) {
        self.handsFree = handsFree
        self.autoEnter = autoEnter
    }

    /// Compacte titel voor de statusbalk-knop: aangevinkt vol (●), uit hol (○),
    /// bv. "HF● AE○".
    public var statusItemTitle: String {
        "\(HotkeyAction.handsFree.badge)\(handsFree ? "●" : "○")"
            + " \(HotkeyAction.autoEnter.badge)\(autoEnter ? "●" : "○")"
    }

    /// Menuregel per toggle, met de stand voluit geschreven.
    public func menuLines() -> [String] {
        [
            "\(HotkeyAction.handsFree.title): \(handsFree ? "aan" : "uit")",
            "\(HotkeyAction.autoEnter.title): \(autoEnter ? "aan" : "uit")",
        ]
    }
}

// MARK: - Input Monitoring-permissie

/// De Input Monitoring-permissie die globale hotkeys nodig hebben. De melding is
/// puur en getest; de echte systeemcheck zit in de Carbon/IOKit-laag.
public enum InputMonitoring {
    /// De expliciete melding bij ontbrekende permissie (spec: geen stil falen).
    public static let missingNotice =
        "pitchlab-speech mag geen toetsaanslagen lezen. Zet ‘Invoercontrole’ (Input Monitoring) aan in Systeeminstellingen ▸ Privacy en beveiliging en start de app opnieuw."

    /// De melding als de permissie ontbreekt, anders nil. Puur — voor de test.
    public static func notice(granted: Bool) -> String? {
        granted ? nil : missingNotice
    }

    #if canImport(IOKit)
    /// True als de gebruiker Input Monitoring heeft toegestaan. Vraagt de
    /// permissie niet aan; alleen de huidige stand.
    public static func isGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
    #else
    public static func isGranted() -> Bool { true }
    #endif
}

#if canImport(IOKit)
import IOKit.hid
#endif

#if canImport(Carbon)
import Carbon.HIToolbox

// MARK: - Carbon-laag (mensentest)

/// De C-event-handler die Carbon aanroept bij een geregistreerde hotkey. Haalt de
/// `EventHotKeyID` uit het event en dispatcht naar de manager. Carbon roept dit op
/// de main-runloop aan, dus `assumeIsolated` is veilig.
private func pitchlabHotkeyHandler(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID)
    guard status == noErr else { return status }
    let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.handleHotkey(id: hotkeyID.id)
    }
    return noErr
}

/// Registreert de twee globale hotkeys via Carbon en flipt bij een toetsdruk de
/// bijbehorende persistente toggle. Vraagt eerst de Input Monitoring-permissie op;
/// ontbreekt die, dan registreert hij niets en zet een melding klaar. Het echt
/// afvangen van een globale toets is een mensentest.
@MainActor
public final class GlobalHotkeyManager {
    private let store: HotkeyStore
    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    /// Vier tekens als handtekening voor de hotkey-registratie ("plsk").
    private let signature: OSType = 0x706C_736B

    /// De melding als de permissie bij `start()` ontbrak, anders nil.
    public private(set) var permissionNotice: String?

    /// Aangeroepen na elke toggle, zodat het statusitem de nieuwe stand tekent.
    public var onToggle: ((HotkeyAction, Bool) -> Void)?

    public init(store: HotkeyStore) {
        self.store = store
    }

    /// De statusbalk-titel voor de huidige stand van beide toggles.
    public func statusItemTitle() -> String {
        store.status().statusItemTitle
    }

    /// Vraagt de permissie op en registreert beide hotkeys. Geeft false terug (en
    /// zet `permissionNotice`) als Input Monitoring ontbreekt.
    @discardableResult
    public func start() -> Bool {
        guard InputMonitoring.isGranted() else {
            permissionNotice = InputMonitoring.missingNotice
            return false
        }
        permissionNotice = nil
        installHandlerIfNeeded()
        for action in HotkeyAction.allCases {
            register(action)
        }
        return true
    }

    /// Herdefinieert de sneltoets voor een actie, bewaart hem en registreert bij
    /// een levende handler meteen opnieuw.
    public func rebind(_ action: HotkeyAction, to combo: KeyCombo) {
        store.setCombo(combo, for: action)
        if handlerRef != nil {
            register(action)
        }
    }

    /// Verwerkt een toetsdruk: wissel de toggle en meld de nieuwe stand.
    func handleHotkey(id: UInt32) {
        guard let action = HotkeyAction(hotkeyID: id) else { return }
        let now = store.toggle(action)
        onToggle?(action, now)
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            pitchlabHotkeyHandler,
            1,
            &eventType,
            userData,
            &handlerRef)
    }

    private func register(_ action: HotkeyAction) {
        unregister(action)
        let combo = store.combo(for: action)
        var ref: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: signature, id: action.hotkeyID)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref)
        if status == noErr, let ref {
            refs[action] = ref
        }
    }

    private func unregister(_ action: HotkeyAction) {
        if let ref = refs[action] {
            UnregisterEventHotKey(ref)
            refs[action] = nil
        }
    }
}
#endif
