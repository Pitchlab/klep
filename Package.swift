// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Swift Testing (`import Testing`) ships in de actieve developer-directory onder
// Library/Developer/Frameworks, maar staat niet op het standaard zoekpad van een
// CLT-only toolchain. We voegen dat pad toe aan het test-target zodat de kale gate
// `swift build -c release && swift test` werkt zonder extra vlaggen. Afgeleid van
// `xcode-select -p`; valt terug op de CLT-standaardlocatie.
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
    name: "PitchlabSpeech",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PitchlabSpeech", targets: ["PitchlabSpeech"]),
    ],
    targets: [
        .target(name: "PitchlabSpeech"),
        .testTarget(
            name: "PitchlabSpeechTests",
            dependencies: ["PitchlabSpeech"],
            swiftSettings: [.unsafeFlags(["-F", frameworksPath])],
            linkerSettings: [.unsafeFlags(["-F", frameworksPath, "-Xlinker", "-rpath", "-Xlinker", frameworksPath])]
        ),
    ]
)
