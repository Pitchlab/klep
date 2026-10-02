/// Systeemgeluid dempen tijdens hands-free.
///
/// WAAROM. Muziek, een video of een meeting die uit de speakers komt gaat de microfoon
/// in en wordt meegetranscribeerd. Bij hands-free met VAD is dat erger dan bij
/// push-to-talk: de app luistert continu en pikt een YouTube-stem op als een uiting.
/// Dus dempen zodra de opname start, herstellen zodra hij stopt.
///
/// TWEE DETAILS DIE HET GOED MOET DOEN.
///  1. Was het systeem al gedempt vóór de opname, dan blijft het gedempt bij het
///     stoppen. De vorige stand wordt bewaard en teruggezet — niet onvoorwaardelijk
///     ontdempt, want dan zet je het geluid aan voor iemand die het bewust uit had.
///  2. Hands-free kan crashen of de app kan gedwongen afgesloten worden terwijl het
///     geluid gedempt staat; dan blijft de Mac stil zonder dat iemand weet waarom.
///     De bewaarde stand staat daarom op schijf (`SystemAudioStateStore`): een herstart
///     leest hem terug en herstelt via `restore()`, ook als de app niet netjes afsloot.
///
/// STANDAARD UIT (`SystemAudioMuteSetting`). Dit grijpt in op iets buiten de app, dus
/// het gebeurt alleen als de instelling aan staat.
///
/// Alle randen zijn protocollen zodat de logica headless te bewijzen is zonder
/// CoreAudio: `SystemAudioOutput` is de mute-laag, `SystemAudioStateStore` de
/// schijf. De productie-implementatie (`CoreAudioOutput`) hangt de echte
/// CoreAudio-laag eronder; die runtime is een mensentest, de logica draait in de gate.

import Foundation

// MARK: - Bewaarde stand

/// De uitvoerstand die vóór het dempen gold. `Codable` zodat hij op schijf overleeft
/// en een herstart na een crash hem terug kan zetten.
public struct SystemAudioSnapshot: Sendable, Equatable, Codable {
    /// Of de systeemuitvoer al gedempt was vóór de opname. Was hij dat, dan blijft hij
    /// gedempt bij het herstellen.
    public let muted: Bool

    public init(muted: Bool) { self.muted = muted }
}

// MARK: - Randen (injecteerbaar)

/// De systeemuitvoer: de mute-stand lezen en zetten. Protocol zodat de suite een
/// geheugen-implementatie injecteert zonder CoreAudio aan te raken.
public protocol SystemAudioOutput: Sendable {
    /// De huidige mute-stand, of `nil` als de uitvoer niet leesbaar is (geen apparaat,
    /// of het apparaat kent geen mute-eigenschap). `nil` telt bij het bewaren als
    /// "niet gedempt", zodat een herstel de uitvoer niet per ongeluk dempt.
    func isMuted() -> Bool?
    /// Zet de mute-stand. Een no-op als er geen uitvoerapparaat is.
    func setMuted(_ muted: Bool)
}

/// De schijf waarop de pre-mute-stand bewaard wordt zodat een herstart na een crash
/// hem terug kan zetten. Protocol zodat de suite hem in het geheugen houdt.
public protocol SystemAudioStateStore: Sendable {
    /// De bewaarde stand, of `nil` als er niets openstaat.
    func load() -> SystemAudioSnapshot?
    /// Bewaar een stand, of wis hem met `nil` zodra hersteld is.
    func save(_ snapshot: SystemAudioSnapshot?)
}

/// Dempt de systeemuitvoer voor de opname en herstelt hem daarna. Protocol zodat de
/// hands-free-keten hem test met een spy, zonder CoreAudio of schijf.
public protocol SystemAudioMuting: Sendable {
    /// Bewaar de huidige stand en demp de uitvoer. Was hij al gedempt, dan verandert er
    /// niets aan de uitvoer, maar wordt de stand wel bewaard zodat het herstel klopt.
    /// Een no-op als de instelling uit staat.
    func muteForRecording() async
    /// Herstel de bewaarde stand. Was de uitvoer vóór het dempen al gedempt, dan blijft
    /// hij gedempt. Zonder bewaarde stand: een no-op. Loopt ook als de instelling
    /// inmiddels uit staat, zodat een mid-sessie uitgezette instelling toch ontdempt.
    func restore() async
}

// MARK: - De instelling (standaard UIT)

/// Of het systeemgeluid gedempt moet worden tijdens de opname. Standaard UIT: dit
/// grijpt in op iets buiten de app. Een `enum` zonder cases — puur een namespace.
public enum SystemAudioMuteSetting {
    public static let defaultsKey = "pitchlab.speech.muteSystemAudioWhileRecording"

    /// De stand als er nog nooit iets is ingesteld: uit.
    public static let fallback = false

    /// De naam van de rij in het instellingenvenster.
    public static let settingsTitle = "Systeemgeluid dempen tijdens opname"

    /// De ingestelde stand, of `fallback` als de sleutel ontbreekt. `object(forKey:)`
    /// om "niet gezet" van "expliciet uit" te onderscheiden.
    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else { return fallback }
        return defaults.bool(forKey: defaultsKey)
    }

    public static func setEnabled(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: defaultsKey)
    }
}

// MARK: - Muter

/// De dempt-logica: bewaar-vóór-dempen en voorwaardelijk-herstellen, los van CoreAudio.
///
/// Een `actor` omdat de hands-free-actor hem tijdens de opname aanroept en de bewaarde
/// stand niet dubbel bewaard mag raken als demp en herstel elkaar kruisen.
public actor SystemAudioMuter: SystemAudioMuting {
    private let output: SystemAudioOutput
    private let store: SystemAudioStateStore
    /// Live gelezen zodat de instelling mid-sessie aan/uit kan zonder de keten te
    /// herstarten — dezelfde vorm als `autoEnter` in `HandsFreeController`.
    private let isEnabled: @Sendable () -> Bool

    public init(
        output: SystemAudioOutput,
        store: SystemAudioStateStore = UserDefaultsSystemAudioStateStore(),
        isEnabled: @escaping @Sendable () -> Bool
    ) {
        self.output = output
        self.store = store
        self.isEnabled = isEnabled
    }

    public func muteForRecording() {
        guard isEnabled() else { return }
        // Al een bewaarde stand? Dan liep er nog een demp (of een crash liet er een
        // staan); de nu-al-gedempte stand er niet overheen schrijven, anders raakt de
        // écht vorige stand kwijt en zou het herstel de uitvoer gedempt laten.
        if store.load() == nil {
            store.save(SystemAudioSnapshot(muted: output.isMuted() ?? false))
        }
        output.setMuted(true)
    }

    public func restore() {
        guard let snapshot = store.load() else { return }
        output.setMuted(snapshot.muted)
        store.save(nil)
    }
}

/// Geen dempen: de standaard in `HandsFreeController`, zodat de keten ongewijzigd
/// draait tot een aanroeper bewust een `SystemAudioMuter` injecteert (standaard UIT).
public struct NoSystemAudioMuting: SystemAudioMuting {
    public init() {}
    public func muteForRecording() async {}
    public func restore() async {}
}

// MARK: - Schijf-implementatie

/// Bewaart de pre-mute-stand in `UserDefaults` als één JSON-blob, zodat een herstart
/// na een crash hem terug kan lezen. `object(forKey:)`/`removeObject` zodat "niets
/// openstaand" (nil) ondubbelzinnig is.
public struct UserDefaultsSystemAudioStateStore: @unchecked Sendable, SystemAudioStateStore {
    private let defaults: UserDefaults
    private let key = "pitchlab.speech.systemAudio.preMuteState"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> SystemAudioSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SystemAudioSnapshot.self, from: data)
    }

    public func save(_ snapshot: SystemAudioSnapshot?) {
        guard let snapshot else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - CoreAudio-implementatie (productie)

#if canImport(CoreAudio)
import CoreAudio

/// Productie-uitvoer: leest en zet de mute-eigenschap van het standaard
/// uitvoerapparaat via CoreAudio. De live-weg raakt echte hardware en wordt met de
/// hand getest (mensentest), niet in de gate. Kent het apparaat geen mute-eigenschap,
/// dan geeft `isMuted()` `nil` en is `setMuted` een no-op — de keten dempt dan niet in
/// plaats van te raden.
public struct CoreAudioOutput: SystemAudioOutput {
    public init() {}

    private func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != AudioDeviceID(0) else { return nil }
        return deviceID
    }

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    public func isMuted() -> Bool? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return status == noErr ? (muted != 0) : nil
    }

    public func setMuted(_ muted: Bool) {
        guard let device = defaultOutputDevice() else { return }
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return }
        var value = UInt32(muted ? 1 : 0)
        let size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }
}
#endif
