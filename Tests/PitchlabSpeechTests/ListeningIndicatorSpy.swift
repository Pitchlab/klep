import Foundation
@testable import PitchlabSpeech

/// Telbare `ListeningIndicating`-dubbel voor de hands-free-bedradingstests. In
/// productie voedt de keten de main-actor `ListeningIndicatorController` (via de
/// `MainActorListeningIndicator`-bridge); die vraagt een venster en runloop en hoort
/// niet in de headless gate. Deze dubbel houdt in plaats daarvan de show/hide-tellers
/// en de niveaus-tijdens-zichtbaar vast, zodat de test bewijst dat de indicator
/// zichtbaar was tijdens het luisteren en met een echt niveau gevoed werd.
final class ListeningIndicator: ListeningIndicating, @unchecked Sendable {
    private let lock = NSLock()
    private var _visible = false
    private var _level: Float = 0
    private var _showCount = 0
    private var _hideCount = 0
    private var _levelsWhileVisible: [Float] = []

    /// Staat de indicator nu aan (hands-free luistert).
    var isVisible: Bool { lock.withLock { _visible } }
    /// Het laatst getoonde niveau (0…1).
    var level: Float { lock.withLock { _level } }
    /// Hoe vaak `show()` en `hide()` aangeroepen zijn — voor de wiring-test.
    var showCount: Int { lock.withLock { _showCount } }
    var hideCount: Int { lock.withLock { _hideCount } }
    /// De niveaus die binnenkwamen terwijl de indicator zichtbaar was.
    var levelsWhileVisible: [Float] { lock.withLock { _levelsWhileVisible } }

    func show() {
        lock.withLock {
            _visible = true
            _showCount += 1
        }
    }

    func update(level: Float) {
        lock.withLock {
            _level = level
            if _visible { _levelsWhileVisible.append(level) }
        }
    }

    func hide() {
        lock.withLock {
            _visible = false
            _level = 0
            _hideCount += 1
        }
    }
}
