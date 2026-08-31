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

    public init(transcriber: Transcriber = Transcriber(), output: TextOutput = TextOutput()) {
        self.transcriber = transcriber
        self.output = output
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
        _ utterances: AsyncStream<Utterance>, to destinations: TextDestinations = .both
    ) async throws {
        for await utterance in utterances {
            let url = try Self.writeTemporaryWav(utterance.samples)
            defer { try? FileManager.default.removeItem(at: url) }
            let text = try await transcriber.transcribe(url)
            guard !text.isEmpty else { continue }
            try output.emit(text, to: destinations)
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
