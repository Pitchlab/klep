import Foundation
@testable import Klep

/// Foundation-hulp voor de menubalk-tests. Los van het testbestand omdat `import
/// Testing` samen met `import Foundation` in één bestand de cross-import overlay
/// `_Testing_Foundation` triggert, die ontbreekt in de CLT-only toolchain (zie
/// `Fixtures.swift`/`AudioTestSupport.swift`). Testing blijft in `MenuBarTests.swift`,
/// Foundation hier. De helpers geven kale stdlib-types terug zodat het testbestand
/// geen Foundation hoeft te importeren.
enum MenuBarTestSupport {

    /// Uitkomst van de LaunchAgent-levenscyclus: schrijven zet auto-start aan,
    /// verwijderen weer uit, en verwijderen zonder bestand faalt niet.
    struct LaunchAgentLifecycle {
        let enabledBeforeWrite: Bool
        let enabledAfterEnable: Bool
        let plistExistsOnDisk: Bool
        let enabledAfterDisable: Bool
        let doubleDisableThrew: Bool
        let plistPathEndsWithLabel: Bool
    }

    /// Draait enable → disable in een tijdelijke map (nooit de echte
    /// `~/Library/LaunchAgents`) en rapporteert elke stap als Bool.
    static func runLaunchAgentLifecycle() -> LaunchAgentLifecycle {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("klep-launchagent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let agent = LaunchAgent(executablePath: "/Applications/Klep.app/Contents/MacOS/Klep")
        let manager = LaunchAgentManager(agent: agent, directory: dir)

        let before = manager.isEnabled()
        try? manager.enable()
        let afterEnable = manager.isEnabled()
        let onDisk = FileManager.default.fileExists(atPath: manager.plistURL.path)
        try? manager.disable()
        let afterDisable = manager.isEnabled()

        var doubleThrew = false
        do { try manager.disable() } catch { doubleThrew = true }

        let pathOK = manager.plistURL.lastPathComponent == "\(agent.label).plist"

        return LaunchAgentLifecycle(
            enabledBeforeWrite: before,
            enabledAfterEnable: afterEnable,
            plistExistsOnDisk: onDisk,
            enabledAfterDisable: afterDisable,
            doubleDisableThrew: doubleThrew,
            plistPathEndsWithLabel: pathOK)
    }

    /// De LaunchAgent-plist als tekst, voor de inhoud-checks in het testbestand.
    static func launchAgentPlistString(executablePath: String) -> String {
        LaunchAgent(executablePath: executablePath).plistString() ?? ""
    }

    /// `toggle()` twee keer: uit→aan→uit. Geeft de twee tussenstanden terug.
    static func runToggleTwice() -> (afterFirst: Bool, afterSecond: Bool) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("klep-toggle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = LaunchAgentManager(
            agent: LaunchAgent(executablePath: "/tmp/Klep"), directory: dir)
        let first = (try? manager.toggle()) ?? false
        let second = (try? manager.toggle()) ?? true
        return (first, second)
    }
}
