/// Waar Klep zijn modellen bewaart: `~/Library/Application Support/Klep/Models/`.
///
/// FluidAudio kiest zonder pad zijn eigen gedeelde cache (`Application Support/FluidAudio`).
/// Een andere app die die cache opruimt, haalt dan ook Klep's Parakeet weg. Met een eigen
/// map hoort het model bij Klep en verdwijnt het alleen als Klep zelf weg gaat.
import Foundation

public enum ModelDirectory {
    /// `~/Library/Application Support/Klep`. FluidAudio's VAD hangt hier zelf `Models/` aan.
    public static func base() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            .appendingPathComponent(TranscriptStore.directoryName, isDirectory: true)
    }

    /// De map van het Parakeet-model, zoals `AsrModels.download(to:)` hem verwacht.
    public static func parakeet() throws -> URL {
        try base()
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
    }
}
