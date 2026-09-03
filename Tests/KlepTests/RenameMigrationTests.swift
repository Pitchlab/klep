import Testing
@testable import Klep

/// Tests voor wat de hernoeming naar Klep achterliet op de machine (PL-731).
///
/// De hernoeming zelf is een zoek-vervang die de gate afvangt. Deze twee dingen niet:
/// een LaunchAgent onder de oude naam blijft stilletjes staan, en de bewaarde
/// transcripten staan in een map die de nieuwe naam niet kent. Allebei onzichtbaar in
/// een groene testsuite en pas merkbaar op de machine van de gebruiker.
@Suite struct RenameMigrationTests {

    // MARK: De oude LaunchAgent

    /// Staat er een plist onder het oude label, dan gaat hij weg en neemt de nieuwe de
    /// auto-start-stand over. Anders verliest iemand die auto-start had zijn instelling.
    @Test func legacyAgentIsRemovedAndAutoStartCarriesOver() {
        let result = RenameMigrationTestSupport.cleanupLegacyAgent(legacyEnabled: true)
        #expect(result.removed)
        #expect(result.legacyGone)
        #expect(result.newEnabled)
    }

    /// De plist weggooien is niet genoeg: launchd houdt een geladen job de hele sessie
    /// geregistreerd, en dat gaf een tweede microfoon in de menubalk. De job moet ook
    /// afgemeld worden, onder het OUDE label.
    @Test func theLegacyJobIsAlsoUnloadedFromLaunchd() {
        let result = RenameMigrationTestSupport.cleanupLegacyAgent(legacyEnabled: true)
        #expect(result.unloaded == [LaunchAgentManager.legacyLabel])
    }

    /// Zonder oude plist wordt er ook niets afgemeld — geen blinde launchctl-aanroep op
    /// een label dat niet van ons is.
    @Test func nothingIsUnloadedWhenThereIsNoLegacyAgent() {
        #expect(RenameMigrationTestSupport.cleanupLegacyAgent(legacyEnabled: false).unloaded.isEmpty)
    }

    /// Zonder oude plist gebeurt er niets, en zeker wordt auto-start niet aangezet voor
    /// iemand die het nooit aan had staan.
    @Test func withoutALegacyAgentNothingHappens() {
        let result = RenameMigrationTestSupport.cleanupLegacyAgent(legacyEnabled: false)
        #expect(!result.removed)
        #expect(!result.newEnabled)
    }

    // MARK: De map met de geschiedenis

    /// De oude map verhuist mee, inclusief inhoud. Dat is het verschil tussen "hernoemd"
    /// en "hernoemd, en je geschiedenis is weg".
    @Test func theHistoryDirectoryMovesAlongWithItsContent() {
        let result = RenameMigrationTestSupport.migrateDirectory(alsoCreateNew: false)
        #expect(result.migrated)
        #expect(result.oldGone)
        #expect(result.contentAtNewPath == "oud")
    }

    /// Bestaan beide mappen, dan is de nieuwe al in gebruik en verhuist er niets —
    /// verhuizen zou verse rijen overschrijven met oude.
    @Test func anExistingNewDirectoryIsNeverOverwritten() {
        let result = RenameMigrationTestSupport.migrateDirectory(alsoCreateNew: true)
        #expect(!result.migrated)
        #expect(!result.oldGone)
        #expect(result.contentAtNewPath == "nieuw")
    }
}
