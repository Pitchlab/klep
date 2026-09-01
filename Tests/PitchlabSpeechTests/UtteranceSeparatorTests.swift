import Testing
@testable import PitchlabSpeech

/// Tests voor de scheiding tussen opeenvolgende uitingen bij de cursor: een uiting die
/// op een zinseinde eindigt krijgt een spatie achteraan, zodat 'eindelijk.En werkt'
/// niet meer voorkomt. De regel geldt alleen voor de cursor-route; stdout blijft
/// verbatim. Beide bestemmingen zitten achter injecteerbare lagen — geen echte
/// toetsaanslagen, geen Accessibility (rules-of-engagement §2).
///
/// Importeert bewust géén Foundation: `import Testing` + `import Foundation` in één
/// bestand triggert de cross-import overlay `_Testing_Foundation`, waarvan de
/// module-interface ontbreekt in de Command-Line-Tools-only toolchain.
@Suite struct UtteranceSeparatorTests {
    /// Een `KeystrokeInserter` die niets post maar onthoudt wat er ingevoegd zou zijn.
    final class SpyInserter: KeystrokeInserter, @unchecked Sendable {
        var authorized: Bool
        private(set) var inserted: [String] = []
        init(authorized: Bool) { self.authorized = authorized }

        var isAuthorized: Bool { authorized }
        func insert(_ text: String) throws {
            guard authorized else { throw TextOutputError.accessibilityNotAuthorized }
            inserted.append(text)
        }
    }

    /// Vangt de stdout-schrijfacties op.
    final class Recorder: @unchecked Sendable {
        private(set) var written: [String] = []
        func write(_ text: String) { written.append(text) }
    }

    // MARK: - De pure regel: eindigt de uiting op een zinseinde?

    @Test func periodQuestionExclamationEndSentences() {
        #expect(UtteranceSeparator.endsSentence("eindelijk."))
        #expect(UtteranceSeparator.endsSentence("werkt het?"))
        #expect(UtteranceSeparator.endsSentence("gelukt!"))
    }

    @Test func noSentenceEndingWhenTextDoesNotEndOnTerminator() {
        #expect(!UtteranceSeparator.endsSentence("zonder leesteken"))
        #expect(!UtteranceSeparator.endsSentence("komma,"))
        #expect(!UtteranceSeparator.endsSentence("dubbele punt:"))
    }

    @Test func emptyTextIsNotASentenceEnding() {
        #expect(!UtteranceSeparator.endsSentence(""))
    }

    /// BESLIST: de afkortingspunt ('bijv.') gaat mee — onderscheid maken kost meer dan
    /// het oplevert, dus ook hier telt het als zinseinde.
    @Test func dutchAbbreviationDotAlsoCountsAsSentenceEnding() {
        #expect(UtteranceSeparator.endsSentence("bijv."))
        #expect(UtteranceSeparator.endsSentence("bekijk het bijv."))
    }

    // MARK: - Cursor-route: spatie erachter, niet ervoor

    @Test func cursorAppendsSpaceAfterSentenceEnding() throws {
        let inserter = SpyInserter(authorized: true)
        let out = Recorder()
        let output = TextOutput(inserter: inserter, writeStandardOutput: out.write)

        try output.emit("eindelijk.", to: .cursor)

        // Spatie achteraan (aparte insert), niet vooraan.
        #expect(inserter.inserted == ["eindelijk.", " "])
    }

    @Test func cursorAppendsNoSpaceWithoutSentenceEnding() throws {
        let inserter = SpyInserter(authorized: true)
        let out = Recorder()
        let output = TextOutput(inserter: inserter, writeStandardOutput: out.write)

        try output.emit("zonder leesteken", to: .cursor)

        #expect(inserter.inserted == ["zonder leesteken"])
    }

    /// Auto-enter aan: er komt al een Return achter de uiting, dus géén extra spatie —
    /// anders staat er een spatie vóór de nieuwe regel.
    @Test func autoEnterAppendsReturnAndNoSpace() throws {
        let inserter = SpyInserter(authorized: true)
        let out = Recorder()
        let output = TextOutput(inserter: inserter, writeStandardOutput: out.write)

        try output.emit("eindelijk.", to: .cursor, pressReturn: true)

        // Return via de default-extensie (een newline), en geen spatie ertussen.
        #expect(inserter.inserted == ["eindelijk.", "\n"])
    }

    // MARK: - Stdout blijft verbatim

    @Test func standardOutputStaysVerbatimEvenWithSentenceEnding() throws {
        let inserter = SpyInserter(authorized: true)
        let out = Recorder()
        let output = TextOutput(inserter: inserter, writeStandardOutput: out.write)

        try output.emit("eindelijk.", to: .standardOutput)

        // Geen spatie op stdout: de scheiding is een cursor-keuze.
        #expect(out.written == ["eindelijk."])
        #expect(inserter.inserted.isEmpty)
    }

    /// Beide bestemmingen: stdout verbatim, cursor krijgt de spatie erachter.
    @Test func bothDestinationsSeparateOnlyAtCursor() throws {
        let inserter = SpyInserter(authorized: true)
        let out = Recorder()
        let output = TextOutput(inserter: inserter, writeStandardOutput: out.write)

        try output.emit("eindelijk.", to: .both)

        #expect(out.written == ["eindelijk."])
        #expect(inserter.inserted == ["eindelijk.", " "])
    }
}
