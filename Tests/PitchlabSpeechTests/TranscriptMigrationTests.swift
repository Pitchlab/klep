import Testing
@testable import PitchlabSpeech

/// Gate voor het versienummer en het migratiepad van de transcriptopslag (PL-934).
/// Bewijst dat een bestaande database bij het openen naar de laatste schemaversie
/// stapt zonder dataverlies; dat een tweede migratiestap een kolom toevoegt zonder de
/// eerste te raken; en dat een stap die faalt geen half schema achterlaat en het
/// dicteren niet blokkeert.
///
/// Importeert bewust géén Foundation — dat zou samen met `import Testing` de
/// cross-import overlay `_Testing_Foundation` triggeren (zie `Fixtures.swift`). De
/// store levert daarom een pad-fabriek (`makeTemporaryDatabasePath`), een injecteerbaar
/// migratiepad en versie-lezers zodat de gate geen `URL`, `Date` of `FileManager` raakt.
@Suite struct TranscriptMigrationTests {

    /// Vangt de log-regels van de store zonder Foundation. De store roept de closure
    /// synchroon aan binnen `open`, dus één thread — geen slot nodig.
    final class LogSpy: @unchecked Sendable {
        private(set) var messages: [String] = []
        func capture(_ message: String) { messages.append(message) }
    }

    /// Een nieuwe database komt op de laatste versie, en heropenen draait niets opnieuw —
    /// geen fout, dezelfde versie.
    @Test func aFreshDatabaseReachesTheLatestVersionAndReopeningRunsNothing() throws {
        let path = TranscriptStore.makeTemporaryDatabasePath()
        do {
            let fresh = try #require(TranscriptStore.open(path: path))
            #expect(fresh.userVersion() == TranscriptStore.schemaVersion)
        }
        let again = try #require(TranscriptStore.open(path: path))
        #expect(again.userVersion() == TranscriptStore.schemaVersion)
    }

    /// Een database "van vorige week" — alleen de eerste migratiestap, geen index — wordt
    /// bij het heropenen met het volledige pad naar de laatste versie gebracht en de
    /// eerder bewaarde rijen blijven staan.
    @Test func existingDatabaseWithRowsIsMigratedOnOpenWithoutDataLoss() throws {
        let path = TranscriptStore.makeTemporaryDatabasePath()
        let baseOnly = Array(TranscriptStore.migrations.prefix(1))
        do {
            let old = try #require(TranscriptStore.open(path: path, migrations: baseOnly))
            old.record(text: "eerste", duration: 1, mode: "hands-free")
            old.record(text: "tweede", duration: 2, mode: "hands-free")
            #expect(old.userVersion() == 1)
            #expect(!old.hasSchemaObject("idx_transcripts_recorded_at"))
        }

        let migrated = try #require(TranscriptStore.open(path: path))
        #expect(migrated.userVersion() == TranscriptStore.schemaVersion)
        #expect(migrated.hasSchemaObject("idx_transcripts_recorded_at"))

        let texts = try migrated.recentTranscripts().map(\.text)
        #expect(texts.count == 2)
        #expect(texts.contains("eerste"))
        #expect(texts.contains("tweede"))
    }

    /// Een tweede migratiestap voegt een kolom toe zonder de eerste te raken: de rij van
    /// vóór de stap blijft staan, de kolom is er, en nog eens heropenen draait de stap
    /// niet opnieuw (geen dubbele kolom).
    @Test func aSecondMigrationStepAddsAColumnWithoutTouchingTheFirst() throws {
        let path = TranscriptStore.makeTemporaryDatabasePath()
        let base = TranscriptStore.migrations[0]
        let addColumn = Migration(version: 99, sql: "ALTER TABLE transcripts ADD COLUMN note TEXT;")

        do {
            let first = try #require(TranscriptStore.open(path: path, migrations: [base]))
            first.record(text: "voor de kolom", duration: 1, mode: "hands-free")
            #expect(!first.hasColumn("note", inTable: "transcripts"))
        }
        do {
            let second = try #require(TranscriptStore.open(path: path, migrations: [base, addColumn]))
            #expect(second.hasColumn("note", inTable: "transcripts"))
            #expect(try second.recentTranscripts().count == 1)   // de eerste stap onaangeroerd
            #expect(second.userVersion() == 99)
        }

        let third = try #require(TranscriptStore.open(path: path, migrations: [base, addColumn]))
        #expect(third.hasColumn("note", inTable: "transcripts"))
        #expect(try third.recentTranscripts().count == 1)
    }

    /// Een stap die halverwege faalt laat geen half schema achter: de transactie draait
    /// terug, de versie blijft op de laatst geslaagde stap, en het openen geeft `nil`
    /// met een logregel in plaats van een crash — het dicteren loopt door.
    @Test func aFailingMigrationLeavesNoHalfSchemaAndDoesNotBlockDictation() throws {
        let path = TranscriptStore.makeTemporaryDatabasePath()
        let base = TranscriptStore.migrations[0]
        let broken = Migration(
            version: 2, sql: "CREATE TABLE half_schema (x INTEGER); dit is geen geldige sql;")
        let spy = LogSpy()

        let store = TranscriptStore.open(
            path: path, migrations: [base, broken], log: { spy.capture($0) })
        #expect(store == nil)                 // openen geeft nil, geen crash
        #expect(!spy.messages.isEmpty)        // de fout ging naar de log

        // Heropenen met alleen de eerste stap: geldig, en van de gefaalde stap staat niets.
        let recovered = try #require(TranscriptStore.open(path: path, migrations: [base]))
        #expect(recovered.userVersion() == 1)
        #expect(!recovered.hasSchemaObject("half_schema"))
    }
}
