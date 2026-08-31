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

    /// True als dit een modifier-only combo is (bv. rechter cmd): de `keyCode` is
    /// zelf een modifier-toets, geen gewone toets. Carbon `RegisterEventHotKey` kan
    /// zo'n kale modifier niet registreren — het vraagt een keycode plus een
    /// modifier-masker — dus deze combo's lopen via de CGEventTap-laag
    /// (`ModifierTapDetector`) in plaats van via Carbon.
    public var isModifierOnly: Bool { ModifierKey.logicalModifier(for: keyCode) != nil }

    /// De combinatie als string voor persistentie: "<modifiers>:<keyCode>". Eén
    /// formaat voor allebei de soorten hotkeys:
    ///  - een gewone keycode-hotkey bewaart de toetscode plus zijn modifier-masker
    ///    (⌃⌥H → "6:4");
    ///  - een modifier-only combo bewaart de modifier-keycode als `keyCode` en de
    ///    meegevraagde modifiers in het masker (rechter cmd → "0:54",
    ///    ⇧+rechter cmd → "8:54").
    /// Het formaat draagt geen aparte vlag; `isModifierOnly` leidt het soort af uit
    /// de keyCode, zodat oude bewaarde combo's ongewijzigd blijven werken.
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
    /// Hands-free op rechter cmd, auto-enter op ⇧+rechter cmd. Allebei modifier-only
    /// (via de CGEventTap-laag): ⌥Space viel af, die is al bezet door het dicteren.
    public static func `default`(for action: HotkeyAction) -> KeyCombo {
        switch action {
        case .handsFree: return KeyCombo(keyCode: ModifierKey.rightCommand, modifiers: [])         // rechter ⌘
        case .autoEnter: return KeyCombo(keyCode: ModifierKey.rightCommand, modifiers: [.shift])   // ⇧ + rechter ⌘
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
        case ModifierKey.rightCommand: return "R⌘"
        case ModifierKey.leftCommand: return "L⌘"
        default: return "key \(keyCode)"
        }
    }
}

// MARK: - Modifier-toetsen (links/rechts)

/// De virtuele toetscodes van de modifier-toetsen, links en rechts apart. Deze zijn
/// nodig voor modifier-only hotkeys (rechter cmd): Carbon `RegisterEventHotKey` kan
/// een kale modifier niet registreren, dus die combo's lopen via een CGEventTap op
/// `.flagsChanged`, waar links en rechts te onderscheiden zijn — rechter cmd is
/// keycode 54, linker cmd 55, met een eigen device-bit in de event-flags. Puur en
/// getest; de tap zelf zit in de Carbon/CoreGraphics-laag (mensentest).
public enum ModifierKey {
    public static let rightCommand: UInt32 = 54
    public static let leftCommand: UInt32 = 55
    public static let leftShift: UInt32 = 56
    public static let rightShift: UInt32 = 60
    public static let leftOption: UInt32 = 58
    public static let rightOption: UInt32 = 61
    public static let leftControl: UInt32 = 59
    public static let rightControl: UInt32 = 62

    /// De logische modifier die bij een modifier-keycode hoort, of nil als het geen
    /// modifier-toets is (dan is het een gewone keycode-hotkey voor Carbon).
    public static func logicalModifier(for keyCode: UInt32) -> KeyCombo.Modifiers? {
        switch keyCode {
        case leftCommand, rightCommand: return .command
        case leftShift, rightShift: return .shift
        case leftOption, rightOption: return .option
        case leftControl, rightControl: return .control
        default: return nil
        }
    }

    /// Het device-specifieke CGEventFlags-bit per modifier-keycode. Links en rechts
    /// hebben elk hun eigen bit (`IOLLEvent.h`, de `NX_DEVICE*`-maskers), zo is
    /// rechter cmd van linker cmd te onderscheiden op een `.flagsChanged`. Nil als
    /// het geen modifier-toets is.
    public static func deviceMask(for keyCode: UInt32) -> UInt64? {
        switch keyCode {
        case leftControl: return 0x0000_0001    // NX_DEVICELCTLKEYMASK
        case leftShift: return 0x0000_0002       // NX_DEVICELSHIFTKEYMASK
        case rightShift: return 0x0000_0004      // NX_DEVICERSHIFTKEYMASK
        case leftCommand: return 0x0000_0008     // NX_DEVICELCMDKEYMASK
        case rightCommand: return 0x0000_0010    // NX_DEVICERCMDKEYMASK
        case leftOption: return 0x0000_0020      // NX_DEVICELALTKEYMASK
        case rightOption: return 0x0000_0040     // NX_DEVICERALTKEYMASK
        case rightControl: return 0x0000_2000    // NX_DEVICERCTLKEYMASK
        default: return nil
        }
    }

    /// True als díe specifieke modifier-toets ingedrukt is in de gegeven
    /// CGEventFlags. Op een `.flagsChanged` vertelt dit of de toets omlaag of omhoog
    /// ging: het device-bit staat aan zolang de toets omlaag is, uit zodra hij los is.
    public static func isKeyDown(keyCode: UInt32, deviceFlags: UInt64) -> Bool {
        guard let mask = deviceMask(for: keyCode) else { return false }
        return deviceFlags & mask != 0
    }
}

// MARK: - Modifier-tik-detectie (CGEventTap-model)

/// Eén tap-gebeurtenis, ontdaan van CoreGraphics zodat de tik-logica zonder een
/// echte CGEventTap te testen is. De Carbon/CoreGraphics-laag vertaalt een ruwe
/// `.flagsChanged` naar `.modifier(...)` en een gewone toetsdruk naar `.otherKey`.
public enum TapEvent: Equatable, Sendable {
    /// Een modifier-toets ging omlaag (`isDown`) of omhoog. `activeModifiers` zijn de
    /// logische modifiers (⌘⇧⌥⌃) die ná deze verandering ingedrukt zijn.
    case modifier(keyCode: UInt32, isDown: Bool, activeModifiers: KeyCombo.Modifiers)
    /// Een gewone (niet-modifier) toets ging omlaag. Breekt een lopende tik af, want
    /// modifier + gewone toets is een snelkoppeling, geen tik.
    case otherKey
}

/// Detecteert een *tik* op een kale modifier en zegt welke toggle moet vuren. Puur —
/// geen CoreGraphics, geen runloop — dus volledig getest. GEEN push-to-talk:
/// vasthouden is nergens een modus, de app kent alleen toggles. Vasthouden wordt hier
/// juist gedetecteerd om een toggle te ONDERDRUKKEN.
///
/// Een geldige tik is: modifier omlaag, dezelfde modifier weer omhoog, met (a) geen
/// andere toets ertussen en (b) niet langer dan `maxHoldSeconds` vastgehouden. Zonder
/// (a) wordt elke cmd-C of cmd-Tab een toggle; (b) vangt het geval dat de modifier
/// lang wordt vastgehouden zonder dat er een andere toets bij komt.
public final class ModifierTapDetector {
    /// Eén modifier-only binding: welke actie vuurt bij een tik op welke
    /// modifier-keycode, met welke extra modifiers erbij gehouden. Hands-free = tik
    /// op rechter cmd (geen extra); auto-enter = tik op rechter cmd met shift vast.
    public struct Binding: Equatable {
        public let action: HotkeyAction
        public let keyCode: UInt32
        public let requiredModifiers: KeyCombo.Modifiers
        public init(action: HotkeyAction, keyCode: UInt32, requiredModifiers: KeyCombo.Modifiers) {
            self.action = action
            self.keyCode = keyCode
            self.requiredModifiers = requiredModifiers
        }
    }

    private let bindings: [Binding]
    private let maxHoldSeconds: Double
    private var pending: Pending?

    private struct Pending {
        let keyCode: UInt32
        let extraModifiers: KeyCombo.Modifiers
        let downAt: Double
    }

    public init(bindings: [Binding], maxHoldSeconds: Double = 0.4) {
        self.bindings = bindings
        self.maxHoldSeconds = maxHoldSeconds
    }

    /// Verwerkt één tap-event op tijdstip `now` (seconden, monotoon). Geeft de actie
    /// terug die moet togglen als dit event een geldige tik afmaakt, anders nil.
    @discardableResult
    public func process(_ event: TapEvent, now: Double) -> HotkeyAction? {
        switch event {
        case .otherKey:
            // Er kwam een gewone toets bij: dit is een snelkoppeling, geen tik.
            pending = nil
            return nil

        case let .modifier(keyCode, isDown, activeModifiers):
            guard let ownModifier = ModifierKey.logicalModifier(for: keyCode) else {
                return nil
            }
            if isDown {
                // Nieuwe kandidaat-tik. De extra modifiers zijn wat er verder nog
                // vastzit, los van de toets die net omlaag ging.
                let extra = activeModifiers.subtracting(ownModifier)
                pending = Pending(keyCode: keyCode, extraModifiers: extra, downAt: now)
                return nil
            }
            // Omhoog: alleen de toets die als laatste omlaag ging telt als tik.
            guard let p = pending, p.keyCode == keyCode else {
                pending = nil
                return nil
            }
            pending = nil
            guard now - p.downAt <= maxHoldSeconds else { return nil }
            return bindings.first {
                $0.keyCode == keyCode && $0.requiredModifiers == p.extraModifiers
            }?.action
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
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Carbon-laag (mensentest)

/// De CGEventTap-callback voor `.flagsChanged` en `.keyDown`. Zet elk ruw event om in
/// een `TapEvent` en geeft het aan de detector; de tap luistert alleen mee
/// (`.listenOnly`), dus het event gaat onveranderd door. Draait op de main-runloop
/// (de source hangt daaraan), dus `assumeIsolated` is veilig.
#if canImport(CoreGraphics)
private func pitchlabFlagsTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userData: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userData {
        let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        // Het ruwe CGEvent hier vertalen naar een Sendable `TapEvent` — een CGEvent
        // mag niet mee de main-actor closure in (Swift 6 data-race).
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            MainActor.assumeIsolated { manager.reenableTap() }
        case .flagsChanged:
            let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
            if ModifierKey.logicalModifier(for: keyCode) != nil {
                let flags = event.flags
                let isDown = ModifierKey.isKeyDown(keyCode: keyCode, deviceFlags: flags.rawValue)
                let active = GlobalHotkeyManager.logicalModifiers(from: flags)
                let tapEvent = TapEvent.modifier(keyCode: keyCode, isDown: isDown, activeModifiers: active)
                MainActor.assumeIsolated { manager.handleTapEvent(tapEvent) }
            }
        case .keyDown:
            MainActor.assumeIsolated { manager.handleTapEvent(.otherKey) }
        default:
            break
        }
    }
    return Unmanaged.passUnretained(event)
}
#endif

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

    /// De tik-detector voor modifier-only combo's (rechter cmd), en de CGEventTap die
    /// hem voedt. Alleen levend zodra er minstens één modifier-only binding is.
    private var detector: ModifierTapDetector?
    #if canImport(CoreGraphics)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    #endif

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

    /// Vraagt de permissie op en registreert beide hotkeys. Gewone keycode-combo's
    /// gaan via Carbon, modifier-only combo's (rechter cmd) via de CGEventTap. Geeft
    /// false terug (en zet `permissionNotice`) als Input Monitoring ontbreekt.
    @discardableResult
    public func start() -> Bool {
        guard InputMonitoring.isGranted() else {
            permissionNotice = InputMonitoring.missingNotice
            return false
        }
        permissionNotice = nil
        installHandlerIfNeeded()
        for action in HotkeyAction.allCases where !store.combo(for: action).isModifierOnly {
            register(action)
        }
        installEventTapIfNeeded()
        return true
    }

    /// Herdefinieert de sneltoets voor een actie, bewaart hem en registreert opnieuw
    /// zodra de laag leeft. De combo kan van soort veranderen — een gewone keycode
    /// wordt modifier-only of andersom — dus beide paden worden bijgewerkt.
    public func rebind(_ action: HotkeyAction, to combo: KeyCombo) {
        store.setCombo(combo, for: action)
        unregister(action)
        if combo.isModifierOnly {
            installEventTapIfNeeded()
        } else if handlerRef != nil {
            register(action)
        }
    }

    /// Verwerkt een Carbon-toetsdruk: wissel de toggle en meld de nieuwe stand.
    func handleHotkey(id: UInt32) {
        guard let action = HotkeyAction(hotkeyID: id) else { return }
        let now = store.toggle(action)
        onToggle?(action, now)
    }

    /// De modifier-only bindings uit de store, voor de detector.
    private func modifierBindings() -> [ModifierTapDetector.Binding] {
        HotkeyAction.allCases.compactMap { action in
            let combo = store.combo(for: action)
            guard combo.isModifierOnly else { return nil }
            return ModifierTapDetector.Binding(
                action: action, keyCode: combo.keyCode, requiredModifiers: combo.modifiers)
        }
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

    #if canImport(CoreGraphics)
    /// De logische modifiers (⌘⇧⌥⌃) die ná deze flags ingedrukt zijn, los van welke
    /// toets links of rechts zat. `nonisolated` zodat de nonisolated tap-callback hem
    /// synchroon kan gebruiken bij het vertalen van een ruw CGEvent.
    nonisolated static func logicalModifiers(from flags: CGEventFlags) -> KeyCombo.Modifiers {
        var m: KeyCombo.Modifiers = []
        if flags.contains(.maskCommand) { m.insert(.command) }
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskControl) { m.insert(.control) }
        return m
    }

    /// Bouwt de detector uit de store en zet één CGEventTap op zodra er een
    /// modifier-only binding is. De tap luistert alleen mee; hij consumeert geen
    /// events. Herbouwt de detector bij elke aanroep, maar maakt de mach-port maar
    /// één keer.
    private func installEventTapIfNeeded() {
        let bindings = modifierBindings()
        detector = ModifierTapDetector(bindings: bindings)
        guard !bindings.isEmpty, eventTap == nil else { return }

        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        let userData = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: pitchlabFlagsTapCallback,
            userInfo: userData) else { return }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Verwerkt een vertaald tap-event: laat de detector beslissen en toggelt bij een
    /// geldige tik. Het ruwe CGEvent is al in de callback tot een `TapEvent` gemaakt.
    func handleTapEvent(_ tapEvent: TapEvent) {
        if let action = detector?.process(tapEvent, now: ProcessInfo.processInfo.systemUptime) {
            let now = store.toggle(action)
            onToggle?(action, now)
        }
    }

    /// Zet de tap weer aan nadat het systeem hem heeft uitgeschakeld (timeout of te
    /// veel invoer).
    func reenableTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
    #endif
}
#endif
