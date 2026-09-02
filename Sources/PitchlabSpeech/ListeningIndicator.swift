/// Zichtbare luister-indicator: een verplaatsbare stip die meebeweegt met je stem (R7).
///
/// Twee lagen, gescheiden zodat de logica zonder AppKit-runloop te testen is:
///  - Pure model-laag (`AudioLevel`, `AudioLevelMeter`, `IndicatorPosition`,
///    `IndicatorPositionStore`, `ListeningIndicatorModel`, `IndicatorInteraction`):
///    het meten van het niveau, de vertaling niveau→stip-grootte en de
///    positie-persistentie. Geen `NSPanel`, geen runloop — direct te testen.
///  - AppKit-laag (`ListeningIndicatorController`), onder `#if canImport(AppKit)`:
///    het non-activating `NSPanel` dat de stip tekent, muis-events doorlaat behalve
///    tijdens slepen, en de positie bewaart. Compileert in de gate; het echt tonen
///    van het venster is een mensentest (PRD, R7).
///
/// Het audioniveau is injecteerbaar (`AudioLevelSource`): de weergave leest hier het
/// niveau, de test voedt samples zonder microfoon. Zo zie je dat de app je hóórt en
/// niet alleen dat hij aan staat — een gedempte microfoon laat de stip stil liggen.
import Foundation

// MARK: - Contract

/// Wat de hands-free-keten de indicator laat doen: tonen bij het begin van luisteren,
/// het niveau bijwerken zolang het loopt, en verbergen zodra hands-free uit gaat.
/// `Sendable` + `AnyObject` zodat de `HandsFreeController`-actor hem nonisolated kan
/// voeden. De productie-implementatie is `MainActorListeningIndicator`, die de
/// main-actor `ListeningIndicatorController` bedient zonder diens isolatie te
/// verzwakken; de tests injecteren een telbare dubbel.
public protocol ListeningIndicating: AnyObject, Sendable {
    /// Toon de indicator: hands-free is aan, de microfoon staat open.
    func show()
    /// Werk het getoonde niveau bij (0…1, RMS van de laatste audio).
    func update(level: Float)
    /// Verberg de indicator: hands-free is uit.
    func hide()
}

// MARK: - Audioniveau

/// Momentaan audioniveau, geklemd op 0…1. 0 is stilte (of gedempt), 1 is luid.
public struct AudioLevel: Sendable, Equatable {
    public let value: Double

    public init(_ value: Double) { self.value = min(max(value, 0), 1) }

    public static let silent = AudioLevel(0)

    /// RMS (root-mean-square) van 16 kHz mono samples, geschaald naar 0…1. RMS is de
    /// energie van het signaal: stilte ≈ 0, spraak stijgt mee met het volume. De
    /// `sensitivity` tilt het typische spraakniveau naar de bovenkant van het bereik;
    /// het resultaat wordt geklemd zodat een piek de stip niet buiten beeld duwt.
    public static func rms(of samples: [Float], sensitivity: Double = 8.0) -> AudioLevel {
        guard !samples.isEmpty else { return .silent }
        var sumOfSquares = 0.0
        for sample in samples {
            let v = Double(sample)
            sumOfSquares += v * v
        }
        let rms = (sumOfSquares / Double(samples.count)).squareRoot()
        return AudioLevel(rms * sensitivity)
    }
}

/// Bron van het momentane audioniveau, injecteerbaar zodat de weergave zonder
/// microfoon te sturen is. In productie is dit een `AudioLevelMeter` die de
/// capture-pijplijn voedt; in de test een dubbel dat een vast niveau teruggeeft.
public protocol AudioLevelSource: AnyObject, Sendable {
    var currentLevel: AudioLevel { get }
}

/// Houdt het laatst gemeten audioniveau vast. De capture-laag roept `ingest` aan met
/// verse samples; de weergave leest `currentLevel`. Thread-safe met een lock omdat
/// samples binnenkomen op de audio-queue en de stip getekend wordt op de main-thread.
public final class AudioLevelMeter: AudioLevelSource, @unchecked Sendable {
    private let lock = NSLock()
    private var level: AudioLevel = .silent
    private let sensitivity: Double

    public init(sensitivity: Double = 8.0) { self.sensitivity = sensitivity }

    /// Meet het niveau van dit stuk samples en onthoudt het als het huidige niveau.
    public func ingest(_ samples: [Float]) {
        let measured = AudioLevel.rms(of: samples, sensitivity: sensitivity)
        lock.lock(); level = measured; lock.unlock()
    }

    /// Zet het niveau terug naar stilte (bij stoppen met luisteren).
    public func reset() {
        lock.lock(); level = .silent; lock.unlock()
    }

    /// Zet het niveau rechtstreeks op een al berekende waarde. De hands-free-keten
    /// levert per audiobuffer een kant-en-klaar RMS-niveau (`HandsFreeEvent.level`);
    /// dat schrijft de bridge hier weg zodat de `ListeningIndicatorController` het bij
    /// zijn volgende poll oppikt, in plaats van de samples nog eens te meten.
    public func set(_ level: AudioLevel) {
        lock.lock(); self.level = level; lock.unlock()
    }

    public var currentLevel: AudioLevel {
        lock.lock(); defer { lock.unlock() }
        return level
    }
}

// MARK: - Positie

/// De schermpositie van de stip als fractie van de zichtbare frame, 0…1 in beide assen
/// (AppKit-coördinaten, onderkant-links). `0.5/0.5` is het midden. Relatief bewaard,
/// niet in absolute punten, zodat de stip zichtbaar blijft als je een monitor
/// loskoppelt of de resolutie verandert — een absolute punt-positie valt dan buiten
/// beeld en dat is precies hoe de stip "kwijtraakte".
public struct IndicatorPosition: Sendable, Equatable {
    /// Horizontale fractie van de zichtbare frame, geklemd op 0…1.
    public let fractionX: Double
    /// Verticale fractie van de zichtbare frame, geklemd op 0…1.
    public let fractionY: Double

    public init(fractionX: Double, fractionY: Double) {
        self.fractionX = min(max(fractionX, 0), 1)
        self.fractionY = min(max(fractionY, 0), 1)
    }

    /// Het midden van het scherm — de voorspelbare startplek zonder bewaarde positie.
    public static let center = IndicatorPosition(fractionX: 0.5, fractionY: 0.5)
}

/// Rekenwerk om een relatieve positie op een concreet scherm te plaatsen en andersom,
/// los van AppKit zodat het testbaar is zonder venster. De `visible*`-waarden zijn de
/// zichtbare frame van het scherm (menubalk en Dock eraf); `panel*` de grootte van het
/// stip-venster. De fractie plaatst het MIDDEN van het venster; de oorsprong wordt
/// daarna geklemd zodat het hele venster binnen de zichtbare frame blijft.
public enum IndicatorGeometry {

    /// De venster-oorsprong (onderkant-links) op één as voor een fractie. Klemt zo dat
    /// het venster volledig binnen `[visibleMin, visibleMin + visibleLength]` valt; is
    /// het scherm smaller dan het venster, dan wint `visibleMin` (nooit erbuiten links).
    public static func origin(
        fraction: Double, visibleMin: Double, visibleLength: Double, panelLength: Double
    ) -> Double {
        let center = visibleMin + fraction * visibleLength
        let unclamped = center - panelLength / 2
        let lo = visibleMin
        let hi = visibleMin + visibleLength - panelLength
        return min(max(unclamped, lo), max(lo, hi))
    }

    /// De fractie die bij een venster-oorsprong hoort (na slepen), zodat het opslaan
    /// relatief gebeurt. Meet het midden van het venster tegen de zichtbare frame af.
    public static func fraction(
        origin: Double, visibleMin: Double, visibleLength: Double, panelLength: Double
    ) -> Double {
        guard visibleLength > 0 else { return 0.5 }
        let center = origin + panelLength / 2
        return min(max((center - visibleMin) / visibleLength, 0), 1)
    }
}

/// Persistente opslag van de stip-positie. Protocol zodat de test een geheugen-store
/// gebruikt en de echte positie in `UserDefaults` een herstart overleeft.
public protocol IndicatorPositionStore: AnyObject {
    func savedPosition() -> IndicatorPosition?
    func save(_ position: IndicatorPosition)
}

/// `UserDefaults`-backed store — de positie blijft bewaard tussen sessies (R7). Bewaart
/// fracties onder eigen sleutels; de oude absolute-punt-sleutels worden bewust niet
/// hergebruikt zodat een eerder opgeslagen punt niet als fractie wordt gelezen.
public final class UserDefaultsIndicatorPositionStore: IndicatorPositionStore {
    private let defaults: UserDefaults
    private let xKey = "pitchlab.speech.indicator.fx"
    private let yKey = "pitchlab.speech.indicator.fy"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func savedPosition() -> IndicatorPosition? {
        guard defaults.object(forKey: xKey) != nil,
              defaults.object(forKey: yKey) != nil else { return nil }
        return IndicatorPosition(
            fractionX: defaults.double(forKey: xKey), fractionY: defaults.double(forKey: yKey))
    }

    public func save(_ position: IndicatorPosition) {
        defaults.set(position.fractionX, forKey: xKey)
        defaults.set(position.fractionY, forKey: yKey)
    }
}

// MARK: - Niveau → grootte

/// Vertaalt een audioniveau naar de maat en de dekking van de stip.
///
/// HERZIEN DOOR PL-747, want hij reageerde te subtiel om iets aan te hebben. Twee
/// dingen volgen nu het niveau, en één ding juist niet:
///  - de DIAMETER groeit van 21 naar 63 punt (was 14 tot 42, dus anderhalf keer zo
///    groot). Groeien was het enige dat al werkte en blijft.
///  - de VULLINGSDEKKING loopt van 0,25 bij stilte naar 0,75 bij vol niveau. Dat
///    verving de vaste 0,55 rood: bij stilte zie je dát hij luistert, bij praten dat
///    hij je hóórt, en het verschil is nu ook zonder meten zichtbaar.
///  - de OUTLINE niet. Vaste breedte, vaste dekking, ongeacht het niveau — dat is de
///    rand waaraan je de stip terugvindt op een lichte achtergrond, en die mag niet
///    mee wegvallen met de vulling.
///
/// Geen animatie-logica, alleen de vertaling; de controller pollt op 30 Hz.
public struct ListeningIndicatorModel: Sendable, Equatable {
    public let minDiameter: Double
    public let maxDiameter: Double

    /// De dekking van de vulling bij stilte en bij vol niveau.
    public static let minFillOpacity: Double = 0.25
    public static let maxFillOpacity: Double = 0.75

    /// De rand: 2 punt breed op 0,9 dekking, vast. Wit-op-wit is de valkuil hier — een
    /// witte stip op een licht bureaublad verdwijnt zonder rand, en een rand die met de
    /// vulling meevervaagt lost hetzelfde probleem niet op. Gemeten keuze: 2 punt is bij
    /// 21 punt diameter nog een tiende van de breedte, dus zichtbaar zonder de kleinste
    /// stand dicht te smeren.
    public static let outlineWidth: Double = 2
    public static let outlineOpacity: Double = 0.9

    public init(minDiameter: Double = 21, maxDiameter: Double = 63) {
        self.minDiameter = min(minDiameter, maxDiameter)
        self.maxDiameter = max(minDiameter, maxDiameter)
    }

    /// De diameter voor een niveau: `min` bij 0, `max` bij 1, lineair ertussen.
    public func diameter(for level: AudioLevel) -> Double {
        minDiameter + (maxDiameter - minDiameter) * level.value
    }

    /// De dekking van de vulling voor een niveau, lineair tussen 0,25 en 0,75.
    public func fillOpacity(for level: AudioLevel) -> Double {
        Self.minFillOpacity
            + (Self.maxFillOpacity - Self.minFillOpacity) * level.value
    }
}

// MARK: - Interactie (klik-doorlaat / slepen)

/// Het schakelmechanisme voor slepen. Klikken gaan standaard dwars door de stip heen
/// (`ignoresMouseEvents`), zodat de indicator nooit in de weg zit. Alleen met de
/// Option-toets (⌥) ingedrukt vangt het venster muis-events en kun je hem verslepen.
/// De keuze voor een modifier houdt de stip klik-transparant tijdens normaal werk en
/// vergt geen aparte "verplaats"-modus.
public enum IndicatorInteraction {
    /// De leesbare modifier die slepen inschakelt (voor melding/documentatie).
    public static let dragModifierLabel = "⌥"

    /// Of het venster muis-events moet vangen: alleen als de sleep-modifier ingedrukt
    /// is. Anders laat het venster klikken door (`ignoresMouseEvents == true`).
    public static func shouldCaptureMouse(dragModifierHeld: Bool) -> Bool {
        dragModifierHeld
    }
}

#if canImport(AppKit)
import AppKit

// MARK: - AppKit-laag (mensentest)

/// De stip zelf: tekent een half-transparante cirkel die de diameter volgt die het
/// niveau bepaalt. Het venster verandert niet van maat; de cirkel groeit binnen een
/// vaste kader, zodat groeien en krimpen geen herpositionering vragen.
@MainActor
final class IndicatorDotView: NSView {
    weak var controller: ListeningIndicatorController?
    var diameter: CGFloat = 21 { didSet { needsDisplay = true } }
    /// De dekking van de vulling; de outline trekt zich hier niets van aan.
    var fillOpacity: CGFloat = CGFloat(ListeningIndicatorModel.minFillOpacity) {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let line = CGFloat(ListeningIndicatorModel.outlineWidth)
        // De rand wordt op het pad getekend, dus hij steekt een halve lijnbreedte naar
        // buiten. Daarom die halve breedte van de beschikbare ruimte af, anders knipt
        // de view de buitenste rand van de grootste stand af.
        let available = min(bounds.width, bounds.height) - line
        let d = min(diameter, available)
        let rect = NSRect(
            x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        let path = NSBezierPath(ovalIn: rect)

        NSColor.white.withAlphaComponent(fillOpacity).setFill()
        path.fill()

        NSColor.white.withAlphaComponent(CGFloat(ListeningIndicatorModel.outlineOpacity))
            .setStroke()
        path.lineWidth = line
        path.stroke()
    }
}

/// Non-activating `NSPanel` met de luister-stip. Steelt geen focus, staat niet in de
/// vensterlijst, altijd bovenop, half transparant. Verschijnt tijdens luisteren
/// (`show`) en verdwijnt als hands-free uit staat (`hide`). Klikken gaan standaard
/// door de stip heen; met ⌥ ingedrukt vang je muis-events om te slepen, en de
/// positie wordt na het slepen bewaard. Runtime niet gedekt door de unit-tests: een
/// venster tonen vraagt een NSApplication-runloop (PRD-mensentest). De meetbare
/// logica zit in `AudioLevel(Meter)`, `ListeningIndicatorModel` en de positie-store.
@MainActor
public final class ListeningIndicatorController {
    private let panel: NSPanel
    private let dot: IndicatorDotView
    private let model: ListeningIndicatorModel
    private let levelSource: AudioLevelSource
    private let positionStore: IndicatorPositionStore

    private var pollTimer: Timer?
    private var flagsMonitor: Any?
    private var isDragging = false
    private var dragOffset: NSPoint = .zero

    /// Ruim boven de grootste stip (63 punt) plus de outline, anders klemt `draw` de
    /// cirkel af en zie je een afgesneden rand op vol niveau.
    private static let panelSize = NSSize(width: 72, height: 72)

    public init(
        levelSource: AudioLevelSource,
        model: ListeningIndicatorModel = ListeningIndicatorModel(),
        positionStore: IndicatorPositionStore = UserDefaultsIndicatorPositionStore()
    ) {
        self.levelSource = levelSource
        self.model = model
        self.positionStore = positionStore

        let frame = NSRect(origin: .zero, size: Self.panelSize)
        self.panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        self.dot = IndicatorDotView(frame: frame)

        configurePanel()
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Klikken gaan standaard door de stip heen; ⌥ zet dit tijdelijk uit.
        panel.ignoresMouseEvents = true
        panel.contentView = dot
        dot.controller = self
        moveToSavedOrDefaultPosition()
    }

    /// Zet de stip op de bewaarde positie, of in het midden van het primaire scherm
    /// als er nog geen is. De relatieve positie wordt via `IndicatorGeometry` op de
    /// zichtbare frame geplaatst en geklemd, zodat de stip nooit buiten beeld valt.
    private func moveToSavedOrDefaultPosition() {
        place(positionStore.savedPosition() ?? .center)
    }

    /// Plaatst het stip-venster op een relatieve positie op het primaire scherm.
    private func place(_ position: IndicatorPosition) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = IndicatorGeometry.origin(
            fraction: position.fractionX, visibleMin: Double(visible.minX),
            visibleLength: Double(visible.width), panelLength: Double(Self.panelSize.width))
        let y = IndicatorGeometry.origin(
            fraction: position.fractionY, visibleMin: Double(visible.minY),
            visibleLength: Double(visible.height), panelLength: Double(Self.panelSize.height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Zet de stip terug naar het midden van het primaire scherm en bewaart die positie.
    ///
    /// NU ZONDER AANROEPER. Het menu-item dat dit aanriep is met het NSMenu verdwenen
    /// (PL-764) en er is bewust geen knop voor teruggekomen: PL-747 maakt de positie
    /// instelbaar als fractie van de schermhoogte, en dan is springen-naar-het-midden
    /// een geval van die regelaar. PL-747 beslist of deze methode weg kan of de basis
    /// wordt. Tot dan blijft hij staan als de enige weg terug voor een stip die buiten
    /// beeld raakte.
    public func resetToCenter() {
        positionStore.save(.center)
        place(.center)
    }

    /// Toon de stip en begin het niveau te volgen. Aanroepen zodra luisteren start.
    public func show() {
        apply(levelSource.currentLevel)
        panel.orderFrontRegardless()
        startPolling()
        startFlagsMonitor()
    }

    /// Verberg de stip en stop met volgen. Aanroepen als hands-free uit gaat.
    public func hide() {
        stopPolling()
        stopFlagsMonitor()
        panel.orderOut(nil)
    }

    /// Tekent de stip op de grootte én dekking die bij `level` horen (ook los aan te
    /// roepen).
    public func update(level: AudioLevel) {
        apply(level)
    }

    private func apply(_ level: AudioLevel) {
        dot.diameter = CGFloat(model.diameter(for: level))
        dot.fillOpacity = CGFloat(model.fillOpacity(for: level))
    }

    // MARK: Niveau volgen

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.update(level: self.levelSource.currentLevel)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Sleep-schakelaar (⌥)

    /// Volgt de Option-toets: ingedrukt → het venster vangt muis-events zodat je kunt
    /// slepen; losgelaten → klikken gaan er weer doorheen.
    private func startFlagsMonitor() {
        stopFlagsMonitor()
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let optionHeld = event.modifierFlags.contains(.option)
                self.panel.ignoresMouseEvents = !IndicatorInteraction.shouldCaptureMouse(
                    dragModifierHeld: optionHeld)
            }
        }
    }

    private func stopFlagsMonitor() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        panel.ignoresMouseEvents = true
    }

    // MARK: Slepen (aangeroepen vanuit de dot-view)

    fileprivate func beginDrag(at pointInWindow: NSPoint) {
        isDragging = true
        dragOffset = pointInWindow
    }

    fileprivate func dragMoved(to pointOnScreen: NSPoint) {
        guard isDragging else { return }
        panel.setFrameOrigin(NSPoint(
            x: pointOnScreen.x - dragOffset.x, y: pointOnScreen.y - dragOffset.y))
    }

    fileprivate func endDrag() {
        guard isDragging else { return }
        isDragging = false
        positionStore.save(currentRelativePosition())
    }

    /// De relatieve positie van het venster nu, tegen de zichtbare frame van het
    /// primaire scherm. Valt terug op het midden als er geen scherm is.
    private func currentRelativePosition() -> IndicatorPosition {
        guard let screen = NSScreen.main else { return .center }
        let visible = screen.visibleFrame
        let origin = panel.frame.origin
        return IndicatorPosition(
            fractionX: IndicatorGeometry.fraction(
                origin: Double(origin.x), visibleMin: Double(visible.minX),
                visibleLength: Double(visible.width), panelLength: Double(Self.panelSize.width)),
            fractionY: IndicatorGeometry.fraction(
                origin: Double(origin.y), visibleMin: Double(visible.minY),
                visibleLength: Double(visible.height), panelLength: Double(Self.panelSize.height)))
    }
}

/// De view leidt muis-events door naar de controller. Events komen alleen binnen als
/// het venster ze vangt — dat gebeurt alleen met ⌥ ingedrukt (zie `startFlagsMonitor`).
extension IndicatorDotView {
    override func mouseDown(with event: NSEvent) {
        controller?.beginDrag(at: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let onScreen = window.convertPoint(toScreen: event.locationInWindow)
        controller?.dragMoved(to: onScreen)
    }

    override func mouseUp(with event: NSEvent) {
        controller?.endDrag()
    }
}

// MARK: - Bridge naar de hands-free-keten

/// Vervult de `ListeningIndicating`-rand met de bestaande main-actor
/// `ListeningIndicatorController`, zonder diens isolatie te verzwakken. De
/// `HandsFreeController`-actor roept `show`/`update`/`hide` nonisolated aan; een
/// naïeve conformance op de controller zelf zou "conformance crosses into main
/// actor-isolated code" geven. Daarom hopt `show`/`hide` naar de main actor waar het
/// paneel leeft, en schrijft `update(level:)` het `Float`-niveau als `AudioLevel` in
/// de meter die de controller pollt — zo volgt de stip het echte niveau zonder dat
/// twee bronnen om de diameter vechten.
public final class MainActorListeningIndicator: ListeningIndicating {
    private let controller: ListeningIndicatorController
    private let meter: AudioLevelMeter

    public init(controller: ListeningIndicatorController, meter: AudioLevelMeter) {
        self.controller = controller
        self.meter = meter
    }

    public func show() {
        Task { @MainActor in controller.show() }
    }

    public func update(level: Float) {
        meter.set(AudioLevel(Double(level)))
    }

    public func hide() {
        Task { @MainActor in controller.hide() }
    }
}
#endif
