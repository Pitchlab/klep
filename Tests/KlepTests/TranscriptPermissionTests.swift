import Testing
@testable import Klep

/// Gate voor de rechten op de geschiedenis (PL-935). De map en het databasebestand
/// dragen de gedicteerde tekst als platte tekst; alleen de eigenaar mag erbij. Bewijst
/// dat de map op 0700 staat (ook als hij al met ruimere rechten bestond) en het bestand
/// op 0600.
///
/// Importeert bewust géén Foundation — dat zou samen met `import Testing` de
/// cross-import overlay `_Testing_Foundation` triggeren (zie `Fixtures.swift`). De
/// store levert daarom een tijdelijke-map-fabriek en een rechten-lezer zodat de gate
/// geen `FileManager` hoeft aan te raken.
@Suite struct TranscriptPermissionTests {

    /// Het aanmaakpad: de map bestaat nog niet, het openen maakt hem met 0700.
    @Test func aFreshDirectoryIsOwnerOnly() throws {
        let dbPath = TranscriptStore.makeTemporaryDatabasePath()
        let store = try #require(TranscriptStore.open(path: dbPath))
        _ = store
        let directory = String(dbPath.dropLast("/transcripts.sqlite3".count))
        #expect(TranscriptStore.posixPermissions(atPath: directory) == 0o700)
    }

    /// Een map die al bestond met ruime rechten (0755), zoals sinds 2026-09-03 op schijf:
    /// het openen zet hem alsnog dicht op 0700. Alleen het aanmaakpad repareren zou hier
    /// niets doen.
    @Test func directoryIsOwnerOnlyEvenWhenItAlreadyExistedWithLoosePermissions() throws {
        let directory = try TranscriptStore.makeTemporaryDirectory(permissions: 0o755)
        #expect(TranscriptStore.posixPermissions(atPath: directory) == 0o755)   // vooraf ruim

        let dbPath = directory + "/transcripts.sqlite3"
        let store = try #require(TranscriptStore.open(path: dbPath))
        _ = store
        #expect(TranscriptStore.posixPermissions(atPath: directory) == 0o700)
    }

    /// Het databasebestand zelf staat op 0600.
    @Test func databaseFileIsOwnerOnly() throws {
        let dbPath = TranscriptStore.makeTemporaryDatabasePath()
        let store = try #require(TranscriptStore.open(path: dbPath))
        _ = store
        #expect(TranscriptStore.posixPermissions(atPath: dbPath) == 0o600)
    }
}
