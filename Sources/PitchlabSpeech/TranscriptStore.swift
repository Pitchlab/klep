/// TranscriptStore: bewaart elke afgeronde uiting in SQLite zodat de geschiedenis
/// terug te zoeken is en de transcriptiekwaliteit te meten. Tot deze taak verdween
/// wat gedicteerd was zodra het was ingevoegd; nu landt elke uiting als rij met de
/// tekst, het tijdstip, de duur en de actieve modus.
///
/// Twee regels bepalen de vorm:
///  - De database staat in Application Support (`~/Library/Application Support/
///    PitchlabSpeech/transcripts.sqlite3`), niet in de bundel. Een herbouw van de
///    app raakt Application Support niet, dus de geschiedenis overleeft het.
///  - Het dicteren is de hoofdtaak. Een ontbrekende of corrupte database mag het
///    invoegen nooit blokkeren: `open(...)` vangt de fout, logt hem en geeft `nil`
///    terug, en `record(...)` gooit nooit — falen gaat naar de log, niet naar de
///    gebruiker. De aanroeper met een `nil`-store dicteert gewoon door zonder
///    geschiedenis.
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
        Logger(subsystem: "nl.pitchlab.speech", category: "TranscriptStore").error("\(message, privacy: .public)")
    }

    /// De vaste locatie in Application Support. Maakt de map aan als hij nog niet
    /// bestaat. Bewust buiten de app-bundel, zodat een herbouw de geschiedenis niet
    /// wist.
    public static func defaultDatabaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("PitchlabSpeech", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcripts.sqlite3", isDirectory: false)
    }

    /// Het standaardpad als string, zonder mappen aan te maken. Zo kan de gate
    /// nagaan dat de database in Application Support en niet in de bundel landt.
    public static func defaultDatabasePath() throws -> String {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        return support
            .appendingPathComponent("PitchlabSpeech", isDirectory: true)
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
    init(sqlitePath: String, log: @escaping @Sendable (String) -> Void = TranscriptStore.defaultLog) throws {
        self.log = log
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(sqlitePath, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "kon database niet openen"
            sqlite3_close(handle)
            throw StoreError.open(message)
        }
        self.db = handle
        do {
            try exec("""
                CREATE TABLE IF NOT EXISTS transcripts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    text TEXT NOT NULL,
                    recorded_at REAL NOT NULL,
                    duration REAL NOT NULL,
                    mode TEXT NOT NULL
                );
                """)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    /// Niet-gooiende fabriek voor het dicteerpad. Faalt het openen of het schema —
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
        do {
            return try TranscriptStore(sqlitePath: path, log: log)
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
        let sql = "DELETE FROM transcripts WHERE recorded_at < ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
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
        var rows: [TranscriptRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let text = String(cString: sqlite3_column_text(statement, 1))
            let recordedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let duration = sqlite3_column_double(statement, 3)
            let mode = String(cString: sqlite3_column_text(statement, 4))
            rows.append(TranscriptRecord(
                id: id, text: text, recordedAt: recordedAt, duration: duration, mode: mode))
        }
        return rows
    }

    private func exec(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "onbekende fout"
            sqlite3_free(errorPointer)
            throw StoreError.schema(message)
        }
    }

    public enum StoreError: Error, Equatable {
        case open(String)
        case schema(String)
        case query(String)
    }
}
