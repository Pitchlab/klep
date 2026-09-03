import Foundation
import AVFoundation
@testable import Klep

/// Foundation/AVFoundation-hulp voor de audio-tests. Staat los van het testbestand
/// omdat `import Testing` samen met `import Foundation` de cross-import overlay
/// `_Testing_Foundation` triggert, die ontbreekt in de CLT-only toolchain (zie
/// `Fixtures.swift`). Testing blijft daarom in `AudioInputTests.swift`, Foundation hier.
enum AudioTestSupport {

    // MARK: - Apparaat-doubles

    /// In-geheugen `SelectionStore`: geen `UserDefaults`, maar overleeft binnen een
    /// test wel een tweede `MicrophoneSelector` — zo simuleren we een herstart.
    final class MemoryStore: SelectionStore {
        private var id: String?
        func selectedDeviceID() -> String? { id }
        func setSelectedDeviceID(_ newID: String?) { id = newID }
    }

    /// Vaste apparaatlijst zodat de keuze-logica zonder AVFoundation te testen is.
    struct FakeEnumerator: AudioDeviceEnumerator {
        let devices: [DeviceInfo]
        let systemDefault: DeviceInfo?
        func availableDevices() -> [DeviceInfo] { devices }
        func systemDefaultDevice() -> DeviceInfo? { systemDefault }
    }

    static let deviceA = DeviceInfo(uniqueID: "mic-A", localizedName: "Ingebouwde microfoon")
    static let deviceB = DeviceInfo(uniqueID: "mic-B", localizedName: "AirPods")

    // MARK: - Fixture-audio

    /// De Nederlandse fixture uit spike PL-715 als 16 kHz mono float-samples.
    static func dutchSamples() -> [Float] { loadMonoFloat(Fixtures.dutchUtterance) }

    private static func loadMonoFloat(_ url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData
        else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    // MARK: - Transcriptie van een gesegmenteerde uiting

    /// Transcribeert 16 kHz mono samples door ze naar een tijdelijke int16-wav te
    /// schrijven (zelfde vorm als de fixture) en de bestaande `Transcriber` te
    /// gebruiken. Bewijst dat een door de VAD gesegmenteerde uiting nog leesbaar is.
    static func transcribe(_ samples: [Float]) async throws -> String {
        let url = try writeWav(samples)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await Transcriber().transcribe(url)
    }

    private static func writeWav(_ samples: [Float]) throws -> URL {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("klep-utterances", isDirectory: true)
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
