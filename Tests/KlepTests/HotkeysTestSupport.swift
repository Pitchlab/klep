import Foundation
@testable import Klep

/// Foundation-hulp voor de hotkey-tests. Los van het testbestand omdat `import
/// Testing` samen met `import Foundation` in één bestand de cross-import overlay
/// `_Testing_Foundation` triggert, die ontbreekt in de CLT-only toolchain (zie
/// `MenuBarTestSupport.swift`). Testing blijft in `HotkeysTests.swift`, Foundation
/// hier. De helpers geven kale types terug zodat het testbestand geen Foundation
/// hoeft te importeren.
enum HotkeysTestSupport {

    /// Geheugen-implementatie van `HotkeyDefaults`, zodat de store getest wordt
    /// zonder de echte `UserDefaults` aan te raken.
    final class MemoryDefaults: HotkeyDefaults {
        private var storage: [String: Any] = [:]

        func string(forKey key: String) -> String? { storage[key] as? String }
        func bool(forKey key: String) -> Bool { (storage[key] as? Bool) ?? false }
        func set(_ value: Any?, forKey key: String) {
            if let value { storage[key] = value } else { storage[key] = nil }
        }
    }

    /// Een verse store op geheugen-defaults.
    static func makeStore() -> HotkeyStore {
        HotkeyStore(defaults: MemoryDefaults())
    }
}
