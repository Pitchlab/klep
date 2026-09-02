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
/// zwerft. `DiagnosticLog` schrijft naar `~/.pitchlab/klep/klep.log.jsonl`, naast de config
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
    /// De tijd tussen "hands-free aan" en de eerste binnengekomen sample (PL-765).
    /// Meet wat je aan het begin van je eerste woord kwijt bent doordat de
    /// `AVCaptureSession` nog opgezet moest worden.
    case captureReady(elapsedMs: Int)
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
        case .captureReady(let elapsedMs):
            return "eerste sample \(elapsedMs) ms na hands-free aan"
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

    /// De stabiele machine-naam van de gebeurtenis, het `event`-veld in het JSONL-record.
    /// Dit is het contract waarop een lezer leunt; `line` is dat niet en mag veranderen.
    public var name: String {
        switch self {
        case .handsFreeOn: return "hands_free_on"
        case .handsFreeOff: return "hands_free_off"
        case .handsFreeRestored: return "hands_free_restored"
        case .deviceSelected: return "device_selected"
        case .permission: return "permission"
        case .captureReady: return "capture_ready"
        case .utteranceDetected: return "utterance_detected"
        case .transcribed: return "transcribed"
        case .output: return "output"
        case .failure: return "failure"
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

/// Schrijft diagnostiek naar een afgekapt logbestand als JSONL — één machine-leesbaar
/// record per regel — en, als diagnostiek aan staat, de menselijke zin naar stderr. Het
/// bestand is het gegevensformaat (`jq -s .` maakt er een array van); stderr blijft de
/// leesbare `--diagnostics`-spiegel. JSONL boven een JSON-array: een afgebroken schrijf
/// of een rotatie laat het bestand regel-voor-regel leesbaar, geen sluithaak om te
/// verplaatsen. Eén generatie rotatie: zodra het bestand `maxBytes` zou overschrijden,
/// gaat het naar `<naam>.1` en begint een vers bestand, zodat het nooit onbegrensd
/// groeit. `@unchecked Sendable`: de schrijf zit achter een `NSLock` zodat de
/// actor-keten en de MainActor er beide veilig in mogen schrijven.
public final class DiagnosticLog: DiagnosticSink, @unchecked Sendable {
    private let fileURL: URL
    private let maxBytes: Int
    private let mirrorToStderr: Bool
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    /// - Parameters:
    ///   - fileURL: het logbestand. Standaard `~/.pitchlab/klep/klep.log.jsonl`.
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

    /// Het standaard-logpad naast de config van PL-696: `~/.pitchlab/klep/klep.log.jsonl`.
    /// De extensie zegt wat erin staat: elke regel is één JSON-record. Het eerdere
    /// `klep.log` droeg platte tekst; dezelfde naam aanhouden zou een bestaand bestand
    /// half tekst en half JSON maken, en daar struikelt elke lezer over.
    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pitchlab/klep/klep.log.jsonl")
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
        let stamp = ISO8601DateFormatter().string(from: now())
        lock.lock()
        defer { lock.unlock() }
        if mirrorToStderr {
            FileHandle.standardError.write(Data("\(stamp) \(event.level.rawValue) \(event.line)\n".utf8))
        }
        write(record(event, stamp: stamp))
    }

    /// Eén JSONL-record: `ts` (ISO8601, sorteerbaar en tijdzone-eenduidig), `level`, de
    /// stabiele `event`-naam, de getypeerde velden per gebeurtenis, en `msg` met de zin
    /// voor wie het bestand direct leest. Faalt de encode (nooit, bij deze waarden), dan
    /// blijft de regel toch JSON zodat het bestand JSONL blijft.
    private func record(_ event: DiagnosticEvent, stamp: String) -> String {
        let row = DiagnosticRecord(
            ts: stamp, level: event.level.rawValue, event: event, msg: event.line)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(row),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{\"event\":\"\(event.name)\",\"level\":\"\(event.level.rawValue)\",\"ts\":\"\(stamp)\"}\n"
        }
        return json + "\n"
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

// MARK: - JSONL-record

/// De machine-leesbare vorm van één gebeurtenis. Encodeert `ts`/`level`/`event`/`msg`
/// plus de velden die bij deze gebeurtenis horen, elk als het juiste type: getallen als
/// getal (`duration_ms`, `elapsed_ms`, `characters`), `succeeded`/`on` als boolean, de
/// rest als string. Zo hoeft een lezer geen zin te parsen om een getal te krijgen.
private struct DiagnosticRecord: Encodable {
    let ts: String
    let level: String
    let event: DiagnosticEvent
    let msg: String

    private enum Key: String, CodingKey {
        case ts, level, event, msg
        case reason, on, device, kind, status
        case durationMs = "duration_ms"
        case characters
        case elapsedMs = "elapsed_ms"
        case route, succeeded, origin, message
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(ts, forKey: .ts)
        try c.encode(level, forKey: .level)
        try c.encode(event.name, forKey: .event)
        switch event {
        case .handsFreeOn(let reason), .handsFreeOff(let reason):
            try c.encode(reason, forKey: .reason)
        case .handsFreeRestored(let on):
            try c.encode(on, forKey: .on)
        case .deviceSelected(let name):
            if let name { try c.encode(name, forKey: .device) } else { try c.encodeNil(forKey: .device) }
        case .permission(let kind, let status):
            try c.encode(kind, forKey: .kind)
            try c.encode(status, forKey: .status)
        case .captureReady(let elapsedMs):
            try c.encode(elapsedMs, forKey: .elapsedMs)
        case .utteranceDetected(let durationMs):
            try c.encode(durationMs, forKey: .durationMs)
        case .transcribed(let characters, let elapsedMs):
            try c.encode(characters, forKey: .characters)
            try c.encode(elapsedMs, forKey: .elapsedMs)
        case .output(let route, let succeeded):
            try c.encode(route, forKey: .route)
            try c.encode(succeeded, forKey: .succeeded)
        case .failure(let origin, let message):
            try c.encode(origin, forKey: .origin)
            try c.encode(message, forKey: .message)
        }
        try c.encode(msg, forKey: .msg)
    }
}
