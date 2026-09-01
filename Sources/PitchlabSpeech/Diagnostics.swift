/// Diagnostiek: een logbestand en een stderr-spiegel zodat de app niet blind draait.
/// In een .app gaat stdout nergens heen; tot deze taak was het enige spoor een
/// menuregel, en elke diagnose was gokken op broncode en `lsof`. Hier komt één
/// kanaal dat de keten beschrijft: hands-free aan/uit met reden, gekozen apparaat,
/// permissiestatus per soort, uiting met duur, transcript-lengte en verstreken tijd,
/// uitvoerroute en of die slaagde, en elke fout met de plek waar hij ontstond.
///
/// Twee regels bepalen de vorm:
///  - GEEN inhoud. Transcripten staan standaard uit en horen niet in een log; er
///    worden alleen lengtes (aantal tekens) en tijden gelogd, nooit de tekst zelf.
///  - GEEN sample-ruis. Elke logregel beschrijft een schakel in de keten, niet elke
///    audio-sample of niveau-update.
///
/// De gebeurtenis is een `DiagnosticEvent` — een waarde met een `line`-eigenschap —
/// zodat de tekst aan de gebeurtenis hangt en niet als losse string door de keten
/// zwerft. `DiagnosticLog` schrijft naar `~/.pitchlab/klep/klep.log`, naast de config
/// en `sessions.jsonl` van PL-696, en kapt het bestand af zodat het niet volloopt.
/// De schakel in de keten praat tegen een `DiagnosticSink`; productie injecteert het
/// echte logbestand, de tests een spy, zodat de gate zonder aanraken van `~/.pitchlab`
/// draait.

import Foundation

// MARK: - Gebeurtenis

/// De ernst van een logregel. Bepaalt alleen het label in de regel; alles gaat naar
/// hetzelfde bestand.
public enum DiagnosticLevel: String, Sendable, Equatable {
    case info = "INFO"
    case error = "ERROR"
}

/// Eén schakel in de keten als waarde. De `line`-eigenschap draagt de tekst zodat de
/// aanroeper geen losse string doorgeeft; `level` scheidt fouten van de rest. Geen
/// case draagt transcript-inhoud: alleen lengtes, duren en routes.
public enum DiagnosticEvent: Sendable, Equatable {
    /// Hands-free aangezet, met de bron (sneltoets, menu, hersteld-bij-opstarten).
    case handsFreeOn(reason: String)
    /// Hands-free uitgezet, met de bron.
    case handsFreeOff(reason: String)
    /// Bij het opstarten herstelde hands-free-stand — getoond, maar (PL-742) niet
    /// noodzakelijk toegepast; de regel maakt het verschil zichtbaar.
    case handsFreeRestored(on: Bool)
    /// Het apparaat waarop de keten opneemt (nil = systeemstandaard).
    case deviceSelected(name: String?)
    /// De toestemmingsstatus per soort, vóór de opname (PL-740: geen stille stilte).
    case permission(kind: String, status: String)
    /// Een afgeronde uiting gedetecteerd, met de duur in milliseconden.
    case utteranceDetected(durationMs: Int)
    /// Een uiting getranscribeerd: aantal tekens (geen inhoud) en verstreken tijd.
    case transcribed(characters: Int, elapsedMs: Int)
    /// De uitvoer naar een route (cursor/stdout) en of die slaagde.
    case output(route: String, succeeded: Bool)
    /// Een fout, met de plek waar hij ontstond en de boodschap.
    case failure(origin: String, message: String)

    /// De ernst; alleen `failure` is een fout.
    public var level: DiagnosticLevel {
        if case .failure = self { return .error }
        return .info
    }

    /// De leesbare regel. Enige plek waar de tekst per gebeurtenis staat.
    public var line: String {
        switch self {
        case .handsFreeOn(let reason):
            return "hands-free aan (\(reason))"
        case .handsFreeOff(let reason):
            return "hands-free uit (\(reason))"
        case .handsFreeRestored(let on):
            return "hands-free herstelde stand bij opstarten: \(on ? "aan" : "uit")"
        case .deviceSelected(let name):
            return "apparaat gekozen: \(name ?? "(systeemstandaard)")"
        case .permission(let kind, let status):
            return "permissie \(kind): \(status)"
        case .utteranceDetected(let durationMs):
            return "uiting gedetecteerd, duur \(durationMs) ms"
        case .transcribed(let characters, let elapsedMs):
            return "transcript \(characters) tekens in \(elapsedMs) ms"
        case .output(let route, let succeeded):
            return "uitvoer \(route): \(succeeded ? "gelukt" : "mislukt")"
        case .failure(let origin, let message):
            return "fout in \(origin): \(message)"
        }
    }
}

// MARK: - Afvoer (injecteerbaar)

/// Waar diagnostiek heen gaat. Productie: het logbestand. Tests: een spy. De keten
/// kent alleen dit protocol, niet het bestand.
public protocol DiagnosticSink: Sendable {
    func log(_ event: DiagnosticEvent)
}

/// Slikt alles. De standaard voor code die geen echte logger krijgt (o.a. de bestaande
/// tests), zodat construeren nooit `~/.pitchlab` aanraakt.
public struct NullDiagnosticSink: DiagnosticSink {
    public init() {}
    public func log(_ event: DiagnosticEvent) {}
}

// MARK: - Logbestand

/// Schrijft diagnostiek naar een afgekapt logbestand en, als diagnostiek aan staat,
/// dezelfde regels naar stderr. Eén generatie rotatie: zodra het bestand `maxBytes`
/// zou overschrijden, gaat het naar `<naam>.1` en begint een vers bestand, zodat het
/// nooit onbegrensd groeit. `@unchecked Sendable`: de schrijf zit achter een `NSLock`
/// zodat de actor-keten en de MainActor er beide veilig in mogen schrijven.
public final class DiagnosticLog: DiagnosticSink, @unchecked Sendable {
    private let fileURL: URL
    private let maxBytes: Int
    private let mirrorToStderr: Bool
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    /// - Parameters:
    ///   - fileURL: het logbestand. Standaard `~/.pitchlab/klep/klep.log`.
    ///   - maxBytes: afkapdrempel; bij overschrijding roteert het bestand één keer.
    ///   - mirrorToStderr: spiegelt elke regel ook naar stderr. Standaard afgeleid van
    ///     de omgeving (`PITCHLAB_SPEECH_DIAG` of `--diagnostics`).
    ///   - now: klok, injecteerbaar zodat de test de tijdstempel vastzet.
    public init(
        fileURL: URL = DiagnosticLog.defaultFileURL,
        maxBytes: Int = 512_000,
        mirrorToStderr: Bool = DiagnosticLog.diagnosticsEnabled(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.mirrorToStderr = mirrorToStderr
        self.now = now
    }

    /// Het standaard-logpad naast de config van PL-696: `~/.pitchlab/klep/klep.log`.
    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pitchlab/klep/klep.log")
    }

    /// De rotatiebestemming: hetzelfde pad met `.1` erachter.
    private var rotatedURL: URL {
        fileURL.appendingPathExtension("1")
    }

    /// Of diagnostiek naar stderr moet: env-variabele `PITCHLAB_SPEECH_DIAG` gezet
    /// (niet leeg, niet `0`/`false`), of `--diagnostics` in de argumenten. Zo geeft de
    /// binary rechtstreeks draaien meteen inzicht, zonder het logbestand te openen.
    public static func diagnosticsEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        if arguments.contains("--diagnostics") { return true }
        guard let value = environment["PITCHLAB_SPEECH_DIAG"]?
            .trimmingCharacters(in: .whitespaces).lowercased()
        else { return false }
        return !value.isEmpty && value != "0" && value != "false"
    }

    public func log(_ event: DiagnosticEvent) {
        let line = format(event)
        lock.lock()
        defer { lock.unlock() }
        if mirrorToStderr {
            FileHandle.standardError.write(Data(line.utf8))
        }
        write(line)
    }

    /// `<ISO8601-tijd> <LEVEL> <regel>\n`. ISO8601 zodat de tijden sorteerbaar en
    /// tijdzone-eenduidig zijn.
    private func format(_ event: DiagnosticEvent) -> String {
        let stamp = ISO8601DateFormatter().string(from: now())
        return "\(stamp) \(event.level.rawValue) \(event.line)\n"
    }

    /// Voegt de regel toe, roteert eerst als het bestand vol zou lopen. Fouten bij het
    /// schrijven mogen de keten niet breken: als het log zelf faalt, is de app niet
    /// stuk — de regel verdwijnt, meer niet.
    private func write(_ line: String) {
        let data = Data(line.utf8)
        rotateIfNeeded(adding: data.count)
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try? fm.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Roteert het bestand als de nieuwe regel het over `maxBytes` zou tillen: de oude
    /// `.1` weg, het huidige bestand naar `.1`, en een vers bestand begint. Zo blijft
    /// de schijf begrensd op ~2×`maxBytes`.
    private func rotateIfNeeded(adding bytes: Int) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int
        else { return }
        guard size + bytes > maxBytes else { return }
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: fileURL, to: rotatedURL)
    }
}
