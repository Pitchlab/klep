import Foundation

/// Test-fixtures. Staat los van de test-bestanden zelf omdat `import Testing`
/// samen met `import Foundation` in één bestand de cross-import overlay
/// `_Testing_Foundation` triggert, waarvan de module-interface ontbreekt in de
/// Command-Line-Tools-only toolchain. Foundation blijft daarom in dit bestand,
/// Testing in het testbestand.
enum Fixtures {
    private static let sentence = "Zet hands free modus aan en typ dit bij de cursor."

    /// Nederlandse fixture uit spike PL-715 (`say -v Xander`, 16 kHz mono wav).
    /// Wordt bij eerste gebruik gegenereerd in een tijdelijk pad en niet gecommit
    /// (ROE §5: audio hoort niet in git). `say` en `afconvert` zijn beide native
    /// in de Command Line Tools, dus geen externe dependency.
    static let dutchUtterance: URL = generate()

    private static func generate() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitchlab-speech-fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let aiff = dir.appendingPathComponent("dutch.aiff")
        let wav = dir.appendingPathComponent("dutch.wav")
        if FileManager.default.fileExists(atPath: wav.path) { return wav }

        run("/usr/bin/say", ["-v", "Xander", "-o", aiff.path, sentence])
        // 16 kHz mono 16-bit little-endian: het formaat dat FluidAudio verwacht.
        run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])

        guard FileManager.default.fileExists(atPath: wav.path) else {
            fatalError("fixture-generatie faalde: \(wav.path) niet aangemaakt")
        }
        return wav
    }

    private static func run(_ launchPath: String, _ arguments: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                fatalError("\(launchPath) faalde met status \(proc.terminationStatus)")
            }
        } catch {
            fatalError("\(launchPath) kon niet starten: \(error)")
        }
    }
}
