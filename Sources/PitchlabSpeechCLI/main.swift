/// CLI-entrypoint `pitchlab-speech`. Twee modi:
///  - `--once <wav>`: transcribeer één wav-bestand en schrijf het transcript naar
///    stdout, zodat spraak in een pipe past (`pitchlab-speech --once x.wav | …`).
///    Draait zonder microfoon of Accessibility — de modus die de gate checkt.
///  - zonder argumenten: live-modus (mic → cursor + stdout). Vereist mic- en
///    Accessibility-permissie en is een mensentest; hier geeft het een expliciete
///    melding in plaats van stil te falen.
///
/// De logica zit in de library (`Pipeline`); dit bestand is puur argument-parsing.
import Foundation
import PitchlabSpeech

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())

if let flag = arguments.firstIndex(of: "--once") {
    guard flag + 1 < arguments.count else {
        fail("--once vereist een pad naar een wav-bestand")
    }
    let path = arguments[flag + 1]
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        fail("bestand niet gevonden: \(path)")
    }
    do {
        let text = try await Pipeline().runOnce(url, to: .standardOutput)
        // Sluit met een newline af zodat pipe-consumenten (grep, tee) een hele regel
        // zien; `TextOutput` schrijft het transcript verbatim, zonder eigen newline.
        if !text.hasSuffix("\n") {
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    } catch {
        fail("transcriptie faalde: \(error)")
    }
} else {
    fail("live-modus vereist microfoon- en Accessibility-permissie (mensentest). "
        + "Gebruik `--once <wav>` om een bestand naar stdout te transcriberen.")
}
