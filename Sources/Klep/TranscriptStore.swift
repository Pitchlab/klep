/// TranscriptStore: bewaart elke afgeronde uiting in SQLite zodat de geschiedenis
/// terug te zoeken is en de transcriptiekwaliteit te meten. Tot deze taak verdween
/// wat gedicteerd was zodra het was ingevoegd; nu landt elke uiting als rij met de
/// tekst, het tijdstip, de duur en de actieve modus.
///
/// Twee regels bepalen de vorm:
///  - De database staat in Application Support (`~/Library/Application Support/
///    Klep/transcripts.sqlite3`), niet in de bundel. Een herbouw van de
///    app raakt Application Support niet, dus de geschiedenis overleeft het.
///  - Het dicteren is de hoofdtaak. Een ontbrekende of corrupte database mag het
///    invoegen nooit blokkeren: `open(...)` vangt de fout, logt hem en geeft `nil`
///    terug, en `record(...)` gooit nooit — falen gaat naar de log, niet naar de
///    gebruiker. De aanroeper met een `nil`-store dicteert gewoon door zonder
///    geschiedenis.
///
/// Het schema draagt een versienummer (`PRAGMA user_version`) en een migratiepad dat
/// een bestaande database bij het openen naar de laatste versie stapt. Elke stap
/// draait apart, in een transactie, en verhoogt de versie pas na succes — een stap
/// die faalt laat geen half schema achter en blokkeert het dicteren niet.
///
/// De store praat tegen een injecteerbare log-closure; productie schrijft naar een
/// `os.Logger`, de tests naar een spy, zodat de gate kan bewijzen dat een fout
/// gelogd en niet gegooid wordt. SQLite via de systeemmodule `SQLite3` — geen extra
/// dependency, geen linker-vlag: de macOS-SDK levert de modulemap die libsqlite3
/// meelinkt.
import Foundation
import SQLite3
import os

// SQLite bindt tekst met een destructor die vertelt of het de bytes mag hergebruiken
// of moet kopiëren. `SQLITE_TRANSIENT` laat SQLite meteen een eigen kopie maken, zodat
// de Swift-`String` na de call vrij mag verdwijnen. De constante zit niet in de
// geïmporteerde header, dus hier met de hand gereconstrueerd (waarde -1).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Eén migratiestap: de SQL die de database naar `version` brengt, plus dat versienummer.
/// De stappen draaien op volgorde en alleen als hun versie boven de huidige ligt, dus
/// een stap wordt nooit twee keer uitgevoerd. `sql` is idempotent (`IF NOT EXISTS`) zodat
/// een tweede migratie een kolom of index kan toevoegen zonder de eerste te raken.
struct Migration {
    let version: Int32
    let sql: String
}

/// Eén bewaarde uiting zoals hij uit de database komt. `recordedAt` is het moment
/// waarop de uiting afgerond was, `duration` de lengte van de opname in seconden,
/// `mode` de actieve dicteermodus toen hij werd opgenomen.
public struct TranscriptRecord: Sendable, Equatable {
    public let id: Int64
    public let text: String
    public let recordedAt: Date
    public let duration: TimeInterval
    public let mode: String

    public init(id: Int64, text: String, recordedAt: Date, duration: TimeInterval, mode: String) {
        self.id = id
        self.text = text
        self.recordedAt = recordedAt
        self.duration = duration
        self.mode = mode
    }

    /// Het tijdstip als seconden sinds 1970. Zo kan een aanroeper (of de gate) het
    /// bewaarde tijdstip lezen zonder een `Date` te hoeven vormen.
    public var recordedAtEpoch: TimeInterval { recordedAt.timeIntervalSince1970 }
}

/// `@unchecked Sendable` op grond van `SQLITE_OPEN_FULLMUTEX` hieronder: SQLite
/// serialiseert die verbinding zelf, dus meerdere threads mogen hem tegelijk gebruiken.
/// De hands-free-keten draait in een actor en schrijft hiernaartoe; zonder deze
/// conformance kan de store die grens niet over.
public final class TranscriptStore: @unchecked Sendable {
    private let db: OpaquePointer
    private let log: @Sendable (String) -> Void

    /// Standaard log-doel: één subsysteem-kanaal in de unified log. Draagt nooit de
    /// getranscribeerde tekst — alleen de foutboodschap — in lijn met de logregel
    /// "geen inhoud" van de diagnostiek.
    public static let defaultLog: @Sendable (String) -> Void = { message in
        Logger(subsystem: "nl.pitchlab.klep", category: "TranscriptStore").error("\(message, privacy: .public)")
    }

    /// Het migratiepad. Stap 1 legt de basistabel aan; stap 2 de index op `recorded_at`
    /// zodat het opruimen geen volledige scan is. Een bestaande database (versie 0) loopt
    /// bij het openen elke stap af tot `schemaVersion`; een nieuwe database ook.
    static let migrations: [Migration] = [
        Migration(version: 1, sql: """
            CREATE TABLE IF NOT EXISTS transcripts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                text TEXT NOT NULL,
                recorded_at REAL NOT NULL,
                duration REAL NOT NULL,
                mode TEXT NOT NULL
            );
            """),
        Migration(version: 2, sql: """
            CREATE INDEX IF NOT EXISTS idx_transcripts_recorded_at
                ON transcripts(recorded_at);
            """),
    ]

    /// De laatste schemaversie: waar het migratiepad naartoe stapt.
    static var schemaVersion: Int32 { migrations.last?.version ?? 0 }

    /// De opruim-query op één plek, zodat het draaiende opruimen (`prune`) en het
    /// query-plan (`prunePlanDescription`) gegarandeerd dezelfde query zijn.
    private static let pruneSQL = "DELETE FROM transcripts WHERE recorded_at < ?;"

    /// De vaste locatie in Application Support. Bewust buiten de app-bundel, zodat een
    /// herbouw de geschiedenis niet wist. De map wordt met de juiste rechten (0700)
    /// aangemaakt in `init`; hier alleen het pad.
    public static func defaultDatabaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return support
            .appendingPathComponent("Klep", isDirectory: true)
            .appendingPathComponent("transcripts.sqlite3", isDirectory: false)
    }

    /// Het standaardpad als string, zonder mappen aan te maken. Zo kan de gate
    /// nagaan dat de database in Application Support en niet in de bundel landt.
    public static func defaultDatabasePath() throws -> String {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        return support
            .appendingPathComponent("Klep", isDirectory: true)
            .appendingPathComponent("transcripts.sqlite3", isDirectory: false)
            .path
    }

    /// Opent (of maakt) de database op `url` en legt het schema vast. Gooit bij een
    /// echte fout — gebruik `open(...)` op de dicteerpad, dat de fout opvangt.
    public convenience init(
        url: URL, log: @escaping @Sendable (String) -> Void = TranscriptStore.defaultLog
    ) throws {
        try self.init(sqlitePath: url.path, log: log)
    }

    /// Kern-initializer op een kaal SQLite-pad. `":memory:"` opent een database in
    /// het geheugen (geen bestand, geen opruimen) — de vorm die de gate gebruikt.
    /// `migrations` is injecteerbaar zodat de gate het migratiepad kan uitproberen;
    /// productie neemt het standaardpad.
    init(
        sqlitePath: String,
        migrations: [Migration] = TranscriptStore.migrations,
        log: @escaping @Sendable (String) -> Void = TranscriptStore.defaultLog
    ) throws {
        self.log = log
        // Een echt bestand krijgt een afgeschermde map (0700) en een afgeschermd bestand
        // (0600): de geschiedenis staat als platte tekst op schijf, alleen de eigenaar
        // mag erbij (PL-935). Een geheugen-database heeft geen bestand, dus dan niet.
        if sqlitePath != ":memory:" {
            try TranscriptStore.secureContainingDirectory(ofFile: sqlitePath)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(sqlitePath, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "kon database niet openen"
            sqlite3_close(handle)
            throw StoreError.open(message)
        }
        self.db = handle
        do {
            if sqlitePath != ":memory:" {
                try TranscriptStore.restrictFilePermissions(atPath: sqlitePath)
            }
            try runMigrations(migrations)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    /// Stapt de database naar de laatste schemaversie. Leest `PRAGMA user_version`,
    /// draait elke stap met een hogere versie apart in een transactie en verhoogt de
    /// versie pas na `COMMIT`. Faalt een stap, dan `ROLLBACK` — geen half schema — en
    /// de fout gaat omhoog; op het dicteerpad vangt `open(...)` hem op.
    private func runMigrations(_ migrations: [Migration]) throws {
        var current = userVersion()
        for step in migrations where step.version > current {
            try exec("BEGIN;")
            do {
                try exec(step.sql)
                try exec("PRAGMA user_version = \(step.version);")
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
            current = step.version
        }
    }

    /// De huidige schemaversie uit `PRAGMA user_version`. `-1` als het lezen mislukt.
    func userVersion() -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int(statement, 0)
    }

    /// Of een tabel of index met die naam in het schema staat. Voor de gate, om te
    /// bewijzen dat de index bestaat en dat een gefaalde migratie geen tabel achterliet.
    func hasSchemaObject(_ name: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db, "SELECT 1 FROM sqlite_master WHERE name = ? LIMIT 1;", -1, &statement, nil) == SQLITE_OK
        else { return false }
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Of `column` in `table` bestaat. Voor de gate, om te bewijzen dat een tweede
    /// migratiestap een kolom toevoegt. `table` is intern/gate, dus veilig te interpoleren.
    func hasColumn(_ column: String, inTable table: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK
        else { return false }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column { return true }
        }
        return false
    }

    /// Het query-plan van de opruim-query als tekst. `EXPLAIN QUERY PLAN` beschrijft
    /// zonder te draaien welke tabellen en indexen SQLite raakt; de gate leest hieruit
    /// dat de opruiming de index gebruikt (`USING INDEX`) en geen volledige scan (`SCAN`).
    func prunePlanDescription() -> String {
        let sql = "EXPLAIN QUERY PLAN " + TranscriptStore.pruneSQL
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return "query-plan mislukt (prepare): \(String(cString: sqlite3_errmsg(db)))"
        }
        var lines: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let detail = sqlite3_column_text(statement, 3) { lines.append(String(cString: detail)) }
        }
        return lines.joined(separator: "\n")
    }

    /// Niet-gooiende fabriek voor het dicteerpad. Faalt het openen of de migratie —
    /// een ontbrekende map, een corrupt bestand — dan gaat de fout naar de log en
    /// komt er `nil` terug; de aanroeper dicteert door zonder geschiedenis.
    /// `url` weglaten pakt de standaardlocatie in Application Support.
    public static func open(
        url: URL? = nil, log: @escaping @Sendable (String) -> Void = TranscriptStore.defaultLog
    ) -> TranscriptStore? {
        do {
            let target = try url ?? defaultDatabaseURL()
            let store = try TranscriptStore(url: target, log: log)
            // Opruimen bij het openen: één keer per sessie, buiten het dicteerpad om.
            store.prune()
            return store
        } catch {
            log("transcriptdatabase openen mislukt: \(error)")
            return nil
        }
    }

    /// Niet-gooiende fabriek op een kaal pad. Wijst het pad naar een niet-bestaande
    /// map of een corrupt bestand, dan gaat de fout naar de log en komt er `nil`
    /// terug — het dicteren loopt door zonder geschiedenis.
    public static func open(
        path: String, log: @escaping @Sendable (String) -> Void = TranscriptStore.defaultLog
    ) -> TranscriptStore? {
        open(path: path, migrations: migrations, log: log)
    }

    /// Als `open(path:)`, maar met een injecteerbaar migratiepad zodat de gate het
    /// migreren van een bestaande database kan uitproberen (een oudere versie openen,
    /// rijen schrijven, met het volledige pad heropenen).
    static func open(
        path: String,
        migrations: [Migration],
        log: @escaping @Sendable (String) -> Void = TranscriptStore.defaultLog
    ) -> TranscriptStore? {
        do {
            return try TranscriptStore(sqlitePath: path, migrations: migrations, log: log)
        } catch {
            log("transcriptdatabase openen mislukt: \(error)")
            return nil
        }
    }

    /// Een database in het geheugen: geen bestand, geen opruimen. De vorm die de gate
    /// gebruikt om het bewaren en teruglezen te bewijzen zonder Application Support te
    /// raken.
    public static func inMemory(
        log: @escaping @Sendable (String) -> Void = TranscriptStore.defaultLog
    ) -> TranscriptStore? {
        open(path: ":memory:", log: log)
    }

    /// Hoelang een uiting bewaard blijft. BESLIST door Erik op 2026-09-02: 30 dagen,
    /// opslaan standaard aan, nog niet versleutelen — de rechten op de homedir volstaan
    /// voorlopig. Alles wat je zegt komt op schijf, dus dit is de rem daarop.
    public static let retentionDays = 30

    /// Gooit alles weg dat ouder is dan `days` dagen. Draait bij het openen, dus één
    /// keer per sessie en niet op het dicteerpad. Gooit nooit: lukt het opruimen niet,
    /// dan gaat dat naar de log en werkt de rest gewoon.
    public func prune(olderThan days: Int = TranscriptStore.retentionDays, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60).timeIntervalSince1970
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, TranscriptStore.pruneSQL, -1, &statement, nil) == SQLITE_OK else {
            log("opruimen mislukt (prepare): \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        sqlite3_bind_double(statement, 1, cutoff)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            log("opruimen mislukt (step): \(String(cString: sqlite3_errmsg(db)))")
            return
        }
    }

    /// Bewaart één afgeronde uiting. Gooit nooit: mislukt de insert, dan gaat de
    /// fout naar de log en dicteert de aanroeper onverstoord door. De tekst gaat wél
    /// de database in (dat is het doel), maar nooit de log.
    public func record(text: String, duration: TimeInterval, mode: String, at recordedAt: Date = Date()) {
        let sql = "INSERT INTO transcripts (text, recorded_at, duration, mode) VALUES (?, ?, ?, ?);"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            log("uiting bewaren mislukt (prepare): \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        sqlite3_bind_text(statement, 1, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, recordedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, duration)
        sqlite3_bind_text(statement, 4, mode, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            log("uiting bewaren mislukt (step): \(String(cString: sqlite3_errmsg(db)))")
            return
        }
    }

    /// Zoekt op woord in de tekst, nieuwste eerst. Doorzoeken is de reden dat we
    /// opslaan; een lege zoekterm geeft de recente lijst terug.
    ///
    /// `LIKE` en geen FTS5: bij een bewaartermijn van 30 dagen blijft de tabel klein
    /// genoeg dat een scan onmerkbaar is, en FTS5 kost een tweede tabel die synchroon
    /// moet blijven. Loopt de termijn ooit op, dan is dit de plek om FTS5 te zetten.
    public func search(_ term: String, limit: Int = 100) throws -> [TranscriptRecord] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try recentTranscripts(limit: limit) }

        let sql = """
            SELECT id, text, recorded_at, duration, mode FROM transcripts
            WHERE text LIKE ? ESCAPE '\\' ORDER BY recorded_at DESC LIMIT ?;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.query(String(cString: sqlite3_errmsg(db)))
        }
        // De jokertekens van LIKE ontsnappen, anders is een getypte % een zoek-alles.
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        sqlite3_bind_text(statement, 1, "%\(escaped)%", -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 2, Int32(limit))
        return try rows(from: statement)
    }

    /// Gooit de hele geschiedenis weg. De gebruiker moet dit kunnen: alles wat je zegt
    /// staat op schijf, dus er hoort een knop te zijn die het leegmaakt.
    public func deleteAll() throws {
        try exec("DELETE FROM transcripts;")
    }

    /// De laatst bewaarde uitingen, nieuwste eerst. Voor het terugzoeken van de
    /// geschiedenis en voor de gate. Gooit bij een leesfout — anders dan het
    /// dicteerpad is dit geen hete route.
    public func recentTranscripts(limit: Int = 100) throws -> [TranscriptRecord] {
        let sql = "SELECT id, text, recorded_at, duration, mode FROM transcripts ORDER BY id DESC LIMIT ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.query(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int(statement, 1, Int32(limit))
        return try rows(from: statement)
    }

    /// Leest de rijen uit een voorbereide query. Eén decoder voor de recente lijst en
    /// voor het zoeken, zodat de kolomvolgorde op één plek staat.
    private func rows(from statement: OpaquePointer?) throws -> [TranscriptRecord] {
        var result: [TranscriptRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let text = String(cString: sqlite3_column_text(statement, 1))
            let recordedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let duration = sqlite3_column_double(statement, 3)
            let mode = String(cString: sqlite3_column_text(statement, 4))
            result.append(TranscriptRecord(
                id: id, text: text, recordedAt: recordedAt, duration: duration, mode: mode))
        }
        return result
    }

    private func exec(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "onbekende fout"
            sqlite3_free(errorPointer)
            throw StoreError.schema(message)
        }
    }

    // MARK: - Rechten (PL-935)

    /// Zorgt dat de map waarin het databasebestand komt bestaat en alleen voor de
    /// eigenaar leesbaar is (0700). Zet de rechten ook op een map die al bestond — hij
    /// kan met een ruimere umask (0755) zijn aangemaakt, en dan repareert alleen het
    /// aanmaakpad niets. Alleen de map zelf, niet de bovenliggende mappen.
    private static func secureContainingDirectory(ofFile path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        guard !dir.isEmpty else { return }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if !fm.fileExists(atPath: dir, isDirectory: &isDirectory) {
            try fm.createDirectory(
                atPath: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
    }

    /// Zet het databasebestand op 0600: alleen de eigenaar leest en schrijft.
    private static func restrictFilePermissions(atPath path: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    // MARK: - Gate-hulp (Foundation buiten de testbestanden)

    /// Een uniek, nog niet aangemaakt pad naar een databasebestand in een tijdelijke
    /// map. De map maakt `init` aan (met 0700). Voor de gate, die het migreren over
    /// open/dicht heen bewijst zonder zelf Foundation te hoeven aanraken.
    static func makeTemporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("klep-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("transcripts.sqlite3", isDirectory: false)
            .path
    }

    /// Maakt een tijdelijke map met opgegeven rechten en geeft het pad terug. Voor de
    /// gate, om het "map bestond al met ruime rechten"-geval te zetten (0755) en te
    /// bewijzen dat het openen hem alsnog dichtzet.
    static func makeTemporaryDirectory(permissions: Int) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("klep-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            atPath: dir.path, withIntermediateDirectories: true,
            attributes: [.posixPermissions: permissions])
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: dir.path)
        return dir.path
    }

    /// De POSIX-rechten van een pad als geheel getal, of `nil` als het pad niet bestaat
    /// of geen rechten draagt. Voor de gate, om 0700 op de map en 0600 op het bestand
    /// te controleren.
    static func posixPermissions(atPath path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let permissions = attributes[.posixPermissions] as? NSNumber else { return nil }
        return permissions.intValue
    }

    public enum StoreError: Error, Equatable {
        case open(String)
        case schema(String)
        case query(String)
    }
}
