/// De drie permissies die samen bepalen of de app iets doet, als één sectie in het
/// instellingenvenster (PL-729, verhuisd in PL-788). Tot PL-729 was het enige signaal een
/// losse ⚠︎-regel in het menu; Erik zag een uitgezette Toegankelijkheid pas na drie uur
/// zoeken. Het hoofdpaneel houdt een bannertje (`PermissionsModel.bannerText`) en het
/// statusitem een waarschuwingsdriehoek — samen de enige melding die je ziet als je nooit
/// iets opent.
///
/// Twee lagen, net als de rest van de app, zodat de logica zonder runloop te testen is:
///  - Pure model-laag (`PermissionKind`, `PermissionItem`, `PermissionsModel`,
///    `PermissionsProbe`, `FirstRunGate`): de teksten, de herstart-hint, de
///    Systeeminstellingen-URL en de live status-afbeelding. Geen AppKit, geen echte TCC —
///    getest in `PermissionsScreenTests`.
///  - AppKit-laag (`PermissionsSectionView`), onder `#if canImport(AppKit)`: hangt de
///    rijen in een stackview die de aanroeper levert. Wat je tekent en het echt openen van
///    een Systeeminstellingen-paneel zijn mensentesten (ROE §2).

import Foundation

// MARK: - Permissiesoort

/// De drie permissies, in de vaste volgorde waarin de sectie ze toont.
public enum PermissionKind: String, CaseIterable, Sendable, Equatable {
    case microphone
    case accessibility
    case inputMonitoring

    /// De rij-titel: waarvóór je de permissie wilt, niet hoe macOS hem noemt.
    ///
    /// Erik 2026-09-01: "de labels moeten even aangepast naar waarom je het wilt".
    /// "Toegankelijkheid" en "Invoerbewaking" zeggen niets over wat je eraan hebt;
    /// "Tekst-uitvoer" en "Sneltoetsen" wel. De macOS-naam blijft nodig om het vinkje
    /// terug te vinden en staat in `systemName`, dat de rij eronder noemt.
    public var title: String {
        switch self {
        case .microphone: return "Microfoon"
        case .accessibility: return "Tekst-uitvoer"
        case .inputMonitoring: return "Sneltoetsen"
        }
    }

    /// Hoe macOS de permissie noemt in Systeeminstellingen. Zonder dit staat de gebruiker
    /// voor een lijst waarin "Tekst-uitvoer" niet voorkomt.
    public var systemName: String {
        switch self {
        case .microphone: return "Microfoon"
        case .accessibility: return "Toegankelijkheid"
        case .inputMonitoring: return "Invoerbewaking"
        }
    }

    /// Wat er zonder deze permissie wel en niet werkt — het gevaar is dat de app stil faalt.
    public var effect: String {
        switch self {
        case .microphone: return "Zonder dit neemt de app stilte op zonder te klagen: geen fout, geen transcript. Heet \"Microfoon\" in Systeeminstellingen."
        case .accessibility: return "Zonder dit lukt transcriberen wel, maar typen bij de cursor niet. Heet \"Toegankelijkheid\" in Systeeminstellingen."
        case .inputMonitoring: return "Zonder dit vuren de globale sneltoetsen niet. Heet \"Invoerbewaking\" in Systeeminstellingen."
        }
    }

    /// Of de app opnieuw gestart moet worden nadat je de permissie hebt gegeven. Eerlijk
    /// per permissie: Invoerbewaking vraagt het (`InputMonitoring.missingNotice` zegt het
    /// al), Toegankelijkheid ook (de al draaiende `AXIsProcessTrusted`-client pakt de
    /// nieuwe trust pas na een herstart op), microfoon niet (de prompt werkt live).
    public var requiresRestart: Bool {
        switch self {
        case .microphone: return false
        case .accessibility, .inputMonitoring: return true
        }
    }

    /// De hint die onder de rij verschijnt zolang de permissie ontbreekt en een herstart
    /// nodig is, of nil.
    public var restartHint: String? {
        requiresRestart ? "Herstart de app nadat je dit hebt aangezet." : nil
    }

    /// Het anker dat het juiste Privacy-deelvenster in Systeeminstellingen selecteert.
    public var settingsAnchor: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        }
    }

    /// De URL die het juiste Systeeminstellingen-paneel opent. KANDIDAAT — twee varianten,
    /// niet zelf getest (draait op Eriks werkende Mac, ROE §2):
    ///   A (nu gekozen, System Settings sinds macOS 13):
    ///       `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?<anker>`
    ///   B (klassiek preference-paneel, oudere macOS):
    ///       `x-apple.systempreferences:com.apple.preference.security?<anker>`
    /// Erik bevestigt in het review welke op macOS 26 het juiste deelvenster opent; wissel
    /// dan het prefix hieronder om.
    public var settingsURLString: String {
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(settingsAnchor)"
    }
}

// MARK: - Live status per permissie

/// De status van één permissie in het paneel.
public struct PermissionItem: Sendable, Equatable {
    public let kind: PermissionKind
    public let isGranted: Bool

    public init(kind: PermissionKind, isGranted: Bool) {
        self.kind = kind
        self.isGranted = isGranted
    }

    public var title: String { kind.title }
    public var effect: String { kind.effect }
    public var requiresRestart: Bool { kind.requiresRestart }

    /// De statustekst naast de titel.
    public var statusLabel: String { isGranted ? "✓ toegestaan" : "⚠︎ ontbreekt" }

    /// De titel van de knop die het juiste Systeeminstellingen-paneel opent.
    public var buttonTitle: String { "Open in Systeeminstellingen" }

    /// De herstart-hint, alleen zolang de permissie ontbreekt en een herstart nodig is.
    public var restartHint: String? { isGranted ? nil : kind.restartHint }
}

/// De hele sectie als data: één item per permissie in vaste volgorde, plus de afgeleide
/// vraag of er iets ontbreekt (voor het statusitem, zichtbaar zonder het menu te openen).
public struct PermissionsModel: Sendable, Equatable {
    public let items: [PermissionItem]

    public init(microphoneGranted: Bool, accessibilityGranted: Bool, inputMonitoringGranted: Bool) {
        self.items = [
            PermissionItem(kind: .microphone, isGranted: microphoneGranted),
            PermissionItem(kind: .accessibility, isGranted: accessibilityGranted),
            PermissionItem(kind: .inputMonitoring, isGranted: inputMonitoringGranted),
        ]
    }

    /// Of minstens één permissie ontbreekt — dan toont het statusitem dat er iets mis is.
    public var anyMissing: Bool { items.contains { !$0.isGranted } }

    /// De ontbrekende permissies, in vaste volgorde.
    public var missingKinds: [PermissionKind] { items.filter { !$0.isGranted }.map(\.kind) }

    /// De korte regel voor het bannertje in het hoofdpaneel, of nil als alles er is.
    /// Noemt wát er ontbreekt, want "een permissie ontbreekt" laat je zoeken; de volledige
    /// uitleg en de knoppen staan in het instellingenvenster.
    public var bannerText: String? {
        let missing = missingKinds
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.title).joined(separator: ", ")
        return missing.count == 1
            ? "\(names) ontbreekt."
            : "Ontbreekt: \(names)."
    }
}

// MARK: - Injecteerbare statusbron

/// De drie statuslagen achter één injecteerbaar protocol, zodat de suite een stub geeft
/// in plaats van echte TCC te lezen (die per machine verschilt en niet vanuit een test te
/// zetten is).
public protocol PermissionStatusSource: Sendable {
    func microphoneGranted() -> Bool
    func accessibilityGranted() -> Bool
    func inputMonitoringGranted() -> Bool
}

/// De echte statusbron: microfoon uit PL-740 (`MicrophonePermission`), Toegankelijkheid
/// via `AXIsProcessTrusted` (dezelfde check als `CGEventKeystrokeInserter`), Invoerbewaking
/// via `IOHIDCheckAccess` (`InputMonitoring`). Leest alleen; vraagt niets aan. Mensentest
/// voor de echte waarden.
public struct SystemPermissionStatusSource: PermissionStatusSource {
    private let microphone: MicrophonePermission

    public init(microphone: MicrophonePermission = AVCaptureMicrophonePermission()) {
        self.microphone = microphone
    }

    public func microphoneGranted() -> Bool {
        microphone.authorizationStatus() == .authorized
    }

    public func accessibilityGranted() -> Bool {
        #if canImport(CoreGraphics) && canImport(ApplicationServices)
        return CGEventKeystrokeInserter().isAuthorized
        #else
        return true
        #endif
    }

    public func inputMonitoringGranted() -> Bool {
        InputMonitoring.isGranted()
    }
}

/// Leest de drie statuslagen op het moment van vragen en levert een `PermissionsModel`.
/// Cachet niets: elke `snapshot()` leest opnieuw, zodat een omgezet vinkje klopt zonder
/// herstart van de app.
public struct PermissionsProbe: Sendable {
    private let source: PermissionStatusSource

    public init(source: PermissionStatusSource = SystemPermissionStatusSource()) {
        self.source = source
    }

    public func snapshot() -> PermissionsModel {
        PermissionsModel(
            microphoneGranted: source.microphoneGranted(),
            accessibilityGranted: source.accessibilityGranted(),
            inputMonitoringGranted: source.inputMonitoringGranted())
    }
}

// MARK: - Eerste start

/// Beslist of de sectie zich bij de eerste start aanbiedt: dan is het gat het grootst en
/// zijn meestal alle drie de permissies er nog niet. Puur en persistent-onafhankelijk;
/// de aanroeper geeft de bewaarde vlag en zet hem daarna.
public enum FirstRunGate {
    /// Bied het paneel aan als de app nog niet eerder is gestart.
    public static func shouldOffer(hasLaunchedBefore: Bool) -> Bool {
        !hasLaunchedBefore
    }
}

#if canImport(AppKit)
import AppKit

// MARK: - AppKit-laag (mensentest)

/// Tekent het `PermissionsModel` als rijen in een `NSStackView` die de aanroeper levert.
/// Sinds PL-788 is dat het instellingenvenster; het hoofdpaneel toont alleen nog een
/// bannertje. Elke rij: naam + live status, wat er zonder werkt en niet, een herstart-hint
/// als die geldt, en een gecentreerde knop naar Systeeminstellingen. Divider boven en
/// onder het blok.
@MainActor
public final class PermissionsSectionView {
    /// Aangeroepen als de knop bij een permissie geklikt wordt, met de soort. De aanroeper
    /// opent het Systeeminstellingen-paneel; deze view opent zelf niets (ROE §2).
    public var onOpenSettings: ((PermissionKind) -> Void)?

    public init() {}

    /// Vult (of hervult) de slot uit het model. Leest niet zelf de status — de aanroeper
    /// geeft een vers `snapshot()` zodat de sectie live klopt bij elke opening.
    public func render(_ model: PermissionsModel, into slot: NSStackView) {
        for view in slot.arrangedSubviews {
            slot.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        // Divider alleen bóven het blok. Eronder staat niets meer, en een lijn onder het
        // laatste blok scheidt de inhoud van de vensterrand — dat leest als een afgekapte
        // lijst in plaats van een afgeronde.
        slot.addArrangedSubview(makeDivider())
        slot.addArrangedSubview(makeHeader())
        for item in model.items {
            slot.addArrangedSubview(makeRow(item))
        }
    }

    private func makeDivider() -> NSView {
        HotkeySettingsWindowController.divider()
    }

    private func makeHeader() -> NSView {
        HotkeySettingsWindowController.sectionHeader("Permissies")
    }

    /// Eén permissie als twee regels: naam, status en de tandwielknop op één rij, met
    /// daaronder wat er zonder werkt en de herstart-hint.
    ///
    /// De knop droeg eerst het volledige "Open in Systeeminstellingen" op een eigen
    /// gecentreerde regel. Drie van die regels onder elkaar maakten het blok twee keer zo
    /// hoog en lieten het als drie losse kaarten lezen; als tandwiel naast de status is
    /// het één rij per permissie. De tekst blijft als tooltip en als VoiceOver-label, dus
    /// de betekenis gaat niet verloren met het icoon.
    private func makeRow(_ item: PermissionItem) -> NSView {
        let status = HotkeySettingsWindowController.captionLabel(item.statusLabel)
        if !item.isGranted { status.textColor = .systemOrange }

        let button = NSButton(title: "", target: self, action: #selector(openClicked(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.image = NSImage(
            systemSymbolName: "gearshape", accessibilityDescription: item.buttonTitle)
        button.imagePosition = .imageOnly
        button.toolTip = item.buttonTitle
        button.setAccessibilityLabel(item.buttonTitle)
        button.identifier = NSUserInterfaceItemIdentifier(item.kind.rawValue)

        let head = HotkeySettingsWindowController.fullWidthRow(
            [HotkeySettingsWindowController.rowLabel(item.title), status, button])

        var rows: [NSView] = [head, HotkeySettingsWindowController.captionLabel(
            item.effect, wrapping: true)]
        if let hint = item.restartHint {
            rows.append(HotkeySettingsWindowController.captionLabel(hint, wrapping: true))
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(
            equalToConstant: HotkeySettingsWindowController.contentWidth).isActive = true
        // Ook de rij zelf mag niet meegroeien met de ruimte die de omringende stack over
        // heeft; hij is precies zo hoog als zijn drie regels.
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setHuggingPriority(.required, for: .vertical)
        return stack
    }

    @objc private func openClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let kind = PermissionKind(rawValue: raw) else { return }
        onOpenSettings?(kind)
    }
}
#endif
