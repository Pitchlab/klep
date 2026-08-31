import Foundation
@testable import PitchlabSpeech

/// Foundation-hulp voor de indicator-tests. Los van het testbestand omdat `import
/// Testing` samen met `import Foundation` de cross-import overlay `_Testing_Foundation`
/// triggert, die ontbreekt in de CLT-only toolchain (zie `MenuBarTestSupport.swift`).
/// De helper geeft kale stdlib-types terug zodat het testbestand geen Foundation hoeft.
enum ListeningIndicatorTestSupport {

    struct PositionPersistence {
        let emptyBeforeSave: Bool
        let readBackX: Double
        let readBackY: Double
    }

    /// Bewijst dat de positie een sessie overleeft: schrijf de relatieve positie met de
    /// ene store weg naar een geïsoleerde `UserDefaults`-suite, lees hem met een verse
    /// store terug (zoals na een herstart). Ruimt de suite daarna op zodat de echte
    /// defaults nooit geraakt worden.
    static func runPositionPersistenceAcrossStores(
        fractionX: Double, fractionY: Double
    ) -> PositionPersistence {
        let suiteName = "pitchlab.speech.indicator.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let writer = UserDefaultsIndicatorPositionStore(defaults: defaults)
        let emptyBeforeSave = writer.savedPosition() == nil
        writer.save(IndicatorPosition(fractionX: fractionX, fractionY: fractionY))

        // Verse store op dezelfde suite: simuleert een nieuwe sessie.
        let reader = UserDefaultsIndicatorPositionStore(defaults: defaults)
        let read = reader.savedPosition()

        return PositionPersistence(
            emptyBeforeSave: emptyBeforeSave,
            readBackX: read?.fractionX ?? .nan,
            readBackY: read?.fractionY ?? .nan)
    }
}
