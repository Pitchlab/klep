/// Pipeline: bindt audio-invoer, transcriptie en tekstuitvoer aaneen tot één
/// lopende keten. Twee ingangen, dezelfde uitgang:
///  - `runOnce(_:to:)` transcribeert één wav-bestand — de kern van de CLI-modus,
///    zodat spraak in een pipe past en de check zonder microfoon draait.
///  - `run(_:to:)` consumeert de `Utterance`-stroom van `MicrophoneCapture` (live,
///    mensentest: mic-permissie) en transcribeert elke uiting los.
///
/// Beide routes lopen door dezelfde `Transcriber` (warm gehouden model) en dezelfde
/// `TextOutput` (cursor + stdout). Een uiting uit de segmenter is een array samples;
/// de bewezen `Transcriber.transcribe(_:)` neemt een wav-URL, dus de live-route
/// schrijft de samples eerst naar een tijdelijke 16 kHz mono wav — dezelfde vorm als
/// de fixture — en ruimt die daarna op.
import Foundation
import AVFoundation

public struct Pipeline {
    private let transcriber: Transcriber
    private let output: TextOutput
    private let store: TranscriptStore?

    /// `store` is optioneel en standaard `nil`: het dicteren is de hoofdtaak, dus een
    /// ontbrekende geschiedenis-database (open mislukt → `nil`) mag de keten niet
    /// blokkeren. Is er een store, dan landt elke afgeronde uiting van de live-route
    /// erin met tekst, tijdstip, duur en modus.
    public init(
        transcriber: Transcriber = Transcriber(),
        output: TextOutput = TextOutput(),
        store: TranscriptStore? = nil
    ) {
        self.transcriber = transcriber
        self.output = output
        self.store = store
    }

    /// CLI `--once`: transcribeer één wav-bestand en stuur het transcript naar de
    /// bestemming(en). Standaard alleen stdout, zodat de modus zonder Accessibility
    /// werkt en in een pipe past. Geeft het transcript terug voor de aanroeper.
    @discardableResult
    public func runOnce(
        _ audioURL: URL, to destinations: TextDestinations = .standardOutput
    ) async throws -> String {
        let text = try await transcriber.transcribe(audioURL)
        try output.emit(text, to: destinations)
        return text
    }

    /// Live: consumeer gesegmenteerde uitingen, transcribeer elke en stuur het
    /// transcript naar de bestemming(en). Loopt tot de stroom sluit (mic gestopt).
    /// Lege transcripties (stilte) worden overgeslagen. Runtime is een mensentest
    /// (mic + Accessibility); de binding zelf compileert in de gate.
    public func run(
        _ utterances: AsyncStream<Utterance>,
        to destinations: TextDestinations = .both,
        mode: String = "hands-free"
    ) async throws {
        for await utterance in utterances {
            let url = try Self.writeTemporaryWav(utterance.samples)
            defer { try? FileManager.default.removeItem(at: url) }
            let text = try await transcriber.transcribe(url)
            guard !text.isEmpty else { continue }
            try output.emit(text, to: destinations)
            // Na een geslaagde invoeging: bewaar de uiting. `record` gooit nooit, dus
            // een stukke database blokkeert de volgende uiting niet.
            store?.record(text: text, duration: utterance.duration, mode: mode)
        }
    }

    /// Schrijft 16 kHz mono samples naar een tijdelijke int16-wav (het formaat dat
    /// FluidAudio verwacht) zodat de bestaande URL-gebaseerde `Transcriber` een
    /// gesegmenteerde uiting kan verwerken.
    static func writeTemporaryWav(_ samples: [Float]) throws -> URL {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(UtteranceSegmenter.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitchlab-speech-pipeline", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("utt-\(UUID().uuidString).wav")

        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))
        else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if !samples.isEmpty {
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
        }
        try file.write(from: buffer)
        return url
    }
}

// MARK: - Luister-modus (CLI `--listen`)

/// Wat `--listen` uit de argumenten wil. `--listen` en `--listen=on` zetten hands-free
/// aan, `--listen=off` uit. Zo bedienen de CLI-vlag en het menubalk-item dezelfde
/// stand (zie `HandsFreeStateStore`) zonder een tweede pad — precies wat PIT-900 fout
/// deed door een aparte keten te bouwen.
public enum ListenArgument: Sendable, Equatable {
    /// Geen `--listen` in de argumenten.
    case absent
    case on
    case off
    /// `--listen=<iets anders>` — de aanroeper krijgt een leesbare fout, geen gok.
    case invalid(String)

    /// Leest de eerste `--listen`-vlag uit `arguments` (zonder het programmapad).
    public static func parse(_ arguments: [String]) -> ListenArgument {
        for argument in arguments {
            if argument == "--listen" { return .on }
            guard argument.hasPrefix("--listen=") else { continue }
            switch String(argument.dropFirst("--listen=".count)) {
            case "on": return .on
            case "off": return .off
            case let other: return .invalid(other)
            }
        }
        return .absent
    }
}

/// De gedeelde hands-free-schakelaar. De menubalk-app schrijft `HotkeyAction.handsFree`
/// via `HotkeyStore.setOn(_:for:)`; `--listen` schrijft dezelfde stand, zodat er
/// één toestand is en geen tweede pad. Protocol zodat de suite een geheugen-store
/// injecteert in plaats van de echte `UserDefaults`. Bewust niet `Sendable`: de store
/// blijft binnen `ListenMode` op één executor (`UserDefaults` is zelf niet `Sendable`).
public protocol HandsFreeStateStore {
    func setHandsFreeOn(_ on: Bool)
    func isHandsFreeOn() -> Bool
}

/// `UserDefaults`-store op dezelfde sleutel als het menu-item (`HotkeyAction.handsFree`).
public struct UserDefaultsHandsFreeState: HandsFreeStateStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func setHandsFreeOn(_ on: Bool) {
        defaults.set(on, forKey: HotkeyAction.handsFree.stateKey)
    }

    public func isHandsFreeOn() -> Bool {
        defaults.bool(forKey: HotkeyAction.handsFree.stateKey)
    }
}

/// Luister-indicator voor de CLI: een no-op. De echte stip hangt aan een venster en
/// runloop (menubalk); een pipe heeft die niet. De keten blijft dezelfde
/// `HandsFreeController`, alleen de indicator-rand is leeg.
public final class SilentListeningIndicator: ListeningIndicating, @unchecked Sendable {
    public init() {}
    public func show() {}
    public func update(level: Float) {}
    public func hide() {}
}

/// Uitvoerlaag voor de CLI: schrijft elk transcript als één regel naar stdout, zodat
/// `klep --listen | …` per uiting een regel krijgt. De Return (`emitReturn`) komt alleen
/// bij `--auto-enter` langs en geeft de pipe-gebruiker dezelfde Return-logica: een
/// tweede regeleinde na de uiting. Geen cursor, geen Accessibility — puur stdout.
public struct StandardOutputLineSink: TranscriptEmitting {
    private let write: @Sendable (String) -> Void

    public init(write: @escaping @Sendable (String) -> Void = { text in
        FileHandle.standardOutput.write(Data(text.utf8))
    }) {
        self.write = write
    }

    public func emit(_ text: String, autoEnter: Bool) throws {
        write(text + "\n")
    }

    public func emitReturn() throws {
        write("\n")
    }

    /// In de geschiedenis heet deze route `stdout`, niet `cursor` — `--listen` typt
    /// nergens in, het schrijft regels weg.
    public var historyRoute: String { "stdout" }
}

/// `--listen`-modus: zet de gedeelde hands-free-stand en draait — als hij aan gaat —
/// dezelfde `HandsFreeController` als de menubalk. Geen tweede keten: de coördinator,
/// de toestemmingsgate en de stand zijn identiek, alleen de indicator (stil) en de
/// uitvoerlaag (stdout, regel per uiting) zijn CLI-randen.
public struct ListenMode {
    private let state: HandsFreeStateStore

    public init(state: HandsFreeStateStore = UserDefaultsHandsFreeState()) {
        self.state = state
    }

    /// `--listen=off`: zet de gedeelde stand uit. Geen opname. Een DRAAIENDE
    /// menubalk-app op afstand stoppen is bewust buiten scope (vraagt IPC); dit schrijft
    /// alleen de stand die zowel de CLI als het menu lezen.
    public func turnOff() {
        state.setHandsFreeOn(false)
    }

    /// `--listen`: zet de gedeelde stand aan en draai `controller` tot de stroom sluit
    /// (Ctrl-C → `requestStop`). Zet de stand daarna weer uit — na afloop luistert er
    /// niets, ook bij een geweigerde microfoon. Geeft door wat `run` gaf: `false` bij een
    /// weigering, zodat de CLI een niet-0 exit en een melding op stderr kan geven (PL-740).
    @discardableResult
    public func turnOn(controller: HandsFreeController, device: DeviceInfo?) async -> Bool {
        state.setHandsFreeOn(true)
        let started = await controller.run(device: device)
        state.setHandsFreeOn(false)
        return started
    }
}
