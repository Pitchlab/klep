import Foundation
@testable import Klep

/// Foundation-hulp voor de hernoem-migraties (PL-731). Los van het testbestand omdat
/// `import Testing` samen met `import Foundation` de cross-import overlay
/// `_Testing_Foundation` triggert, die ontbreekt in de CLT-only toolchain.
enum RenameMigrationTestSupport {

    struct AgentCleanup {
        let removed: Bool
        let legacyGone: Bool
        let newEnabled: Bool
    }

    /// Legt een plist van de oude naam neer in een tijdelijke map, ruimt op, en kijkt
    /// wat er daarna staat. Raakt `~/Library/LaunchAgents` niet aan.
    static func cleanupLegacyAgent(legacyEnabled: Bool) -> AgentCleanup {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("klep-agents-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = LaunchAgentManager(
            agent: LaunchAgent(label: "nl.pitchlab.klep", executablePath: "/usr/bin/true"),
            directory: dir)
        let legacy = dir.appendingPathComponent("\(LaunchAgentManager.legacyLabel).plist")
        if legacyEnabled {
            FileManager.default.createFile(atPath: legacy.path, contents: Data("x".utf8))
        }

        let removed = manager.removeLegacyAgent()
        return AgentCleanup(
            removed: removed,
            legacyGone: !FileManager.default.fileExists(atPath: legacy.path),
            newEnabled: manager.isEnabled())
    }

    struct DirectoryMigration {
        let migrated: Bool
        let oldGone: Bool
        let contentAtNewPath: String?
    }

    /// Zet een bestand in de oude map, verhuist, en leest terug of het meeging.
    /// `alsoCreateNew` maakt óók de nieuwe map aan — dan mag er niets verhuizen.
    static func migrateDirectory(alsoCreateNew: Bool) -> DirectoryMigration {
        let fm = FileManager.default
        let support = fm.temporaryDirectory
            .appendingPathComponent("klep-support-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: support) }

        let old = support.appendingPathComponent(TranscriptStore.legacyDirectoryName, isDirectory: true)
        try? fm.createDirectory(at: old, withIntermediateDirectories: true)
        fm.createFile(atPath: old.appendingPathComponent("marker").path, contents: Data("oud".utf8))

        let new = support.appendingPathComponent(TranscriptStore.directoryName, isDirectory: true)
        if alsoCreateNew {
            try? fm.createDirectory(at: new, withIntermediateDirectories: true)
            fm.createFile(atPath: new.appendingPathComponent("marker").path, contents: Data("nieuw".utf8))
        }

        let migrated = TranscriptStore.migrateLegacyDirectory(in: support)
        let data = fm.contents(atPath: new.appendingPathComponent("marker").path)
        return DirectoryMigration(
            migrated: migrated,
            oldGone: !fm.fileExists(atPath: old.path),
            contentAtNewPath: data.flatMap { String(data: $0, encoding: .utf8) })
    }
}
