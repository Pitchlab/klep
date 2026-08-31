/// Het opnemen van een sneltoets: de gebruiker klikt in een opnameveld, drukt een
/// combinatie, en die wordt getoond en bewaard. Twee dingen die een gewoon
/// opnameveld níet doet, horen hier wél:
///  - een kále modifier accepteren (rechter cmd alleen), want de defaults uit PL-732
///    zijn modifier-only; een gewoon opnameveld negeert een losse modifier;
///  - een combinatie weigeren die de andere actie al gebruikt, want twee acties op
///    dezelfde toets is een stille bug.
///
/// De weergave gebruikt de bestaande glyph-logica uit `KeyCombo` (`display`) — niet
/// opnieuw gebouwd. `Hotkeys.swift` blijft ongewijzigd; het toewijzen met
/// conflict-check hangt hier als extensie op `HotkeyStore`.
///
/// Twee lagen, net als de rest van de app, zodat de opname-logica zonder AppKit te
/// testen is:
///  - Pure model-laag (`HotkeyRecorder`, `RecorderEvent`, de `HotkeyStore`-extensie,
///    `HotkeyConflict`): het opname-state-machine en de conflict-check. Geen AppKit —
///    direct getest (`HotkeyRecorderTests`).
///  - AppKit-laag (`HotkeyRecorderField`, `HotkeySettingsWindowController`), onder
///    `#if canImport(AppKit)`: het echte venster met per actie een opnameveld en een
///    reset-knop. Compileert in de gate; het venster tonen en een globale toets
///    afvangen is een mensentest.

import Foundation

// MARK: - Opname-model

/// Eén invoer-gebeurtenis voor het opnameveld, ontdaan van AppKit zodat de
/// opname-logica zonder een echte `NSView` te testen is. De AppKit-laag vertaalt een
/// `keyDown` naar `.key(...)` en een `flagsChanged` naar `.modifier(...)`.
public enum RecorderEvent: Equatable, Sendable {
    /// Een gewone (niet-modifier) toets ging omlaag, met de modifiers die op dat
    /// moment vastzaten. Legt meteen een volledige keycode-combo vast.
    case key(keyCode: UInt32, modifiers: KeyCombo.Modifiers)
    /// Een modifier-toets ging omlaag (`isDown`) of omhoog. `activeModifiers` zijn de
    /// logische modifiers (⌘⇧⌥⌃) die ná deze verandering vastzitten. Een tik op een
    /// kale modifier — omlaag en weer omhoog, zonder gewone toets ertussen — legt een
    /// modifier-only combo vast.
    case modifier(keyCode: UInt32, isDown: Bool, activeModifiers: KeyCombo.Modifiers)
}

/// Het opnameveld als state-machine. Voed hem `RecorderEvent`s; zodra een geldige
/// combinatie klaar is, staat die in `recorded`. Anders dan een gewoon opnameveld
/// legt hij expliciet óók een kale modifier vast (rechter cmd), want de defaults uit
/// PL-732 zijn modifier-only. Puur — geen AppKit, geen runloop — dus volledig getest.
public final class HotkeyRecorder {
    /// De opgenomen combinatie, of nil zolang er nog niets vastligt.
    public private(set) var recorded: KeyCombo?

    /// De modifier die omlaag ging en nog op een tik wacht: welke keycode, en welke
    /// extra modifiers er verder nog vastzaten. De tik is compleet als dezelfde
    /// keycode weer omhoog gaat zonder dat er een gewone toets tussendoor kwam.
    private var pendingModifier: (keyCode: UInt32, extra: KeyCombo.Modifiers)?
    private var isDone = false

    public init() {}

    /// Verwerkt één opname-gebeurtenis. Geeft de opgenomen combinatie terug zodra hij
    /// compleet is, anders nil. Na een complete opname doen verdere events niets tot
    /// `reset()`.
    @discardableResult
    public func process(_ event: RecorderEvent) -> KeyCombo? {
        guard !isDone else { return recorded }
        switch event {
        case let .key(keyCode, modifiers):
            // Een gewone toets rondt de opname meteen af: een volledige keycode-combo.
            // Een modifier die daarvóór omlaag ging (cmd bij ⌘A) zit in `modifiers`.
            finish(with: KeyCombo(keyCode: keyCode, modifiers: modifiers))

        case let .modifier(keyCode, isDown, activeModifiers):
            guard let own = ModifierKey.logicalModifier(for: keyCode) else { return nil }
            if isDown {
                // Kandidaat-tik: onthoud de toets plus wat er verder nog vastzit.
                pendingModifier = (keyCode, activeModifiers.subtracting(own))
            } else if let p = pendingModifier, p.keyCode == keyCode {
                // Dezelfde modifier weer omhoog, niets ertussen: een kale-modifier-combo.
                finish(with: KeyCombo(keyCode: keyCode, modifiers: p.extra))
            } else {
                pendingModifier = nil
            }
        }
        return recorded
    }

    private func finish(with combo: KeyCombo) {
        recorded = combo
        pendingModifier = nil
        isDone = true
    }

    /// Wist de opname zodat het veld opnieuw kan opnemen.
    public func reset() {
        recorded = nil
        pendingModifier = nil
        isDone = false
    }
}

// MARK: - Toewijzen met conflict-check

extension HotkeyStore {
    /// De actie die combinatie `combo` al gebruikt, anders dan `action` zelf, of nil.
    /// Twee acties op dezelfde toets is een stille bug, dus dit is de check vóór een
    /// combinatie wordt toegewezen. Combo's verschillen al bij een andere modifier —
    /// rechter cmd en ⇧+rechter cmd botsen niet.
    public func conflictingAction(for combo: KeyCombo, assigning action: HotkeyAction) -> HotkeyAction? {
        HotkeyAction.allCases.first { $0 != action && self.combo(for: $0) == combo }
    }

    /// Wijst een opgenomen combinatie toe aan een actie en bewaart hem, tenzij de
    /// andere actie hem al gebruikt — dan verandert er niets en komt de botsende actie
    /// terug. De aanroeper toont dan een melding (`HotkeyConflict.message`).
    @discardableResult
    public func assign(_ combo: KeyCombo, to action: HotkeyAction) -> HotkeyAction? {
        if let clash = conflictingAction(for: combo, assigning: action) { return clash }
        setCombo(combo, for: action)
        return nil
    }

    /// Zet een actie terug op zijn standaardcombinatie. Loopt via `assign`, dus ook de
    /// reset weigert een combinatie die de andere actie inmiddels gebruikt. De defaults
    /// botsen onderling nooit; een botsing kan alleen ná een eigen instelling.
    @discardableResult
    public func resetToDefault(for action: HotkeyAction) -> HotkeyAction? {
        assign(KeyCombo.default(for: action), to: action)
    }
}

/// De melding bij een botsende combinatie, in het Nederlands zoals de rest van de UI.
public enum HotkeyConflict {
    public static func message(combo: KeyCombo, inUseBy action: HotkeyAction) -> String {
        "\(combo.display) is al in gebruik voor \(action.title). Kies een andere combinatie."
    }
}

#if canImport(AppKit)
import AppKit
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - AppKit-laag (mensentest)

/// Eén opnameveld: klik erin, druk een combinatie, en die wordt getoond. Vertaalt de
/// ruwe `keyDown`/`flagsChanged` naar `RecorderEvent`s en laat `HotkeyRecorder`
/// beslissen wanneer een combinatie compleet is — óók een kale modifier. Bij een
/// complete opname vraagt het `onRecord` de combinatie toe te wijzen; komt daar een
/// botsende actie uit, dan toont het veld de melding en blijft de oude combinatie
/// staan. Runtime een mensentest.
public final class HotkeyRecorderField: NSView {
    /// De actie die dit veld opneemt.
    public let action: HotkeyAction
    /// Aangeroepen met een complete opname; geeft nil bij succes of de botsende actie
    /// als de combinatie al elders in gebruik is.
    public var onRecord: ((KeyCombo) -> HotkeyAction?)?
    /// De combinatie die het veld nu toont.
    public private(set) var combo: KeyCombo

    private var recorder: HotkeyRecorder?
    private let label = NSTextField(labelWithString: "")

    public init(action: HotkeyAction, combo: KeyCombo) {
        self.action = action
        self.combo = combo
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 5
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        redraw()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is niet ondersteund") }

    public override var acceptsFirstResponder: Bool { true }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recorder = HotkeyRecorder()
        label.stringValue = "Druk een combinatie…"
        drawBorder(recording: true)
    }

    public override func keyDown(with event: NSEvent) {
        guard recorder != nil else { super.keyDown(with: event); return }
        if event.keyCode == 53 { cancelRecording(); return }   // Escape: opname afbreken.
        feed(.key(keyCode: UInt32(event.keyCode),
                  modifiers: Self.logicalModifiers(from: event.modifierFlags)))
    }

    public override func flagsChanged(with event: NSEvent) {
        guard recorder != nil else { super.flagsChanged(with: event); return }
        let keyCode = UInt32(event.keyCode)
        guard ModifierKey.logicalModifier(for: keyCode) != nil else { return }
        // De device-specifieke maskers (links/rechts) zitten in de CGEvent-flags, net
        // als in de tap-laag; `event.modifierFlags` valt daarop terug.
        let deviceFlags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
        let isDown = ModifierKey.isKeyDown(keyCode: keyCode, deviceFlags: deviceFlags)
        feed(.modifier(keyCode: keyCode, isDown: isDown,
                       activeModifiers: Self.logicalModifiers(from: event.modifierFlags)))
    }

    private func feed(_ event: RecorderEvent) {
        guard let recorder, let candidate = recorder.process(event) else { return }
        self.recorder = nil
        commit(candidate)
    }

    private func commit(_ candidate: KeyCombo) {
        if let clash = onRecord?(candidate) {
            label.stringValue = HotkeyConflict.message(combo: candidate, inUseBy: clash)
            drawBorder(recording: false)
            return
        }
        combo = candidate
        redraw()
    }

    private func cancelRecording() {
        recorder = nil
        redraw()
    }

    /// Zet het veld op een nieuwe combinatie (bv. na een reset van buitenaf) en teken.
    public func show(_ combo: KeyCombo) {
        self.combo = combo
        recorder = nil
        redraw()
    }

    private func redraw() {
        label.stringValue = combo.display
        drawBorder(recording: false)
    }

    private func drawBorder(recording: Bool) {
        layer?.borderColor = (recording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

    /// De logische modifiers (⌘⇧⌥⌃) in een `NSEvent.ModifierFlags`.
    static func logicalModifiers(from flags: NSEvent.ModifierFlags) -> KeyCombo.Modifiers {
        var m: KeyCombo.Modifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        return m
    }
}

/// Het instellingenvenster: per actie (hands-free, auto-enter) een label, een
/// opnameveld en een reset-knop. Wijst een opgenomen combinatie toe via de store (met
/// conflict-check) en meldt de nieuwe binding via `onRebind`, zodat de live manager
/// hem meteen registreert. Runtime een mensentest — het venster tonen vraagt een
/// NSApplication-sessie.
public final class HotkeySettingsWindowController: NSWindowController {
    private let store: HotkeyStore
    /// Aangeroepen zodra een combinatie geldig is toegewezen, zodat de live
    /// hotkey-manager de nieuwe binding registreert. Losgekoppeld van Carbon.
    private let onRebind: ((HotkeyAction, KeyCombo) -> Void)?
    private var fields: [HotkeyAction: HotkeyRecorderField] = [:]

    public init(store: HotkeyStore, onRebind: ((HotkeyAction, KeyCombo) -> Void)? = nil) {
        self.store = store
        self.onRebind = onRebind
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Sneltoetsen"
        super.init(window: window)
        window.contentView = buildContentView()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is niet ondersteund") }

    private func buildContentView() -> NSView {
        let rows: [NSView] = HotkeyAction.allCases.map { action in
            let name = NSTextField(labelWithString: action.title)
            name.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            name.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true

            let field = HotkeyRecorderField(action: action, combo: store.combo(for: action))
            field.onRecord = { [weak self] combo in self?.assign(combo, to: action) }
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(equalToConstant: 28).isActive = true
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
            fields[action] = field

            let reset = NSButton(title: "Standaard", target: self, action: #selector(resetTapped(_:)))
            reset.bezelStyle = .rounded
            reset.tag = HotkeyAction.allCases.firstIndex(of: action) ?? 0

            let row = NSStackView(views: [name, field, reset])
            row.orientation = .horizontal
            row.spacing = 12
            row.alignment = .centerY
            return row
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    /// Wijst een opgenomen combinatie toe (met conflict-check) en registreert hem live.
    private func assign(_ combo: KeyCombo, to action: HotkeyAction) -> HotkeyAction? {
        if let clash = store.conflictingAction(for: combo, assigning: action) { return clash }
        store.setCombo(combo, for: action)
        onRebind?(action, combo)
        return nil
    }

    @objc private func resetTapped(_ sender: NSButton) {
        let action = HotkeyAction.allCases[sender.tag]
        let def = KeyCombo.default(for: action)
        // De reset weigert stil als hij zou botsen; de defaults botsen onderling nooit,
        // dus dit kan alleen ná een eigen instelling van de andere actie.
        guard store.conflictingAction(for: def, assigning: action) == nil else {
            NSSound.beep()
            return
        }
        store.setCombo(def, for: action)
        onRebind?(action, def)
        fields[action]?.show(def)
    }
}
#endif
