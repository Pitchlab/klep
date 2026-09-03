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

    /// Dezelfde NL-fixture op het vaste pad dat de CLI-gate leest,
    /// `Tests/Fixtures/nl_short.wav`. Wordt hier met `say` gegenereerd (ROE §5:
    /// audio nooit committen — de map is gitignored) en met `#filePath` gelokaliseerd
    /// zodat de working directory niet uitmaakt. `swift test` draait in de gate vóór
    /// de CLI-stap, dus het bestand bestaat wanneer `klep --once` het leest.
    static let shortFixtureURL: URL = generateShort()

    /// De map `Tests/Fixtures/`, afgeleid van dit bestand (`Tests/KlepTests/`).
    static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)      // …/Tests/KlepTests/Fixtures.swift
            .deletingLastPathComponent()     // …/Tests/KlepTests
            .deletingLastPathComponent()     // …/Tests
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private static func generateShort() -> URL {
        let dir = fixturesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("nl_short.wav")
        if FileManager.default.fileExists(atPath: wav.path) { return wav }

        let aiff = dir.appendingPathComponent("nl_short.aiff")
        run("/usr/bin/say", ["-v", "Xander", "-o", aiff.path, sentence])
        run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        try? FileManager.default.removeItem(at: aiff)

        guard FileManager.default.fileExists(atPath: wav.path) else {
            fatalError("korte fixture-generatie faalde: \(wav.path) niet aangemaakt")
        }
        return wav
    }

    private static func generate() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("klep-fixtures", isDirectory: true)
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
