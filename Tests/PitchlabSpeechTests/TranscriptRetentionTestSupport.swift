import Foundation
@testable import PitchlabSpeech

/// Foundation-hulp voor de bewaartermijn-tests. Los van het testbestand omdat
/// `import Testing` samen met `import Foundation` de cross-import overlay
/// `_Testing_Foundation` triggert, die ontbreekt in de CLT-only toolchain.
/// Geeft kale stdlib-types terug zodat het testbestand geen Foundation hoeft.
enum TranscriptRetentionTestSupport {

    /// Schrijft drie uitingen weg op 31, 30 en 1 dag oud, ruimt op met een vast "nu",
    /// en geeft terug welke teksten bleven staan.
    static func pruneAtBoundary() -> [String] {
        guard let store = TranscriptStore.inMemory() else { return [] }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = 24.0 * 60 * 60

        store.record(text: "oud", duration: 1, mode: "test", at: now.addingTimeInterval(-31 * day))
        store.record(text: "grens", duration: 1, mode: "test", at: now.addingTimeInterval(-30 * day))
        store.record(text: "vers", duration: 1, mode: "test", at: now.addingTimeInterval(-1 * day))

        store.prune(now: now)
        return ((try? store.recentTranscripts()) ?? []).map(\.text)
    }

    /// Opruimen op een lege database; geeft terug of er daarna nog iets in staat.
    static func pruneEmptyLeavesNothing() -> Bool {
        guard let store = TranscriptStore.inMemory() else { return false }
        store.prune()
        return ((try? store.recentTranscripts()) ?? []).isEmpty
    }
}
