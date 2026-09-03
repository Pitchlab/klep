@testable import Klep

/// Een injecteerbare statusbron met omzetbare standen, zodat de suite de live-afbeelding
/// test zonder echte TCC. `@unchecked Sendable`: muteerbaar en enkel binnen één serie test
/// gebruikt. Draai de vinkjes om tussen twee `snapshot()`-aanroepen om te bewijzen dat de
/// probe niets cachet.
final class StubPermissionStatusSource: PermissionStatusSource, @unchecked Sendable {
    var microphone: Bool
    var accessibility: Bool
    var inputMonitoring: Bool

    init(microphone: Bool = false, accessibility: Bool = false, inputMonitoring: Bool = false) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }

    func microphoneGranted() -> Bool { microphone }
    func accessibilityGranted() -> Bool { accessibility }
    func inputMonitoringGranted() -> Bool { inputMonitoring }
}
