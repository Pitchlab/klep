import Testing
@testable import Klep

/// Tests voor de tekstuitvoer. Beide bestemmingen zitten achter injecteerbare
/// lagen, dus geen echte toetsaanslagen en geen Accessibility nodig — het echt
/// posten van events is een mensentest (rules-of-engagement §2).
///
/// Dit bestand importeert bewust géén Foundation: `import Testing` + `import
/// Foundation` in één bestand triggert de cross-import overlay `_Testing_Foundation`,
/// waarvan de module-interface ontbreekt in de Command-Line-Tools-only toolchain.
@Suite struct TextOutputTests {
    /// Een `KeystrokeInserter` die niets post maar onthoudt wat er ingevoegd zou
    /// zijn, met instelbare toestemming.
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

    @Test func standardOutputWritesVerbatim() throws {
        let inserter = SpyInserter(authorized: true)
        let out = Recorder()
        let output = TextOutput(inserter: inserter, writeStandardOutput: out.write)

        try output.emit("Zet handsfree modus aan.", to: .standardOutput)

        #expect(out.written == ["Zet handsfree modus aan."])
        #expect(inserter.inserted.isEmpty)
    }

    @Test func cursorInsertsThroughInserter() throws {
        let inserter = SpyInserter(authorized: true)
        let out = Recorder()
        let output = TextOutput(inserter: inserter, writeStandardOutput: out.write)

        try output.emit("bij de cursor", to: .cursor)

        #expect(inserter.inserted == ["bij de cursor"])
        #expect(out.written.isEmpty)
    }

    @Test func bothDestinationsReceiveTheText() throws {
        let inserter = SpyInserter(authorized: true)
        let out = Recorder()
        let output = TextOutput(inserter: inserter, writeStandardOutput: out.write)

        try output.emit("tekst", to: .both)

        #expect(out.written == ["tekst"])
        #expect(inserter.inserted == ["tekst"])
    }

    @Test func missingAccessibilityThrowsExplicitlyForCursor() throws {
        let inserter = SpyInserter(authorized: false)
        let out = Recorder()
        let output = TextOutput(inserter: inserter, writeStandardOutput: out.write)

        #expect(throws: TextOutputError.accessibilityNotAuthorized) {
            try output.emit("tekst", to: .cursor)
        }
        #expect(inserter.inserted.isEmpty)
    }

    @Test func standardOutputNeedsNoAccessibility() throws {
        let inserter = SpyInserter(authorized: false)
        let out = Recorder()
        let output = TextOutput(inserter: inserter, writeStandardOutput: out.write)

        try output.emit("tekst", to: .standardOutput)

        #expect(out.written == ["tekst"])
    }

    /// Beide gevraagd, geen toestemming: stdout krijgt de tekst wél (die route
    /// heeft geen Accessibility nodig), en de cursor-route gooit expliciet — geen
    /// stille mislukking.
    @Test func bothWithoutAccessibilityStillWritesStdoutThenThrows() throws {
        let inserter = SpyInserter(authorized: false)
        let out = Recorder()
        let output = TextOutput(inserter: inserter, writeStandardOutput: out.write)

        #expect(throws: TextOutputError.accessibilityNotAuthorized) {
            try output.emit("tekst", to: .both)
        }
        #expect(out.written == ["tekst"])
        #expect(inserter.inserted.isEmpty)
    }
}
