// Wegwerp-spike (PL-715 / PIT-847): draait Parakeet TDT 0.6b v3 native in Swift via
// FluidAudio + CoreML, zonder Xcode (alleen Command Line Tools). Meet koude start,
// warme transcriptie en piek-geheugen zodat het naast de Python/MLX-cijfers ligt.

import Foundation
import FluidAudio

// Piek-RSS in MB. getrusage.ru_maxrss is bytes op macOS -> zelfde formule als de Python-spike.
func peakRssMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / (1024 * 1024)
}

func now() -> Double { Date().timeIntervalSince1970 }

// Koude start telt vanaf procesopstart, niet vanaf hier: benader met de wall-clock sinds
// de kernel het proces mapte. ProcessInfo geeft geen starttijd, dus we meten vanaf main.
let processStart = now()

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: parakeet-spike <fixture.wav>\n".utf8))
    exit(2)
}
let wavURL = URL(fileURLWithPath: CommandLine.arguments[1])

func report(_ dict: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

do {
    var out: [String: Any] = ["model": "FluidInference/parakeet-tdt-0.6b-v3-coreml", "fixture": wavURL.lastPathComponent]

    // 1+2: model laden (downloadt eenmalig naar de HF-cache, daarna van schijf).
    let tLoad = now()
    let models = try await AsrModels.downloadAndLoad(version: .v3)
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    out["model_load_s"] = round((now() - tLoad) * 1000) / 1000
    out["rss_after_load_mb"] = round(peakRssMB() * 10) / 10

    // 3: eerste transcriptie. Koude start = proces op tot eerste transcript.
    var state1 = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    let tFirst = now()
    let first = try await asr.transcribe(wavURL, decoderState: &state1)
    out["first_transcribe_s"] = round((now() - tFirst) * 1000) / 1000
    out["cold_start_s"] = round((now() - processStart) * 1000) / 1000
    out["first_text"] = first.text.trimmingCharacters(in: .whitespacesAndNewlines)

    // 4: warme runs. Elke run een verse decoder-state -> losse single-shot, zoals de Python-warm.
    var warm: [Double] = []
    for _ in 0..<3 {
        var st = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let t = now()
        _ = try await asr.transcribe(wavURL, decoderState: &st)
        warm.append(now() - t)
    }
    out["warm_transcribe_s"] = round((warm.min() ?? 0) * 1000) / 1000
    out["peak_rss_mb"] = round(peakRssMB() * 10) / 10

    report(out)
    // stdout krijgt ook de platte tekst zodat de CHECK op 'cursor' kan greppen.
    print(first.text.trimmingCharacters(in: .whitespacesAndNewlines))
} catch {
    FileHandle.standardError.write(Data("SPIKE FAILED: \(error)\n".utf8))
    exit(1)
}
