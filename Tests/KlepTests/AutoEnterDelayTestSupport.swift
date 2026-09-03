import Foundation
@testable import Klep

/// Foundation-hulp voor `AutoEnterDelayTests`. Los van het testbestand omdat `import
/// Testing` samen met `import Foundation` de cross-import overlay `_Testing_Foundation`
/// triggert, die ontbreekt in de CLT-only toolchain (zie `MenuBarTestSupport.swift`).
/// De helpers geven kale stdlib-types terug zodat het testbestand geen Foundation hoeft.
enum AutoEnterDelayTestSupport {

    struct Persistence {
        let fallbackBeforeStore: Double
        let readBack: Double
    }

    /// Bewijst dat een ingestelde waarde een herstart overleeft: schrijf hem naar een
    /// geïsoleerde suite, lees hem terug alsof de app opnieuw start. Ruimt de suite
    /// daarna op zodat de echte defaults nooit geraakt worden.
    static func storeAndReadBack(_ seconds: Double) -> Persistence {
        let suiteName = "pitchlab.speech.autoenter.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let before = AutoEnterDelay.stored(in: defaults)
        AutoEnterDelay.store(seconds, in: defaults)
        return Persistence(fallbackBeforeStore: before,
                           readBack: AutoEnterDelay.stored(in: defaults))
    }

    /// Idem voor de VAD-stiltedrempel, plus de config die de segmenter er echt uit
    /// krijgt — anders bewijst de test alleen dat een getal bewaard blijft.
    static func storeSilenceAndReadBack(_ seconds: Double) -> (readBack: Double, config: Double) {
        let suiteName = "pitchlab.speech.silence.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SilenceThreshold.store(seconds, in: defaults)
        return (SilenceThreshold.stored(in: defaults),
                SilenceThreshold.segmentationConfig(in: defaults).minSilenceDuration)
    }

    /// De twee sleutels, zodat de test kan vaststellen dat ze verschillen zonder zelf
    /// Foundation te hoeven importeren.
    static var keys: (autoEnter: String, silence: String) {
        (AutoEnterDelay.defaultsKey, SilenceThreshold.defaultsKey)
    }
}
