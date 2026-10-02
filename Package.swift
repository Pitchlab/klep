// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Swift Testing (`import Testing`) ships in de actieve developer-directory onder
// Library/Developer/Frameworks, maar staat niet op het standaard zoekpad van een
// CLT-only toolchain. Dit pad + rpath op het test-target laat de test-binary
// Testing.framework compileren en op runtime vinden. Het maakt kaal `swift test`
// NIET groen: SwiftPM linkt dan een .xctest-bundle die de xctest-host nodig heeft
// (alleen in Xcode), draait nul tests en eindigt exit 0 — false green. De gate is
// `make gate` (= `swift test -Xswiftc -F -Xswiftc <frameworksPath>`), zie README.
// Pad afgeleid van `xcode-select -p`; valt terug op de CLT-standaardlocatie.
func developerDir() -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    proc.arguments = ["-p"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    guard (try? proc.run()) != nil else { return "/Library/Developer/CommandLineTools" }
    proc.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (out?.isEmpty == false ? out! : "/Library/Developer/CommandLineTools")
}
let frameworksPath = developerDir() + "/Library/Developer/Frameworks"

let package = Package(
    name: "Klep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Klep", targets: ["Klep"]),
        // Menubalk-binary die `scripts/build-app.sh` tot Klep.app verpakt.
        .executable(name: "KlepApp", targets: ["KlepApp"]),
        // CLI-binary: `klep --once <wav>` transcribeert naar stdout,
        // zodat spraak in een pipe past en de gate zonder microfoon draait.
        .executable(name: "klep", targets: ["KlepCLI"]),
    ],
    dependencies: [
        // Parakeet TDT 0.6b v3 via CoreML/Neural Engine. Versie zoals bewezen in
        // de Swift-spike (0.12.4 resolvet naar 0.15.6).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .target(
            name: "Klep",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        // Dunne instap: roept `runMenuBarApp()` uit de library. De AppKit-runloop
        // en het statusitem tonen is een mensentest; de logica staat in de library.
        .executableTarget(
            name: "KlepApp",
            dependencies: ["Klep"]
        ),
        // Dunne CLI-instap: parseert `--once` en roept `Pipeline` in de library aan.
        .executableTarget(
            name: "KlepCLI",
            dependencies: ["Klep"]
        ),
        .testTarget(
            name: "KlepTests",
            dependencies: ["Klep"],
            // Geen resources: de NL-fixture wordt in de test gegenereerd met
            // `say`+`afconvert` (zie Fixtures.swift), niet ingecheckt.
            swiftSettings: [.unsafeFlags(["-F", frameworksPath])],
            linkerSettings: [.unsafeFlags(["-F", frameworksPath, "-Xlinker", "-rpath", "-Xlinker", frameworksPath])]
        ),
    ]
)
