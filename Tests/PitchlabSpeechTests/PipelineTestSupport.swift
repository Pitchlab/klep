import Foundation
@testable import PitchlabSpeech

/// Foundation-hulp voor de pipeline-tests. Staat los van het testbestand omdat
/// `import Testing` samen met `import Foundation` de cross-import overlay
/// `_Testing_Foundation` triggert, die ontbreekt in de CLT-only toolchain (zie
/// `Fixtures.swift`). Testing blijft in `PipelineTests.swift`, Foundation hier.
enum PipelineTestSupport {

    /// Vangt wat een `KeystrokeInserter` bij de cursor zou invoegen, zonder echte
    /// toetsaanslagen te posten (die vragen Accessibility — ROE §2). `isAuthorized`
    /// is instelbaar zodat de test ook de niet-geautoriseerde route kan afdwingen.
    final class RecordingInserter: KeystrokeInserter, @unchecked Sendable {
        let isAuthorized: Bool
        private(set) var inserted: [String] = []

        init(authorized: Bool = true) { self.isAuthorized = authorized }

        func insert(_ text: String) throws {
            guard isAuthorized else { throw TextOutputError.accessibilityNotAuthorized }
            inserted.append(text)
        }
    }

    /// Wat één pipeline-run naar de cursor en naar stdout schreef.
    struct Capture {
        let returned: String
        let stdout: String
        let cursor: [String]
    }

    /// Draait `Pipeline.runOnce` op de korte fixture met een gevangen stdout en een
    /// injecteerbare cursor-inserter, zodat de test het transcript op beide
    /// bestemmingen kan nalopen zonder systeemtoestemming.
    static func runOnceFixture(
        to destinations: TextDestinations, authorized: Bool = true
    ) async throws -> Capture {
        let inserter = RecordingInserter(authorized: authorized)
        let box = StdoutBox()
        let output = TextOutput(
            inserter: inserter,
            writeStandardOutput: { box.append($0) })
        let pipeline = Pipeline(output: output)
        let returned = try await pipeline.runOnce(Fixtures.shortFixtureURL, to: destinations)
        return Capture(returned: returned, stdout: box.value, cursor: inserter.inserted)
    }

    /// Threadveilige verzamelaar voor de stdout-closure.
    private final class StdoutBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        var value: String { lock.withLock { buffer } }
        func append(_ text: String) { lock.withLock { buffer += text } }
    }
}
