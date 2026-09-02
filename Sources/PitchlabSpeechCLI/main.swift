/// CLI-entrypoint `pitchlab-speech`. Drie modi:
///  - `--once <wav>`: transcribeer één wav-bestand en schrijf het transcript naar
///    stdout, zodat spraak in een pipe past (`pitchlab-speech --once x.wav | …`).
///    Draait zonder microfoon of Accessibility — de modus die de gate checkt.
///  - `--listen[=on]` / `--listen=off`: zet hands-free vanaf de commandline aan of uit.
///    Aan draait de ECHTE audioketen (mic → VAD → transcriptie) tot Ctrl-C en schrijft
///    elk transcript als een regel naar stdout — óók het diagnose-instrument om de
///    keten zonder de menubalk-app te draaien. Dezelfde `HandsFreeController` en dezelfde
///    stand als het menu-item, geen tweede pad.
///  - zonder argumenten: melding dat er een modus gekozen moet worden.
///
/// De logica zit in de library (`Pipeline`, `ListenMode`, `HandsFreeController`); dit
/// bestand is argument-parsing plus de productie-randen (mic, stdout, toestemming).
import Foundation
import PitchlabSpeech

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())

// MARK: - `--listen`: hands-free aan/uit vanaf de commandline

switch ListenArgument.parse(arguments) {
case .absent:
    break   // val door naar `--once` / de melding hieronder
case .off:
    // Zet alleen de gedeelde stand uit. Een draaiende menubalk-app op afstand stoppen
    // is bewust buiten scope (vraagt IPC).
    ListenMode().turnOff()
    exit(0)
case .invalid(let value):
    fail("onbekende waarde voor --listen: \(value). Gebruik --listen, --listen=on of --listen=off.")
case .on:
    // Kies het apparaat: `--device <id-of-naam>`, anders de bewaarde menu-keuze
    // (dezelfde selectie als de menubalk), anders de systeemstandaard.
    let device: DeviceInfo?
    if let flag = arguments.firstIndex(of: "--device") {
        guard flag + 1 < arguments.count else {
            fail("--device vereist een apparaat-id of -naam")
        }
        let wanted = arguments[flag + 1]
        let devices = AVFoundationDeviceEnumerator().availableDevices()
        guard let picked = devices.first(where: { $0.uniqueID == wanted || $0.localizedName == wanted })
        else {
            let known = devices.map(\.localizedName).joined(separator: ", ")
            fail("apparaat niet gevonden: \(wanted). Beschikbaar: \(known.isEmpty ? "geen" : known)")
        }
        device = picked
    } else {
        device = MicrophoneSelector().resolve().device
    }

    // `--auto-enter`: geef de pipe-gebruiker dezelfde Return-logica als het menu — een
    // regeleinde ná de uiting. Default uit.
    let autoEnter = arguments.contains("--auto-enter")

    // Dezelfde keten als de menubalk (`startHandsFree`): productie-mic, warm-gehouden
    // model, gedeelde toestemmingsgate. Alleen de indicator (stil) en de uitvoerlaag
    // (stdout, regel per uiting) zijn CLI-randen.
    let controller = HandsFreeController(
        audio: MicrophoneCapture(),
        transcriber: WarmTranscriber(),
        sink: StandardOutputLineSink(),
        indicator: SilentListeningIndicator(),
        permission: AVCaptureMicrophonePermission(),
        autoEnter: { autoEnter },
        // Ook deze route bewaart (PL-757). `--listen` is dicteren, geen bestand
        // omzetten: `mode` legt vast dat het transcript naar stdout ging en niet naar
        // de cursor. `--once` blijft bewust ongestoord — dat zet een bestand om.
        store: TranscriptStore.open())

    // Geen stil falen: een keten-fout (bv. audiobron kon niet starten) landt op stderr
    // in plaats van in het menu-paneel.
    await controller.setOnError { message in
        FileHandle.standardError.write(Data(("fout: " + message + "\n").utf8))
    }

    // Ctrl-C stopt netjes: de opname sluiten laat de laatste uiting afmaken, de stroom
    // sluit en `run` keert terug. `SIG_IGN` haalt de default-terminate weg zodat de
    // dispatch-bron het signaal krijgt.
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        Task { await controller.requestStop() }
    }
    sigint.resume()

    let started = await ListenMode().turnOn(controller: controller, device: device)
    guard started else {
        // Microfoontoestemming geweigerd (PL-740): de reden staat al op stderr via
        // onError; sluit af met een niet-0 exit zodat een script het ziet.
        fail("--listen kon niet starten: geen microfoontoestemming.", code: 3)
    }
    exit(0)
}

// MARK: - `--once`: één wav-bestand naar stdout

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
    fail("kies een modus: `--once <wav>` transcribeert een bestand naar stdout, "
        + "`--listen` zet hands-free aan (Ctrl-C stopt), `--listen=off` weer uit.")
}
