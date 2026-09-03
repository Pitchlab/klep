import Testing
@testable import Klep

/// Gate voor de transcriptgeschiedenis (PL-757). Bewijst dat elke afgeronde uiting
/// als rij in SQLite landt met tekst, tijdstip, duur en modus; dat de database in
/// Application Support hoort en niet in de bundel; en dat een ontbrekende of corrupte
/// database het dicteren niet blokkeert maar naar de log gaat.
///
/// Importeert bewust géén Foundation — dat zou samen met `import Testing` de
/// cross-import overlay `_Testing_Foundation` triggeren (zie `Fixtures.swift`). De
/// store levert daarom een geheugen-database (`inMemory`), een pad-fabriek en een
/// pad-accessor zodat de gate geen `URL`, `Date` of `FileManager` hoeft aan te raken.
@Suite struct TranscriptStoreTests {

    /// Vangt de log-regels van de store zonder Foundation. De store roept de closure
    /// synchroon aan binnen `open`/`record`, dus één thread — geen slot nodig.
    final class LogSpy: @unchecked Sendable {
        private(set) var messages: [String] = []
        func capture(_ message: String) { messages.append(message) }
    }

    /// Elke uiting landt als rij met tekst, duur en een tijdstip; de modus komt mee.
    /// Twee inserts, nieuwste eerst teruggelezen.
    @Test func recordsEachUtteranceWithTextTimestampDurationAndMode() throws {
        let store = try #require(TranscriptStore.inMemory())
        store.record(text: "goedemorgen", duration: 1.25, mode: "hands-free")
        store.record(text: "tweede zin", duration: 2.5, mode: "hands-free")

        let rows = try store.recentTranscripts()
        #expect(rows.count == 2)

        let newest = rows[0]
        #expect(newest.text == "tweede zin")
        #expect(newest.duration == 2.5)
        #expect(newest.mode == "hands-free")
        #expect(newest.recordedAtEpoch > 0)   // een echt tijdstip, geen nul

        let oldest = rows[1]
        #expect(oldest.text == "goedemorgen")
        #expect(oldest.duration == 1.25)
    }

    /// De database hoort in Application Support, niet in de app-bundel: een herbouw
    /// mag de geschiedenis niet wissen.
    @Test func databaseLivesInApplicationSupportNotInBundle() throws {
        let path = try TranscriptStore.defaultDatabasePath()
        #expect(path.contains("Application Support"))
        #expect(path.contains("Klep/transcripts.sqlite3"))
        #expect(!path.contains(".app/"))
    }

    /// Een ontbrekende of corrupte database blokkeert het dicteren niet: het openen
    /// van een pad in een niet-bestaande map geeft `nil` en logt de fout in plaats van
    /// te gooien.
    @Test func missingDatabaseDoesNotBlockButLogs() {
        let spy = LogSpy()
        let store = TranscriptStore.open(
            path: "/pitchlab-geen-map-\(Self.self)/x/transcripts.sqlite3",
            log: { spy.capture($0) })
        #expect(store == nil)
        #expect(!spy.messages.isEmpty)   // fout ging naar de log, niet naar de gebruiker
    }

    /// `record` gooit nooit — het is fire-and-forget. Na een geslaagde insert werkt de
    /// volgende gewoon, zodat een enkele haperende uiting de keten niet stopt.
    @Test func recordIsFireAndForget() throws {
        let store = try #require(TranscriptStore.inMemory())
        store.record(text: "een", duration: 0.5, mode: "hands-free")
        store.record(text: "twee", duration: 0.5, mode: "hands-free")
        #expect(try store.recentTranscripts().count == 2)
    }
}

/// Aanvullingen na Eriks drie beslissingen van 2026-09-02: opslaan standaard aan,
/// 30 dagen bewaren, nog niet versleutelen.
@Suite struct TranscriptRetentionTests {

    /// De termijn staat op 30 dagen, de waarde die Erik koos.
    @Test func retentionIsThirtyDays() {
        #expect(TranscriptStore.retentionDays == 30)
    }

    /// Opruimen gooit weg wat ouder is dan de termijn en laat de rest staan. De grens
    /// zelf hoort te blijven: precies 30 dagen oud is nog binnen de termijn.
    @Test func pruneDropsOnlyWhatIsOlderThanTheTerm() {
        let kept = TranscriptRetentionTestSupport.pruneAtBoundary()
        #expect(kept.contains("vers"))
        #expect(kept.contains("grens"))
        #expect(!kept.contains("oud"))
    }

    /// De geschiedenis moet zeggen WAAR een transcript heen ging. De cursorroute is de
    /// standaard; `--listen` typt nergens in en heet daarom `stdout`.
    @Test func theHistoryRouteDistinguishesCursorFromStdout() {
        #expect(TextOutputSink().historyRoute == "cursor")
        #expect(StandardOutputLineSink().historyRoute == "stdout")
    }

    /// Opruimen op een lege database is geen fout — dat is de stand bij de allereerste
    /// start, en die mag het openen niet laten struikelen.
    @Test func pruneOnAnEmptyDatabaseIsHarmless() {
        #expect(TranscriptRetentionTestSupport.pruneEmptyLeavesNothing())
    }
}
