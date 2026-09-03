import Testing
@testable import Klep

/// Bewijst de luister-modus (PL-741): `klep --listen` zet hands-free aan en
/// `klep --listen=off` weer uit, via dezelfde `HandsFreeController` en dezelfde stand als
/// het menubalk-item — geen tweede keten (de fout van PIT-900). De suite draait de keten
/// met de bestaande stubs (audio/transcriptie/uitvoer), meet dat een uiting via de keten
/// bij de uitvoerlaag landt, dat de gedeelde stand aan- en na afloop weer uitgaat, dat een
/// geweigerde microfoon de start weigert (PL-740) en dat elk transcript een eigen regel op
/// stdout krijgt. Zonder microfoon, model of Accessibility.
///
/// Importeert bewust géén Foundation: `import Testing` samen met `import Foundation` in één
/// bestand triggert de cross-import overlay `_Testing_Foundation`, die ontbreekt in de
/// CLT-only toolchain (zie `MenuBarPipelineTests.swift`). De Foundation-stubs staan in de
/// bestaande support-bestanden; de dubbels hier gebruiken alleen de stdlib.
@Suite struct ListenModeTests {

    // MARK: - Dubbels (alleen stdlib, geen Foundation)

    /// Geheugen-store voor de gedeelde hands-free-stand. Onthoudt élke schrijfactie zodat
    /// de test ziet dat `turnOn` de stand aan- en daarna weer uitzet.
    final class MemoryHandsFreeState: HandsFreeStateStore, @unchecked Sendable {
        private(set) var writes: [Bool] = []
        func setHandsFreeOn(_ on: Bool) { writes.append(on) }
        func isHandsFreeOn() -> Bool { writes.last ?? false }
    }

    /// Verzamelt wat `StandardOutputLineSink` naar stdout zou schrijven.
    final class LineCollector: @unchecked Sendable {
        private(set) var lines: [String] = []
        func append(_ line: String) { lines.append(line) }
    }

    // MARK: - Argument-parsing

    @Test func parsesListenFlagVariants() {
        #expect(ListenArgument.parse([]) == .absent)
        #expect(ListenArgument.parse(["--once", "x.wav"]) == .absent)
        #expect(ListenArgument.parse(["--listen"]) == .on)
        #expect(ListenArgument.parse(["--listen=on"]) == .on)
        #expect(ListenArgument.parse(["--listen=off"]) == .off)
        #expect(ListenArgument.parse(["--listen=bogus"]) == .invalid("bogus"))
    }

    // MARK: - Uit: alleen de stand, geen opname

    @Test func turnOffSetsSharedStateOff() {
        let state = MemoryHandsFreeState()
        state.setHandsFreeOn(true)
        ListenMode(state: state).turnOff()
        #expect(state.isHandsFreeOn() == false)
        #expect(state.writes == [true, false])
    }

    // MARK: - Aan: dezelfde keten, dezelfde stand

    /// Een uiting door de keten landt bij de uitvoerlaag — dezelfde `HandsFreeController`
    /// als het menu, alleen met CLI-randen. De stand gaat aan en na afloop weer uit.
    @Test func turnOnDrivesControllerAndTogglesSharedState() async {
        let state = MemoryHandsFreeState()
        let sink = MenuBarPipelineTestSupport.RecordingSink()
        let controller = HandsFreeController(
            audio: MenuBarPipelineTestSupport.StubAudioSource(
                events: [MenuBarPipelineTestSupport.utterance([0.1, 0.2])]),
            transcriber: MenuBarPipelineTestSupport.StubTranscriber(text: "hallo wereld"),
            sink: sink,
            indicator: SilentListeningIndicator(),
            permission: MicrophonePermissionTestSupport.StubPermission(status: .authorized),
            autoEnter: { false })

        let started = await ListenMode(state: state).turnOn(controller: controller, device: nil)

        #expect(started == true)
        #expect(sink.calls.count == 1)
        #expect(sink.calls.first?.text == "hallo wereld")
        #expect(state.writes == [true, false])
    }

    /// Geen microfoontoestemming (PL-740): de keten start niet, de audiobron wordt nooit
    /// aangesproken, en `turnOn` geeft `false` zodat de CLI een niet-0 exit kan geven. De
    /// stand gaat weer uit — er luistert niets.
    @Test func turnOnRefusesWithoutMicrophonePermission() async {
        let state = MemoryHandsFreeState()
        let audio = MicrophonePermissionTestSupport.SpyAudioSource()
        let controller = HandsFreeController(
            audio: audio,
            transcriber: MicrophonePermissionTestSupport.NoopTranscriber(),
            sink: MicrophonePermissionTestSupport.NoopSink(),
            indicator: SilentListeningIndicator(),
            permission: MicrophonePermissionTestSupport.StubPermission(status: .denied),
            autoEnter: { false })

        let started = await ListenMode(state: state).turnOn(controller: controller, device: nil)

        #expect(started == false)
        #expect(audio.startCalled == false)
        #expect(state.writes == [true, false])
    }

    // MARK: - Stdout: regel per uiting

    /// `StandardOutputLineSink` schrijft elk transcript als één regel; twee uitingen door
    /// de keten geven twee regels, elk afgesloten met een newline.
    @Test func standardOutputSinkWritesOneLinePerUtterance() async {
        let collector = LineCollector()
        let controller = HandsFreeController(
            audio: MenuBarPipelineTestSupport.StubAudioSource(events: [
                MenuBarPipelineTestSupport.utterance([0.1]),
                MenuBarPipelineTestSupport.utterance([0.2]),
            ]),
            transcriber: MenuBarPipelineTestSupport.StubTranscriber(text: "regel"),
            sink: StandardOutputLineSink(write: { collector.append($0) }),
            indicator: SilentListeningIndicator(),
            permission: MicrophonePermissionTestSupport.StubPermission(status: .authorized),
            autoEnter: { false })

        await controller.run(device: nil)

        #expect(collector.lines == ["regel\n", "regel\n"])
    }

    /// Met `--auto-enter` volgt na de uiting een losse Return: een tweede regeleinde,
    /// dezelfde Return-logica als het menu geeft op de cursor.
    @Test func autoEnterAddsReturnLineOnStandardOutput() throws {
        let collector = LineCollector()
        let sink = StandardOutputLineSink(write: { collector.append($0) })
        try sink.emit("regel", autoEnter: true)
        try sink.emitReturn()
        #expect(collector.lines == ["regel\n", "\n"])
    }
}
