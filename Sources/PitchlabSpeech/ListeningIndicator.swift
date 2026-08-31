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

    public var currentLevel: AudioLevel {
        lock.lock(); defer { lock.unlock() }
        return level
    }
}

// MARK: - Positie

/// De schermpositie van de stip (onderkant-links, AppKit-coördinaten). Bewaard tussen
/// sessies zodat de stip terugkomt waar je hem liet staan.
public struct IndicatorPosition: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Persistente opslag van de stip-positie. Protocol zodat de test een geheugen-store
/// gebruikt en de echte positie in `UserDefaults` een herstart overleeft.
public protocol IndicatorPositionStore: AnyObject {
    func savedPosition() -> IndicatorPosition?
    func save(_ position: IndicatorPosition)
}

/// `UserDefaults`-backed store — de positie blijft bewaard tussen sessies (R7).
public final class UserDefaultsIndicatorPositionStore: IndicatorPositionStore {
    private let defaults: UserDefaults
    private let xKey = "pitchlab.speech.indicator.x"
    private let yKey = "pitchlab.speech.indicator.y"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func savedPosition() -> IndicatorPosition? {
        guard defaults.object(forKey: xKey) != nil,
              defaults.object(forKey: yKey) != nil else { return nil }
        return IndicatorPosition(
            x: defaults.double(forKey: xKey), y: defaults.double(forKey: yKey))
    }

    public func save(_ position: IndicatorPosition) {
        defaults.set(position.x, forKey: xKey)
        defaults.set(position.y, forKey: yKey)
    }
}

// MARK: - Niveau → grootte

/// Vertaalt een audioniveau naar de diameter van de stip. Bij stilte de minimale
/// grootte (je ziet dát hij luistert), bij luid de maximale (je ziet dat hij je
/// hóórt). Lineair tussen min en max — geen animatie-logica, alleen de vertaling.
public struct ListeningIndicatorModel: Sendable, Equatable {
    public let minDiameter: Double
    public let maxDiameter: Double

    public init(minDiameter: Double = 14, maxDiameter: Double = 42) {
        self.minDiameter = min(minDiameter, maxDiameter)
        self.maxDiameter = max(minDiameter, maxDiameter)
    }

    /// De diameter voor een niveau: `min` bij 0, `max` bij 1, lineair ertussen.
    public func diameter(for level: AudioLevel) -> Double {
        minDiameter + (maxDiameter - minDiameter) * level.value
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
    var diameter: CGFloat = 14 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let d = min(diameter, min(bounds.width, bounds.height))
        let rect = NSRect(
            x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        let path = NSBezierPath(ovalIn: rect)
        NSColor.systemRed.withAlphaComponent(0.55).setFill()
        path.fill()
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

    private static let panelSize = NSSize(width: 56, height: 56)

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

    /// Zet de stip op de bewaarde positie, of rechtsonder als er nog geen is.
    private func moveToSavedOrDefaultPosition() {
        if let saved = positionStore.savedPosition() {
            panel.setFrameOrigin(NSPoint(x: saved.x, y: saved.y))
            return
        }
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - Self.panelSize.width - 24,
                y: visible.minY + 24))
        }
    }

    /// Toon de stip en begin het niveau te volgen. Aanroepen zodra luisteren start.
    public func show() {
        dot.diameter = CGFloat(model.diameter(for: levelSource.currentLevel))
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

    /// Tekent de stip op de grootte die bij `level` hoort (ook los aan te roepen).
    public func update(level: AudioLevel) {
        dot.diameter = CGFloat(model.diameter(for: level))
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
        let origin = panel.frame.origin
        positionStore.save(IndicatorPosition(x: Double(origin.x), y: Double(origin.y)))
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
#endif
