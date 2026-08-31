/// Audio-invoer: microfoonkeuze, rolling pre-roll en uiting-segmentatie.
///
/// Drie brokken, elk los te testen zonder microfoon-permissie of hardware:
///  - `MicrophoneSelector` somt invoerapparaten op (AVFoundation), bewaart de
///    keuze en valt terug op de systeemstandaard als het apparaat verdwijnt (R6).
///  - `PreRollBuffer` houdt de laatste milliseconden audio vast zodat het eerste
///    woord na een hotkey compleet is (R8).
///  - `UtteranceSegmenter` laat de VAD uit FluidAudio begin en eind van een uiting
///    bepalen en levert de hele uiting als batch — de default uit de PRD, geen
///    eigen VAD.
///
/// `MicrophoneCapture` is de productie-lijm: het opent een AVCaptureSession op het
/// gekozen apparaat en voedt de segmenter. Die live-weg vraagt mic-permissie en
/// wordt met de hand getest (PRD-mensentest), niet in de unit-tests.
import Foundation
@preconcurrency import AVFoundation
import FluidAudio

// MARK: - Apparaten

/// Eén invoerapparaat, losgekoppeld van AVFoundation zodat de keuze-logica zonder
/// hardware te testen is. `uniqueID` overleeft een herstart, de naam is voor het menu.
public struct DeviceInfo: Sendable, Equatable, Identifiable {
    public let uniqueID: String
    public let localizedName: String
    public var id: String { uniqueID }

    public init(uniqueID: String, localizedName: String) {
        self.uniqueID = uniqueID
        self.localizedName = localizedName
    }
}

/// Bron van de apparaatlijst. Een protocol zodat de tests een vaste lijst injecteren
/// in plaats van de echte AVFoundation-discovery aan te roepen.
public protocol AudioDeviceEnumerator: Sendable {
    func availableDevices() -> [DeviceInfo]
    func systemDefaultDevice() -> DeviceInfo?
}

/// Echte apparaatlijst via `AVCaptureDevice.DiscoverySession` (R6, PRD-tabel).
public struct AVFoundationDeviceEnumerator: AudioDeviceEnumerator {
    public init() {}

    public func availableDevices() -> [DeviceInfo] {
        let types: [AVCaptureDevice.DeviceType] = [.microphone, .external]
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .audio, position: .unspecified)
        return session.devices.map {
            DeviceInfo(uniqueID: $0.uniqueID, localizedName: $0.localizedName)
        }
    }

    public func systemDefaultDevice() -> DeviceInfo? {
        guard let device = AVCaptureDevice.default(for: .audio) else { return nil }
        return DeviceInfo(uniqueID: device.uniqueID, localizedName: device.localizedName)
    }
}

// MARK: - Keuze bewaren

/// Persistente opslag van de gekozen apparaat-id. Protocol zodat de tests een
/// geheugen-store gebruiken en de echte keuze in `UserDefaults` een herstart overleeft.
public protocol SelectionStore: AnyObject {
    func selectedDeviceID() -> String?
    func setSelectedDeviceID(_ id: String?)
}

/// `UserDefaults`-backed store — de keuze blijft bewaard tussen sessies (R6).
public final class UserDefaultsSelectionStore: SelectionStore {
    private let defaults: UserDefaults
    private let key = "pitchlab.speech.selectedMicrophoneID"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func selectedDeviceID() -> String? { defaults.string(forKey: key) }
    public func setSelectedDeviceID(_ id: String?) { defaults.set(id, forKey: key) }
}

/// Melding wanneer het gekozen apparaat verdwenen is en de app terugviel op de
/// systeemstandaard. Het menu toont `message` in plaats van stil te vallen (R6).
public enum FallbackNotice: Sendable, Equatable {
    case selectedDeviceUnavailable(selectedID: String, fellBackTo: DeviceInfo?)

    public var message: String {
        switch self {
        case .selectedDeviceUnavailable(_, let fallback):
            if let fallback {
                return "Gekozen microfoon is losgekoppeld. Teruggevallen op \(fallback.localizedName)."
            }
            return "Gekozen microfoon is losgekoppeld en er is geen systeemstandaard."
        }
    }
}

/// Uitkomst van `resolve()`: het effectieve apparaat plus een eventuele melding.
public struct DeviceResolution: Sendable, Equatable {
    public let device: DeviceInfo?
    public let notice: FallbackNotice?

    public init(device: DeviceInfo?, notice: FallbackNotice?) {
        self.device = device
        self.notice = notice
    }
}

/// Kiest en onthoudt de microfoon. `resolve()` geeft het apparaat dat nu gebruikt
/// moet worden: de bewaarde keuze als die er nog is, anders de systeemstandaard met
/// een melding als de keuze verdwenen is.
public struct MicrophoneSelector {
    private let enumerator: AudioDeviceEnumerator
    private let store: SelectionStore

    public init(
        enumerator: AudioDeviceEnumerator = AVFoundationDeviceEnumerator(),
        store: SelectionStore = UserDefaultsSelectionStore()
    ) {
        self.enumerator = enumerator
        self.store = store
    }

    public func availableDevices() -> [DeviceInfo] { enumerator.availableDevices() }

    /// De bewaarde keuze, of nil als er nog niets gekozen is.
    public var selectedDeviceID: String? { store.selectedDeviceID() }

    public func select(_ device: DeviceInfo) { store.setSelectedDeviceID(device.uniqueID) }
    public func clearSelection() { store.setSelectedDeviceID(nil) }

    public func resolve() -> DeviceResolution {
        let available = enumerator.availableDevices()
        let systemDefault = enumerator.systemDefaultDevice()

        guard let wantedID = store.selectedDeviceID() else {
            return DeviceResolution(device: systemDefault, notice: nil)
        }
        if let match = available.first(where: { $0.uniqueID == wantedID }) {
            return DeviceResolution(device: match, notice: nil)
        }
        return DeviceResolution(
            device: systemDefault,
            notice: .selectedDeviceUnavailable(selectedID: wantedID, fellBackTo: systemDefault))
    }
}

// MARK: - Pre-roll

/// Rolling buffer met de laatste `capacity` samples. Opname loopt continu; als een
/// uiting begint zit het aanloopje er al in, zodat het eerste woord compleet is (R8).
public struct PreRollBuffer: Sendable {
    public let capacity: Int
    private var storage: [Float] = []

    public init(capacity: Int) { self.capacity = max(0, capacity) }

    /// Pre-roll in seconden bij een gegeven sample rate (16 kHz is FluidAudio's tempo).
    public init(seconds: Double, sampleRate: Int = 16_000) {
        self.init(capacity: max(0, Int(seconds * Double(sampleRate))))
    }

    public var count: Int { storage.count }

    /// Voegt samples toe en gooit de oudste weg zodra de buffer vol zit.
    public mutating func append(_ samples: [Float]) {
        storage.append(contentsOf: samples)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    /// De vastgehouden samples, oudste eerst.
    public func snapshot() -> [Float] { storage }

    public mutating func reset() { storage.removeAll(keepingCapacity: true) }
}

// MARK: - Uiting-segmentatie

/// Eén afgeronde uiting: 16 kHz mono samples, inclusief het pre-roll-aanloopje.
public struct Utterance: Sendable, Equatable {
    public let samples: [Float]

    public init(samples: [Float]) { self.samples = samples }

    public var sampleCount: Int { samples.count }
    public var duration: TimeInterval { Double(samples.count) / Double(UtteranceSegmenter.sampleRate) }
}

/// Bepaalt begin en eind van een uiting met de VAD uit FluidAudio (geen eigen VAD)
/// en levert per uiting de hele audio als batch — de PRD-default, sneller en
/// nauwkeuriger dan streaming-transcriptie. Voer willekeurige stukken 16 kHz mono
/// samples in via `feed`; op elk speech-eind komt een `Utterance` terug. `finish`
/// sluit een uiting af die nog liep toen de stroom stopte.
public actor UtteranceSegmenter {
    public static let sampleRate = 16_000

    public enum Failure: Error { case notLoaded }

    private let segmentationConfig: VadSegmentationConfig
    private let chunkSize = VadManager.chunkSize

    private var vad: VadManager?
    private var streamState: VadStreamState = .initial()
    private var preRoll: PreRollBuffer
    private var pending: [Float] = []
    private var current: [Float] = []
    private var triggered = false

    /// - Parameters:
    ///   - preRollSeconds: aanloopje dat vóór een uiting bewaard blijft (R8).
    ///   - segmentationConfig: FluidAudio's drempels; `minSilenceDuration` bepaalt
    ///     wanneer een uiting als afgerond geldt (PRD open vraag, hier de default).
    public init(preRollSeconds: Double = 0.3, segmentationConfig: VadSegmentationConfig = .default) {
        self.segmentationConfig = segmentationConfig
        self.preRoll = PreRollBuffer(seconds: preRollSeconds, sampleRate: Self.sampleRate)
    }

    public var isWarm: Bool { vad != nil }

    /// Laadt het VAD-model eenmalig. Eerste keer downloaden, daarna offline.
    public func warmUp() async throws {
        guard vad == nil else { return }
        let manager = try await VadManager(config: .default)
        streamState = await manager.makeStreamState()
        vad = manager
    }

    /// Voert samples in en geeft de uitingen terug die dit stuk afsloot.
    public func feed(_ samples: [Float]) async throws -> [Utterance] {
        try await warmUp()
        guard let vad else { throw Failure.notLoaded }
        pending.append(contentsOf: samples)

        var completed: [Utterance] = []
        while pending.count >= chunkSize {
            let chunk = Array(pending.prefix(chunkSize))
            pending.removeFirst(chunkSize)
            if let utterance = try await process(chunk: chunk, vad: vad) {
                completed.append(utterance)
            }
        }
        return completed
    }

    /// Sluit de stroom af: verwerkt de staart en levert een uiting die nog liep.
    public func finish() async throws -> Utterance? {
        guard let vad else { return nil }
        if !pending.isEmpty {
            let chunk = pending
            pending = []
            if let utterance = try await process(chunk: chunk, vad: vad) {
                return utterance
            }
        }
        if triggered, !current.isEmpty {
            let utterance = Utterance(samples: current)
            current = []
            triggered = false
            return utterance
        }
        return nil
    }

    private func process(chunk: [Float], vad: VadManager) async throws -> Utterance? {
        let result = try await vad.processStreamingChunk(
            chunk, state: streamState, config: segmentationConfig)
        streamState = result.state

        var finished: Utterance?
        if let event = result.event {
            switch event.kind {
            case .speechStart:
                current = preRoll.snapshot()
                current.append(contentsOf: chunk)
                triggered = true
            case .speechEnd:
                current.append(contentsOf: chunk)
                finished = Utterance(samples: current)
                current = []
                triggered = false
            }
        } else if triggered {
            current.append(contentsOf: chunk)
        }
        // Alleen buiten een uiting de pre-roll bijhouden: het aanloopje voor de
        // vólgende uiting mag niet de staart van de vorige bevatten.
        if !triggered { preRoll.append(chunk) }
        return finished
    }
}

// MARK: - Live capture (productie, mensentest)

/// Opent een AVCaptureSession op het gekozen apparaat, zet de audio om naar 16 kHz
/// mono en voedt de segmenter. Levert afgeronde uitingen via een `AsyncStream`.
///
/// Runtime niet gedekt door de unit-tests: dit vraagt mic-permissie en echte
/// hardware (PRD-mensentest, R7/R9). De build bewijst dat het compileert; de
/// meetbare logica zit in `MicrophoneSelector`, `PreRollBuffer` en
/// `UtteranceSegmenter` hierboven.
public final class MicrophoneCapture: NSObject, @unchecked Sendable {
    public enum Failure: Error {
        case deviceNotFound(String)
        case cannotAddInput
        case cannotAddOutput
    }

    private let segmenter: UtteranceSegmenter
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "pitchlab.speech.capture")

    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(UtteranceSegmenter.sampleRate),
        channels: 1, interleaved: false)!
    private var continuation: AsyncStream<Utterance>.Continuation?

    public init(segmenter: UtteranceSegmenter = UtteranceSegmenter()) {
        self.segmenter = segmenter
        super.init()
    }

    /// Start opnemen van `device` en geef een stroom afgeronde uitingen terug.
    public func start(device: DeviceInfo) throws -> AsyncStream<Utterance> {
        guard let avDevice = AVCaptureDevice(uniqueID: device.uniqueID) else {
            throw Failure.deviceNotFound(device.uniqueID)
        }
        let input = try AVCaptureDeviceInput(device: avDevice)

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw Failure.cannotAddInput
        }
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw Failure.cannotAddOutput
        }
        session.addOutput(output)
        session.commitConfiguration()

        let stream = AsyncStream<Utterance> { continuation in
            self.continuation = continuation
        }
        session.startRunning()
        return stream
    }

    /// Stop opnemen en sluit een uiting af die nog liep.
    public func stop() async {
        session.stopRunning()
        if let tail = try? await segmenter.finish() {
            continuation?.yield(tail)
        }
        continuation?.finish()
        continuation = nil
    }
}

extension MicrophoneCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let samples = float16kMono(from: sampleBuffer) else { return }
        Task { [segmenter, continuation] in
            guard let utterances = try? await segmenter.feed(samples) else { return }
            for utterance in utterances { continuation?.yield(utterance) }
        }
    }

    /// Zet een opgevangen CMSampleBuffer om naar 16 kHz mono float via AVAudioConverter.
    private func float16kMono(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }
        var streamDesc = asbdPointer.pointee
        guard let inputFormat = AVAudioFormat(streamDescription: &streamDesc) else { return nil }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        inputBuffer.frameLength = AVAudioFrameCount(frames)

        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: inputBuffer.mutableAudioBufferList) == noErr
        else { return nil }

        if converter == nil || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio + 1)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return nil }

        // AVAudioConverter roept dit blok synchroon aan; de één-shot-vlag zit in een
        // referentie zodat de @Sendable-closure geen muterende var vangt.
        final class Once: @unchecked Sendable { var supplied = false }
        let once = Once()
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, status in
            if once.supplied {
                status.pointee = .noDataNow
                return nil
            }
            once.supplied = true
            status.pointee = .haveData
            return inputBuffer
        }
        guard error == nil, let channel = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(outputBuffer.frameLength)))
    }
}
