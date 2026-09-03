import Testing
@testable import PitchlabSpeech

/// Gate voor de index op `recorded_at` (PL-936). Het opruimen filtert op die kolom en
/// draait bij elke keer dat de store opent; zonder index is dat een volledige scan.
/// Bewijst met `EXPLAIN QUERY PLAN` dat het opruim-plan de index gebruikt en niet scant,
/// en dat een bestaande database de index er bij het heropenen bij krijgt.
///
/// Importeert bewust géén Foundation — dat zou samen met `import Testing` de
/// cross-import overlay `_Testing_Foundation` triggeren (zie `Fixtures.swift`). De store
/// levert daarom een plan-beschrijving en een schema-lezer zodat de gate geen `URL` of
/// `FileManager` raakt. De assertie is het plan, geen tijdmeting — een timing op een
/// lege tabel bewijst niets.
@Suite struct TranscriptIndexTests {

    /// Het plan van de opruim-query noemt de index en scant niet.
    @Test func pruneQueryUsesTheIndexNotAFullScan() throws {
        let store = try #require(TranscriptStore.inMemory())
        let plan = store.prunePlanDescription()
        #expect(plan.contains("idx_transcripts_recorded_at"))
        #expect(plan.contains("USING INDEX"))
        #expect(!plan.contains("SCAN"))
    }

    /// Een database van vóór de index — alleen de basis-migratiestap — krijgt de index
    /// er bij het heropenen bij, en het plan gebruikt hem daarna.
    @Test func theIndexExistsEvenOnADatabaseThatAlreadyExisted() throws {
        let path = TranscriptStore.makeTemporaryDatabasePath()
        let baseOnly = Array(TranscriptStore.migrations.prefix(1))
        do {
            let old = try #require(TranscriptStore.open(path: path, migrations: baseOnly))
            old.record(text: "oud", duration: 1, mode: "hands-free")
            #expect(!old.hasSchemaObject("idx_transcripts_recorded_at"))
        }

        let migrated = try #require(TranscriptStore.open(path: path))
        #expect(migrated.hasSchemaObject("idx_transcripts_recorded_at"))

        let plan = migrated.prunePlanDescription()
        #expect(plan.contains("USING INDEX"))
        #expect(!plan.contains("SCAN"))
    }
}
