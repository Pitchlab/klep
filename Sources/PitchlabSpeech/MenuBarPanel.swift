/// Het menubalk-paneel: een bedieningspaneel dat uit het statusitem klapt, in plaats
/// van een `NSMenu`. Een menu kan geen schuifregelaar met een zichtbare waarde
/// dragen, dus elke instelling die niet aan/uit is zou naar een apart venster moeten —
/// één klik te ver voor een drempel die je per dictaat bijstelt (docs/ux-reference/
/// analysis.md). Het paneel draagt gewone views, dus toggles, een dropdown en straks
/// schuifregelaars staan op één plek.
///
/// KEUZE: NSPopover, geankerd aan de statusitem-knop, niet een NSWindow met
/// `.nonactivatingPanel`. Reden: de popover ankert zichzelf onder de knop, dwingt de
/// app niet te activeren (past bij `.accessory`, geen Dock-icoon), sluit vanzelf bij een
/// klik erbuiten (`.transient`) en host willekeurige AppKit-views — dus een dropdown en
/// een schuifregelaar met waarde werken zonder extra werk. Een `.nonactivatingPanel`
/// zou handmatige plaatsing onder de knop, handmatig sluiten bij een klik erbuiten en
/// schermrand-logica vragen; het enige dat hij extra zou geven — openblijven terwijl je
/// in een andere app werkt — heeft een bedieningspaneel dat je opent, bijstelt en sluit
/// niet nodig.
///
/// Twee lagen, net als `MenuBarApp.swift`, zodat de logica zonder runloop te testen is:
///  - Pure model-laag (`MenuBarPanelModel`, `StatusIndicator`, `SpeechFormat`,
///    `FooterButton`): de paneelteksten, de statusstip-kleur (de statusomzetting) en de
///    getalnotatie worden hier bepaald. Geen AppKit — direct te testen
///    (`MenuBarPanelTests`).
///  - AppKit-laag (`MenuBarPanelController`), onder `#if canImport(AppKit)`: bouwt de
///    views uit het model en hangt de acties aan de callbacks. Wat je tekent is een
///    mensentest (PRD, ROE §2).

import Foundation

// MARK: - Getalnotatie

/// Eén `NumberFormatter` voor het hele paneel én het instellingenvenster. Valkuil uit
/// SpeechButton: het paneel schreef `1.00s` met punt en het venster `1,00s` met komma
/// voor dezelfde waarde. Alle secondewaarden lopen door `SpeechFormat.seconds`, zodat
/// PL-746 (auto-enter-vertraging) en elke latere drempel dezelfde komma en precisie
/// tonen.
public enum SpeechFormat {
    /// Nederlandse notatie, twee decimalen: `1,00`. Locale hard op `nl_NL` zodat de
    /// notatie niet met de systeemtaal meebeweegt.
    public static let secondsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    /// Een secondewaarde als tekst met de vaste notatie, bv. `1,00s`.
    public static func seconds(_ value: Double) -> String {
        let number = secondsFormatter.string(from: NSNumber(value: value))
            ?? String(format: "%.2f", value)
        return "\(number)s"
    }
}

// MARK: - Statusstip

/// De semantische kleur van de statusstip. Los van AppKit zodat de statusomzetting
/// getest kan worden zonder `NSColor`; de AppKit-laag mapt hem naar een echte kleur.
public enum StatusColor: String, Sendable, Equatable {
    case ready
    case listening
    case working
}

extension SpeechState {
    /// De kleur van de statusstip in de paneelkop. Dit is de statusomzetting die de
    /// gate dekt: gereed groen, luisteren rood, transcriberen amber.
    public var statusColor: StatusColor {
        switch self {
        case .idle: return .ready
        case .listening: return .listening
        case .transcribing: return .working
        }
    }
}

/// De statusregel als data: de kleur van de stip en de tekst ernaast. Puur, zodat de
/// test de kleur-per-staat kan nalopen.
public struct StatusIndicator: Sendable, Equatable {
    public let color: StatusColor
    public let label: String

    public init(state: SpeechState) {
        self.color = state.statusColor
        self.label = state.menuLabel
    }
}

// MARK: - Voetrij

/// Eén actie in de voetrij van het paneel.
public enum PanelAction: String, Sendable, Equatable {
    case settings
    case history
    case quit

    /// De knoptekst.
    public var title: String {
        switch self {
        case .settings: return "Instellingen"
        case .history: return "Geschiedenis"
        case .quit: return "Stoppen"
        }
    }
}

/// Eén voetknop met zijn actie en of hij aanklikbaar is. Geschiedenis staat voorlopig
/// uit — de inhoud komt in PL-757.
public struct FooterButton: Sendable, Equatable {
    public let action: PanelAction
    public let isEnabled: Bool

    public init(action: PanelAction, isEnabled: Bool) {
        self.action = action
        self.isEnabled = isEnabled
    }

    public var title: String { action.title }
}

// MARK: - Paneel-model

/// Het volledige paneel als data. Levert per onderdeel de tekst, de standen en de
/// keuzelijst, zodat de AppKit-laag alleen nog views hoeft te maken en de tests de
/// teksten en standen direct kunnen nalopen zonder runloop.
public struct MenuBarPanelModel: Sendable, Equatable {
    public var state: SpeechState
    /// Het versienummer voor de paneelkop; bij een app die je zelf herbouwt is "welke
    /// draait er nu" een echte vraag (analysis.md).
    public var version: String
    public var handsFreeOn: Bool
    /// De sneltoets die hands-free omschakelt, als leesbare tekst (bv. "R⌘"). Vult
    /// zowel de toetsenchip als de hint onder de toggle.
    public var handsFreeShortcut: String
    public var autoEnterOn: Bool
    /// Of de app bij inloggen start (de LaunchAgent-plist bestaat). Aan/uit is een
    /// toggle, dus hij hoort in het paneel — niet in een apart venster (PL-691).
    public var autoStartOn: Bool
    /// De keuzelijst voor de microfoon-dropdown.
    public var devices: [DeviceInfo]
    /// De id van het gekozen apparaat, voor de selectie in de dropdown.
    public var selectedDeviceID: String?
    /// Melding als de gekozen microfoon verdween en de app terugviel (R6), of nil.
    public var fallbackNotice: String?
    /// Melding als de tekstuitvoer faalde (bv. ontbrekende Accessibility), of nil. Geen
    /// stille mislukking: het paneel toont dit onder de statusregel (R9).
    public var errorNotice: String?
    /// Of de luister-stip gekoppeld is; alleen dan toont de statusregel de
    /// "terug naar het midden"-knop, zodat een dood knopje nooit verschijnt (PL-737).
    public var canRecenter: Bool

    public init(
        state: SpeechState = .idle,
        version: String = "0.0.0",
        handsFreeOn: Bool = false,
        handsFreeShortcut: String = "",
        autoEnterOn: Bool = false,
        autoStartOn: Bool = false,
        devices: [DeviceInfo] = [],
        selectedDeviceID: String? = nil,
        fallbackNotice: String? = nil,
        errorNotice: String? = nil,
        canRecenter: Bool = false
    ) {
        self.state = state
        self.version = version
        self.handsFreeOn = handsFreeOn
        self.handsFreeShortcut = handsFreeShortcut
        self.autoEnterOn = autoEnterOn
        self.autoStartOn = autoStartOn
        self.devices = devices
        self.selectedDeviceID = selectedDeviceID
        self.fallbackNotice = fallbackNotice
        self.errorNotice = errorNotice
        self.canRecenter = canRecenter
    }

    /// De statusregel: de stipkleur en de tekst.
    public var statusIndicator: StatusIndicator { StatusIndicator(state: state) }

    /// Het versienummer voor de kop, met de gebruikelijke `v`-prefix.
    public var versionLabel: String { "v\(version)" }

    /// De tekst op de alleen-lezen toetsenchip. Klikken opent het sneltoets-instelscherm
    /// (PL-733); de chip zelf wijzigt niets.
    public var shortcutChip: String { handsFreeShortcut }

    public var handsFreeTitle: String { "Hands-free" }

    /// De hint onder de hands-free-toggle: welke toets hem omschakelt.
    public var handsFreeHint: String { "Omschakelen met \(handsFreeShortcut)" }

    public var autoEnterTitle: String { "Auto-enter" }

    /// De titel van de auto-start-toggle (de stand komt van `autoStartOn`).
    public var autoStartTitle: String { "Start automatisch bij inloggen" }

    /// De tekst op de "terug naar het midden"-knop bij de statusregel; ook de
    /// tooltip/VoiceOver-tekst. Zet de luister-stip terug in het midden (PL-737).
    public var recenterTitle: String { "Stip naar het midden" }

    public var microphoneTitle: String { "Microfoon" }

    /// De naam van het gekozen apparaat, of nil als er niets gekozen is.
    public var selectedMicrophoneName: String? {
        devices.first { $0.uniqueID == selectedDeviceID }?.localizedName
    }

    /// De dropdown-items als paren titel + of hij gekozen is.
    public func microphoneItems() -> [(title: String, isSelected: Bool)] {
        devices.map { ($0.localizedName, $0.uniqueID == selectedDeviceID) }
    }

    /// De tekst als er geen microfoons zijn.
    public var microphonePlaceholder: String { "(geen microfoons gevonden)" }

    /// De ⚠︎-regels onder de statusregel: terugval (R6) en uitvoerfout (R9), elk
    /// alleen als hij er is. Geen stille mislukking.
    public func noticeLines() -> [String] {
        var lines: [String] = []
        if let fallbackNotice { lines.append("⚠︎ \(fallbackNotice)") }
        if let errorNotice { lines.append("⚠︎ \(errorNotice)") }
        return lines
    }

    /// De drie voetknoppen: Instellingen, Geschiedenis (uit tot PL-757), Stoppen.
    public func footerButtons() -> [FooterButton] {
        [
            FooterButton(action: .settings, isEnabled: true),
            FooterButton(action: .history, isEnabled: false),
            FooterButton(action: .quit, isEnabled: true),
        ]
    }
}

#if canImport(AppKit)
import AppKit

// MARK: - AppKit-laag (mensentest)

/// Tekent het `MenuBarPanelModel` als een kolom views in een `NSPopover`. De rijen van
/// boven naar beneden: statusregel met stip, versie en — als de stip gekoppeld is — een
/// "terug naar het midden"-knop (PL-737), de alleen-lezen toetsenchip, hands-free-toggle
/// met hint, een lege plek voor de permissiestatus (PL-729), de auto-enter-toggle, een
/// lege plek voor de auto-enter-vertraging (PL-746), de microfoon-dropdown, de
/// auto-start-toggle (PL-691) en de voetrij. De twee lege plekken (`permissionSlot`,
/// `autoEnterDelaySlot`) zijn publieke stackviews zodat PL-729 en PL-746 hun view erin
/// hangen zonder dit bestand te herbouwen; leeg klappen ze tot nul hoogte in.
///
/// PLAATSING van de twee teruggekeerde acties. Auto-start staat als toggle onder de
/// microfoon en boven de voetrij: het is een aan/uit-voorkeur zoals hands-free en
/// auto-enter, maar een die je zelden omzet, dus laag in de kolom en niet tussen de
/// dictaat-toggles. "Terug naar het midden" hoort bij de statusregel, niet in de
/// voetrij: de knop werkt op de luister-stip, en de statusregel is het echo daarvan;
/// zo blijft de voetrij de drie navigatie-acties (Instellingen/Geschiedenis/Stoppen)
/// die de spec vastlegt. De knop verschijnt alleen als de stip gekoppeld is
/// (`canRecenter`), zodat een dood knopje nooit getekend wordt.
///
/// Runtime niet gedekt door de unit-tests: een paneel tonen vraagt een NSApplication-
/// runloop en is een mensentest. De testbare logica zit in `MenuBarPanelModel`.
@MainActor
public final class MenuBarPanelController: NSViewController {
    private var model: MenuBarPanelModel

    /// De vaste breedte van het paneel in punten.
    private static let panelWidth: CGFloat = 300

    /// Lege plek voor de permissiestatus (PL-729). Later gevuld; nu nul hoogte.
    public let permissionSlot = NSStackView()
    /// Lege plek voor de auto-enter-vertraging als schuifregelaar (PL-746).
    public let autoEnterDelaySlot = NSStackView()

    /// De hoofdkolom; bij elke `apply` opnieuw gevuld, met de twee lege plekken op hun
    /// plaats zodat de erin gehangen views een herbouw overleven.
    private let column = NSStackView()

    // Callbacks, gezet door `MenuBarController`.
    /// Hands-free omgeschakeld via het paneel, met de nieuwe stand.
    public var onToggleHandsFree: ((Bool) -> Void)?
    /// Auto-enter omgeschakeld via het paneel, met de nieuwe stand.
    public var onToggleAutoEnter: ((Bool) -> Void)?
    /// Auto-start (start bij inloggen) omgeschakeld via het paneel, met de nieuwe stand.
    public var onToggleAutoStart: ((Bool) -> Void)?
    /// De "terug naar het midden"-knop aangeklikt: zet de luister-stip terug (PL-737).
    public var onRecenter: (() -> Void)?
    /// Een microfoon gekozen, met de `uniqueID`.
    public var onSelectDevice: ((String) -> Void)?
    /// De toetsenchip aangeklikt: open het sneltoets-instelscherm (PL-733).
    public var onOpenShortcutSettings: (() -> Void)?
    /// Een voetknop aangeklikt, met de actie.
    public var onFooterAction: ((PanelAction) -> Void)?

    public init(model: MenuBarPanelModel = MenuBarPanelModel()) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is niet ondersteund") }

    public override func loadView() {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        column.translatesAutoresizingMaskIntoConstraints = false

        permissionSlot.orientation = .vertical
        permissionSlot.spacing = 6
        autoEnterDelaySlot.orientation = .vertical
        autoEnterDelaySlot.spacing = 6

        let container = NSView()
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            column.widthAnchor.constraint(equalToConstant: Self.panelWidth),
        ])
        self.view = container
        rebuild()
    }

    /// Vervangt het model en hertekent het paneel.
    public func apply(_ model: MenuBarPanelModel) {
        self.model = model
        if isViewLoaded { rebuild() }
    }

    // MARK: Opbouw

    private func rebuild() {
        for view in column.arrangedSubviews {
            column.removeArrangedSubview(view)
            if view !== permissionSlot, view !== autoEnterDelaySlot {
                view.removeFromSuperview()
            }
        }

        column.addArrangedSubview(makeStatusRow())
        for line in model.noticeLines() {
            column.addArrangedSubview(makeNoticeLabel(line))
        }
        column.addArrangedSubview(makeShortcutRow())
        column.addArrangedSubview(makeHandsFreeRow())
        column.addArrangedSubview(permissionSlot)   // PL-729
        column.addArrangedSubview(makeAutoEnterRow())
        column.addArrangedSubview(autoEnterDelaySlot) // PL-746
        column.addArrangedSubview(makeMicrophoneRow())
        column.addArrangedSubview(makeAutoStartRow())
        column.addArrangedSubview(makeFooterRow())
    }

    private func makeStatusRow() -> NSView {
        let dot = DotView()
        dot.color = Self.color(for: model.statusIndicator.color)
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
        ])
        let label = Self.label(model.statusIndicator.label)
        let version = Self.label(model.versionLabel)
        version.textColor = .secondaryLabelColor
        var views: [NSView] = [dot, label, NSView(), version]
        // Alleen tekenen als de stip gekoppeld is; anders een dood knopje (PL-737).
        if model.canRecenter {
            let recenter = NSButton(
                title: "", target: self, action: #selector(recenterClicked))
            recenter.bezelStyle = .rounded
            recenter.controlSize = .small
            recenter.image = NSImage(
                systemSymbolName: "scope", accessibilityDescription: model.recenterTitle)
            recenter.imagePosition = .imageOnly
            recenter.toolTip = model.recenterTitle
            recenter.setAccessibilityLabel(model.recenterTitle)
            views.append(recenter)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    private func makeNoticeLabel(_ text: String) -> NSView {
        let label = Self.label(text)
        label.textColor = .systemOrange
        return label
    }

    private func makeShortcutRow() -> NSView {
        let chip = NSButton(title: model.shortcutChip, target: self, action: #selector(chipClicked))
        chip.bezelStyle = .rounded
        chip.controlSize = .small
        chip.toolTip = "Sneltoets aanpassen"
        let caption = Self.label("Sneltoets")
        caption.textColor = .secondaryLabelColor
        let row = NSStackView(views: [caption, NSView(), chip])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    private func makeHandsFreeRow() -> NSView {
        let toggle = NSSwitch()
        toggle.state = model.handsFreeOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(handsFreeChanged(_:))
        let title = Self.label(model.handsFreeTitle)
        let top = NSStackView(views: [title, NSView(), toggle])
        top.orientation = .horizontal
        top.spacing = 8
        top.alignment = .centerY

        let hint = Self.label(model.handsFreeHint)
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [top, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func makeAutoEnterRow() -> NSView {
        let toggle = NSSwitch()
        toggle.state = model.autoEnterOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(autoEnterChanged(_:))
        let title = Self.label(model.autoEnterTitle)
        let row = NSStackView(views: [title, NSView(), toggle])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    private func makeAutoStartRow() -> NSView {
        let toggle = NSSwitch()
        toggle.state = model.autoStartOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(autoStartChanged(_:))
        let title = Self.label(model.autoStartTitle)
        let row = NSStackView(views: [title, NSView(), toggle])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    private func makeMicrophoneRow() -> NSView {
        let caption = Self.label(model.microphoneTitle)
        caption.textColor = .secondaryLabelColor
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(microphoneChanged(_:))
        if model.devices.isEmpty {
            popup.addItem(withTitle: model.microphonePlaceholder)
            popup.isEnabled = false
        } else {
            for device in model.devices {
                let item = NSMenuItem(title: device.localizedName, action: nil, keyEquivalent: "")
                item.representedObject = device.uniqueID
                popup.menu?.addItem(item)
                if device.uniqueID == model.selectedDeviceID {
                    popup.select(item)
                }
            }
        }
        let stack = NSStackView(views: [caption, popup])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: Self.panelWidth - 28).isActive = true
        return stack
    }

    private func makeFooterRow() -> NSView {
        let buttons = model.footerButtons().map { spec -> NSButton in
            let button = NSButton(title: spec.title, target: self, action: #selector(footerClicked(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.isEnabled = spec.isEnabled
            button.identifier = NSUserInterfaceItemIdentifier(spec.action.rawValue)
            return button
        }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.panelWidth - 28).isActive = true
        return row
    }

    // MARK: Acties

    @objc private func chipClicked() { onOpenShortcutSettings?() }

    @objc private func handsFreeChanged(_ sender: NSSwitch) {
        onToggleHandsFree?(sender.state == .on)
    }

    @objc private func autoEnterChanged(_ sender: NSSwitch) {
        onToggleAutoEnter?(sender.state == .on)
    }

    @objc private func autoStartChanged(_ sender: NSSwitch) {
        onToggleAutoStart?(sender.state == .on)
    }

    @objc private func recenterClicked() { onRecenter?() }

    @objc private func microphoneChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        onSelectDevice?(id)
    }

    @objc private func footerClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let action = PanelAction(rawValue: raw) else { return }
        onFooterAction?(action)
    }

    // MARK: Hulp

    private static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// De echte kleur voor de statusstip.
    private static func color(for status: StatusColor) -> NSColor {
        switch status {
        case .ready: return .systemGreen
        case .listening: return .systemRed
        case .working: return .systemOrange
        }
    }
}

/// Een gevulde cirkel als statusstip.
private final class DotView: NSView {
    var color: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
#endif
