import Testing
@testable import PitchlabSpeech

/// Tests voor het dempen van het systeemgeluid tijdens hands-free (PL-766).
///
/// De klacht die deze taak opriep: muziek of een meeting uit de speakers gaat de
/// microfoon in en wordt meegetranscribeerd — bij VAD-hands-free erger dan bij
/// push-to-talk, want de app luistert continu. De kern is daarom niet "er is een
/// mute-schakelaar" maar dat de vorige stand bewaard en teruggezet wordt (was het al
/// gedempt, blijft het gedempt) en dat een crash de Mac niet stil achterlaat (de
/// bewaarde stand staat op schijf en herstelt bij de volgende start).
///
/// Alleen `import Testing`, geen `import Foundation`: samen in één bestand triggeren ze
/// de cross-import overlay `_Testing_Foundation` die in de CLT-only toolchain ontbreekt
/// (zie `Fixtures.swift`). De spies hieronder gebruiken daarom geen Foundation; de
/// keten-stubs komen uit de bestaande support-bestanden.
@Suite struct SystemAudioMuteTests {

    // MARK: - Spies (geen Foundation)

    /// Geheugen-uitvoer: onthoudt de mute-stand en telt de zet-aanroepen, zonder
    /// CoreAudio. `@unchecked Sendable` omdat de muter-actor de aanroepen serialiseert
    /// en de test pas ná `await` leest — geen gelijktijdige toegang.
    final class SpyOutput: SystemAudioOutput, @unchecked Sendable {
        private var muted: Bool?
        private(set) var setCalls: [Bool] = []
        init(muted: Bool?) { self.muted = muted }
        func isMuted() -> Bool? { muted }
        func setMuted(_ value: Bool) { muted = value; setCalls.append(value) }
        var current: Bool? { muted }
    }

    /// Geheugen-schijf: houdt de bewaarde stand vast zonder UserDefaults.
    final class MemoryStore: SystemAudioStateStore, @unchecked Sendable {
        private var snapshot: SystemAudioSnapshot?
        init(_ snapshot: SystemAudioSnapshot? = nil) { self.snapshot = snapshot }
        func load() -> SystemAudioSnapshot? { snapshot }
        func save(_ value: SystemAudioSnapshot?) { snapshot = value }
        var stored: SystemAudioSnapshot? { snapshot }
    }

    /// Muter-spy voor de keten-tests: onthoudt de volgorde van demp en herstel.
    final class SpyMuter: SystemAudioMuting, @unchecked Sendable {
        private(set) var events: [String] = []
        func muteForRecording() async { events.append("mute") }
        func restore() async { events.append("restore") }
    }

    // MARK: - Muter-logica

    @Test func mutesAndSavesPriorState() async {
        let output = SpyOutput(muted: false)
        let store = MemoryStore()
        let muter = SystemAudioMuter(output: output, store: store, isEnabled: { true })

        await muter.muteForRecording()
        #expect(output.current == true)
        #expect(store.stored == SystemAudioSnapshot(muted: false))

        await muter.restore()
        #expect(output.current == false)   // teruggezet naar de stand van vóór het dempen
        #expect(store.stored == nil)       // niets meer openstaand
    }

    /// Het detail van SpeechButton: was het systeem al gedempt vóór de opname, dan zet
    /// de app het niet aan bij het stoppen. De bewaarde stand is `muted: true`, dus het
    /// herstel dempt weer.
    @Test func staysMutedIfAlreadyMutedBeforeRecording() async {
        let output = SpyOutput(muted: true)
        let store = MemoryStore()
        let muter = SystemAudioMuter(output: output, store: store, isEnabled: { true })

        await muter.muteForRecording()
        #expect(store.stored == SystemAudioSnapshot(muted: true))

        await muter.restore()
        #expect(output.current == true)
    }

    /// Standaard uit: met de instelling uit raakt de muter de uitvoer niet aan en
    /// bewaart hij niets.
    @Test func disabledIsANoOp() async {
        let output = SpyOutput(muted: false)
        let store = MemoryStore()
        let muter = SystemAudioMuter(output: output, store: store, isEnabled: { false })

        await muter.muteForRecording()
        #expect(output.setCalls.isEmpty)
        #expect(store.stored == nil)
    }

    @Test func restoreWithoutSnapshotIsANoOp() async {
        let output = SpyOutput(muted: false)
        let muter = SystemAudioMuter(output: output, store: MemoryStore(), isEnabled: { true })

        await muter.restore()
        #expect(output.setCalls.isEmpty)
    }

    /// Een tweede demp mag de echte vorige stand niet overschrijven met de nu-gedempte
    /// stand, anders zou het herstel de uitvoer gedempt laten.
    @Test func secondMuteKeepsTheFirstSnapshot() async {
        let output = SpyOutput(muted: false)
        let store = MemoryStore()
        let muter = SystemAudioMuter(output: output, store: store, isEnabled: { true })

        await muter.muteForRecording()   // bewaart muted:false, dempt
        await muter.muteForRecording()   // uitvoer staat nu gedempt: niet overschrijven
        #expect(store.stored == SystemAudioSnapshot(muted: false))

        await muter.restore()
        #expect(output.current == false)
    }

    /// Crash-herstel: de vorige run bewaarde de stand maar herstelde niet (crash of
    /// force-quit), dus de uitvoer staat nog gedempt en de schijf houdt de pre-mute-stand.
    /// Bij de volgende start herstelt `restore()` hem — ook met de instelling uit, want
    /// anders blijft de Mac stil zonder dat iemand weet waarom.
    @Test func restoresPersistedStateAfterCrash() async {
        let output = SpyOutput(muted: true)
        let store = MemoryStore(SystemAudioSnapshot(muted: false))
        let muter = SystemAudioMuter(output: output, store: store, isEnabled: { false })

        await muter.restore()
        #expect(output.current == false)
        #expect(store.stored == nil)
    }

    /// Standaard UIT: dit grijpt in op iets buiten de app.
    @Test func settingDefaultsOff() {
        #expect(SystemAudioMuteSetting.fallback == false)
    }

    // MARK: - Bedrading in de keten

    /// De keten dempt zodra de opname start en herstelt zodra hij stopt, in die volgorde.
    @Test func controllerMutesOnStartAndRestoresOnStop() async {
        let muter = SpyMuter()
        let controller = HandsFreeController(
            audio: MicrophonePermissionTestSupport.SpyAudioSource(),
            transcriber: MicrophonePermissionTestSupport.NoopTranscriber(),
            sink: MicrophonePermissionTestSupport.NoopSink(),
            indicator: ListeningIndicator(),
            permission: MicrophonePermissionTestSupport.StubPermission(status: .authorized),
            autoEnter: { false },
            systemAudio: muter)

        let started = await controller.run(device: nil)
        #expect(started)
        #expect(muter.events == ["mute", "restore"])
    }

    /// Geweigerde microfoontoestemming: de keten start niet, dus er wordt niet gedempt —
    /// anders bleef de uitvoer gedempt voor een opname die nooit begon.
    @Test func deniedPermissionSkipsMuting() async {
        let muter = SpyMuter()
        let controller = HandsFreeController(
            audio: MicrophonePermissionTestSupport.SpyAudioSource(),
            transcriber: MicrophonePermissionTestSupport.NoopTranscriber(),
            sink: MicrophonePermissionTestSupport.NoopSink(),
            indicator: ListeningIndicator(),
            permission: MicrophonePermissionTestSupport.StubPermission(status: .denied),
            autoEnter: { false },
            systemAudio: muter)

        let started = await controller.run(device: nil)
        #expect(!started)
        #expect(muter.events.isEmpty)
    }
}
