import Testing
@testable import PitchlabSpeech

/// Bewijst de hands-free-bedrading (PL-739): de menubalk-app knoopte tot deze taak
/// geen enkel onderdeel aan elkaar; hands-free flipte alleen een boolean. Deze suite
/// draait de echte `HandsFreeController` met injecteerbare stubs (audio/transcriptie/
/// uitvoer) en meet dat een uiting via de keten tekst bij de uitvoerlaag oplevert, de
/// indicator zichtbaar is tijdens het luisteren, het model warm blijft, en een Return
/// alleen bij auto-enter aan volgt. Zonder microfoon, model of Accessibility.
///
/// Importeert bewust géén Foundation: stubs en drivers staan in
/// `MenuBarPipelineTestSupport.swift` (zie dat bestand voor de reden).
@Suite struct MenuBarPipelineTests {

    // MARK: - Uiting → uitvoerlaag

    /// Een uiting door de keten geeft het transcript bij de uitvoerlaag.
    @Test func utteranceReachesOutputLayer() async {
        let result = await MenuBarPipelineTestSupport.runWiring(
            events: [MenuBarPipelineTestSupport.utterance([0.1, 0.2, 0.3])],
            transcript: "hallo wereld",
            autoEnter: false)
        #expect(result.sinkCalls.count == 1)
        #expect(result.sinkCalls.first?.text == "hallo wereld")
    }

    /// Lege transcriptie (stilte) wordt niet naar de uitvoerlaag gestuurd.
    @Test func silenceIsSkipped() async {
        let result = await MenuBarPipelineTestSupport.runWiring(
            events: [MenuBarPipelineTestSupport.utterance([])],
            autoEnter: false)
        #expect(result.transcribeCount == 1)
        #expect(result.sinkCalls.isEmpty)
    }

    // MARK: - Indicator

    /// De indicator is zichtbaar tijdens het luisteren — gevoed met het echte
    /// audioniveau — en verborgen zodra hands-free uit gaat.
    @Test func indicatorVisibleWhileListeningHiddenAfter() async {
        let result = await MenuBarPipelineTestSupport.runWiring(
            events: [
                MenuBarPipelineTestSupport.level(0.5),
                MenuBarPipelineTestSupport.utterance([0.1]),
            ],
            autoEnter: false)
        #expect(result.indicatorShowCount == 1)
        #expect(result.levelsWhileVisible.contains(0.5))
        #expect(result.indicatorHideCount == 1)
        #expect(result.isListeningAfter == false)
    }

    /// De echte niveauberekening van `MicrophoneCapture`: RMS van stilte is 0, van een
    /// constant signaal gelijk aan de amplitude. De indicator krijgt dus een echt
    /// niveau, geen placeholder.
    @Test func rmsLevelReflectsAmplitude() {
        #expect(MicrophoneCapture.rmsLevel([]) == 0)
        #expect(MicrophoneCapture.rmsLevel([0, 0, 0]) == 0)
        #expect(MicrophoneCapture.rmsLevel([0.5, 0.5, 0.5]) == 0.5)
        #expect(MicrophoneCapture.rmsLevel([1, 1, 1]) == 1)
    }

    // MARK: - Auto-enter

    /// Auto-enter aan geeft de uitvoerlaag de Return-vlag; uit niet.
    @Test func autoEnterFlagFollowsTheToggle() async {
        let on = await MenuBarPipelineTestSupport.runWiring(
            events: [MenuBarPipelineTestSupport.utterance([0.1])], autoEnter: true)
        #expect(on.sinkCalls.first?.autoEnter == true)

        let off = await MenuBarPipelineTestSupport.runWiring(
            events: [MenuBarPipelineTestSupport.utterance([0.1])], autoEnter: false)
        #expect(off.sinkCalls.first?.autoEnter == false)
    }

    /// Op de echte `TextOutput`-laag: een Return komt alleen bij auto-enter aan, en
    /// pas als de keten hem apart stuurt.
    ///
    /// HERZIEN DOOR PL-746: de Return zat in `emit` en gaat nu via `emitReturn`, zodat
    /// de auto-enter-vertraging ertussen past. Tijdens die pauze staat de tekst er dus
    /// al zonder Return — dat is de eerste helft hieronder, en precies het gedrag waar
    /// de taak om begon.
    @Test func returnOnlyWhenAutoEnterOnTheRealOutputLayer() throws {
        let waiting = try MenuBarPipelineTestSupport.runTextOutputSink(text: "hoi", autoEnter: true)
        #expect(waiting.inserted == ["hoi"])
        #expect(waiting.returns == 0)

        let on = try MenuBarPipelineTestSupport.runTextOutputSink(
            text: "hoi", autoEnter: true, sendReturn: true)
        #expect(on.inserted == ["hoi"])
        #expect(on.returns == 1)

        let off = try MenuBarPipelineTestSupport.runTextOutputSink(text: "hoi", autoEnter: false)
        #expect(off.inserted == ["hoi"])
        #expect(off.returns == 0)
    }

    // MARK: - Model warm houden

    /// Het model laadt één keer, ook bij meerdere uitingen — niet per uiting.
    @Test func modelWarmsOnceAcrossUtterances() async {
        let result = await MenuBarPipelineTestSupport.runWiring(
            events: [
                MenuBarPipelineTestSupport.utterance([0.1]),
                MenuBarPipelineTestSupport.utterance([0.2]),
                MenuBarPipelineTestSupport.utterance([0.3]),
            ],
            autoEnter: false)
        #expect(result.warmUpCount == 1)
        #expect(result.transcribeCount == 3)
        #expect(result.sinkCalls.count == 3)
    }

    // MARK: - Geen stil falen (R9)

    /// Gooit de uitvoerlaag (ontbrekende Accessibility), dan faalt het niet stil: de
    /// fout landt in `lastError` en de indicator wordt netjes verborgen.
    @Test func outputErrorIsSurfacedNotSwallowed() async {
        let result = await MenuBarPipelineTestSupport.runWiring(
            events: [MenuBarPipelineTestSupport.utterance([0.1])],
            autoEnter: false,
            sinkFailsWith: .accessibilityNotAuthorized)
        #expect(result.sinkCalls.isEmpty)
        #expect(result.lastError != nil)
        #expect(result.indicatorHideCount == 1)
    }

    /// Het paneel toont een uitvoerfout onder de statusregel (R9).
    @Test func panelShowsErrorNotice() {
        let model = MenuBarPanelModel(errorNotice: "Geen Accessibility-toestemming")
        #expect(model.noticeLines().contains("⚠︎ Geen Accessibility-toestemming"))
    }
}
