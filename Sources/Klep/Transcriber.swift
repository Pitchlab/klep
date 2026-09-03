/// STT-core: Parakeet TDT 0.6b v3 via FluidAudio (CoreML, Neural Engine).
///
/// Het model wordt eenmalig geladen en warm gehouden in een actor, zodat
/// opeenvolgende uitingen geen herlaadkost betalen. `transcribe(_:)` geeft de
/// tekst voor één uiting. Werkt offline zodra het model op schijf staat; alleen
/// de eerste download heeft netwerk nodig.
///
/// De aanroep-volgorde (downloadAndLoad → AsrManager → loadModels → per uiting
/// een verse `TdtDecoderState` → `transcribe`) is de in spike PL-715 (PIT-847)
/// bewezen vorm; hier niet opnieuw verzonnen.
import Foundation
import FluidAudio

public actor Transcriber {
    public enum Failure: Error {
        /// `transcribe` aangeroepen voordat het model geladen kon worden.
        case notLoaded
    }

    private var asr: AsrManager?
    private var decoderLayers = 0
    private var loads = 0

    public init() {}

    /// Het model is geladen en warm.
    public var isWarm: Bool { asr != nil }

    /// Hoe vaak het model daadwerkelijk geladen is. Blijft 1 zodra het warm is:
    /// bewijs dat `warmUp` idempotent is en opeenvolgende uitingen het model
    /// niet herladen.
    public var loadCount: Int { loads }

    /// Laadt het Parakeet-model eenmalig en houdt het warm. Idempotent: een
    /// tweede aanroep is een no-op. De eerste aanroep downloadt het model naar
    /// de FluidAudio-cache als het nog niet op schijf staat.
    public func warmUp() async throws {
        guard asr == nil else { return }
        loads += 1
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        decoderLayers = await manager.decoderLayerCount
        asr = manager
    }

    /// Transcribeert één uiting (een 16 kHz mono wav-bestand) naar tekst.
    /// Warmt zo nodig eerst op. Elke uiting krijgt een verse decoder-state, dus
    /// losse single-shots zonder overloop tussen uitingen.
    public func transcribe(_ audioURL: URL) async throws -> String {
        try await warmUp()
        guard let asr else { throw Failure.notLoaded }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await asr.transcribe(audioURL, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
