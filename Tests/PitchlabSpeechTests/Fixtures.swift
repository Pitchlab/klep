import Foundation

/// Test-fixtures. Staat los van de test-bestanden zelf omdat `import Testing`
/// samen met `import Foundation` in één bestand de cross-import overlay
/// `_Testing_Foundation` triggert, waarvan de module-interface ontbreekt in de
/// Command-Line-Tools-only toolchain. Foundation blijft daarom in dit bestand,
/// Testing in het testbestand.
enum Fixtures {
    /// Nederlandse fixture uit spike PL-715 (`say -v Xander 'Zet hands free
    /// modus aan en typ dit bij de cursor.'`, 16 kHz mono wav), meegebundeld als
    /// test-resource.
    static var dutchUtterance: URL {
        guard let url = Bundle.module.url(forResource: "fixture", withExtension: "wav") else {
            fatalError("fixture.wav ontbreekt in de test-bundle")
        }
        return url
    }
}
