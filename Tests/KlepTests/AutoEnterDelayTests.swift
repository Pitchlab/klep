import Testing
@testable import Klep

/// Tests voor de twee tijdregelaars (PL-746).
///
/// De klacht die deze taak opriep: auto-enter stuurde de Return midden in een zin.
/// De kern is daarom niet "er is een schuifregelaar" maar dat er ECHT twee losse
/// waarden zijn — de VAD-stilte die een uiting afkapt, en de wachttijd vóór de
/// Return — en dat de Return niet meer aan de tekst vastzit.
///
/// De regelaars staan in het instellingenvenster (Erik, 2026-09-02), niet in het
/// menubalk-paneel zoals de taak eerst zei. Dat venster vraagt een runloop en is een
/// mensentest (ROE §2); hier staat de logica eromheen. Foundation-werk staat in
/// `AutoEnterDelayTestSupport`, want `import Testing` + `import Foundation` in één
/// bestand breekt op de CLT-only toolchain.
@Suite struct AutoEnterDelayTests {

    /// Onthoudt wat er ingevoegd zou zijn. Eigen spy en niet die van `TextOutputTests`:
    /// die zit genest in dat suite-type en is hier niet bereikbaar.
    final class DelaySpyInserter: KeystrokeInserter, @unchecked Sendable {
        private(set) var inserted: [String] = []
        var isAuthorized: Bool { true }
        func insert(_ text: String) throws { inserted.append(text) }
        func insertReturn() throws { inserted.append("\n") }
    }

    // MARK: De twee waarden zijn echt gescheiden

    /// De hele reden van de taak: één waarde voor twee dingen was de fout. Verschillende
    /// sleutels, verschillende defaults, verschillende grenzen.
    @Test func thresholdsDoNotShareAKey() {
        let keys = AutoEnterDelayTestSupport.keys
        #expect(keys.autoEnter != keys.silence)
        #expect(AutoEnterDelay.fallback != SilenceThreshold.fallback)
    }

    /// De stiltedrempel schuift door naar de config die de segmenter echt gebruikt.
    /// Zonder deze stap is de regelaar een knop die nergens op zit.
    @Test func silenceThresholdReachesTheSegmenterConfig() {
        let result = AutoEnterDelayTestSupport.storeSilenceAndReadBack(1.4)
        #expect(result.readBack == 1.4)
        #expect(result.config == 1.4)
    }

    // MARK: Grenzen

    /// "Een verstandige ondergrens, zodat je hem niet per ongeluk op nul zet." Op nul
    /// is auto-enter terug bij het gedrag waar de klacht over ging.
    @Test func lowerBoundIsAboveZero() {
        #expect(AutoEnterDelay.minimum > 0)
        #expect(AutoEnterDelay.clamp(0) == AutoEnterDelay.minimum)
        #expect(AutoEnterDelay.clamp(-5) == AutoEnterDelay.minimum)
    }

    @Test func clampKeepsBothValuesInRange() {
        #expect(AutoEnterDelay.clamp(99) == AutoEnterDelay.maximum)
        #expect(AutoEnterDelay.clamp(1.0) == 1.0)
        #expect(SilenceThreshold.clamp(0) == SilenceThreshold.minimum)
        #expect(SilenceThreshold.clamp(99) == SilenceThreshold.maximum)
    }

    /// De default is FluidAudio's eigen waarde: niets instellen verandert het gedrag
    /// van vóór deze taak niet.
    @Test func silenceDefaultMatchesTheVadDefault() {
        #expect(SilenceThreshold.fallback == 0.75)
    }

    // MARK: Overleeft een herstart

    /// Criterium: de gekozen waarde overleeft een herstart van de app. Geschreven met
    /// de ene aanroep, teruggelezen alsof het proces opnieuw begon.
    @Test func storedValueSurvivesARestart() {
        let result = AutoEnterDelayTestSupport.storeAndReadBack(2.25)
        #expect(result.fallbackBeforeStore == AutoEnterDelay.fallback)
        #expect(result.readBack == 2.25)
    }

    /// Een met de hand aangepaste plist mag de app niet buiten zijn bereik zetten:
    /// ook op de leesroute wordt geklemd.
    @Test func storedValueIsClampedOnTheWayBackIn() {
        #expect(AutoEnterDelayTestSupport.storeAndReadBack(60).readBack == AutoEnterDelay.maximum)
    }

    // MARK: Het paneel draagt de waarden

    /// De waardelabels klemmen ook, zodat een met de hand aangepaste plist niet als
    /// `9,00s` in het venster verschijnt terwijl de keten 5,00s gebruikt.
    @Test func valueLabelsClampLikeTheStoredValue() {
        #expect(AutoEnterDelay.valueLabel(99) == SpeechFormat.seconds(AutoEnterDelay.maximum))
        #expect(SilenceThreshold.valueLabel(0) == SpeechFormat.seconds(SilenceThreshold.minimum))
    }

    /// De twee rijen in het instellingenvenster heten niet hetzelfde. Ze zijn allebei
    /// een tijd in seconden, en dezelfde naam zou ze weer op één hoop gooien.
    @Test func theTwoSettingsRowsHaveDistinctNames() {
        #expect(AutoEnterDelay.settingsTitle != SilenceThreshold.settingsTitle)
    }

    /// Beide regelaars lopen door `SpeechFormat.seconds`, de ene formatter die PL-764
    /// hiervoor neerzette. SpeechButton schrijft dezelfde waarde als `1.00s` in het
    /// paneel en `1,00s` in het venster omdat daar twee formatters staan; een tweede
    /// formatter erbij zetten zou die fout hier importeren.
    @Test func bothLabelsUseTheOneFormatter() {
        #expect(AutoEnterDelay.valueLabel(1.5) == SpeechFormat.seconds(1.5))
        #expect(SilenceThreshold.valueLabel(1.5) == SpeechFormat.seconds(1.5))
        // Vaste nl_NL-notatie: komma, twee decimalen. Beweegt niet met de systeemtaal.
        #expect(SpeechFormat.seconds(1.5) == "1,50s")
    }

    // MARK: De Return zit niet meer aan de tekst vast

    /// Met auto-enter aan gaat de tekst er meteen in, ZONDER Return en zonder de
    /// scheidingsspatie — die zou anders vóór de nieuwe regel belanden. De Return komt
    /// pas na de vertraging, via een eigen aanroep.
    @Test func autoEnterEmitsTextWithoutReturnOrTrailingSpace() throws {
        let inserter = DelaySpyInserter()
        let sink = TextOutputSink(
            output: TextOutput(inserter: inserter, writeStandardOutput: { _ in }),
            to: .cursor)

        try sink.emit("Klaar.", autoEnter: true)
        #expect(inserter.inserted == ["Klaar."])

        try sink.emitReturn()
        #expect(inserter.inserted == ["Klaar.", "\n"])
    }

    /// Met auto-enter uit blijft het oude gedrag staan: spatie achter een zinseinde,
    /// geen Return. Dat is de regel uit PL-744 en die mag deze taak niet slopen.
    @Test func withoutAutoEnterTheSeparatorSpaceStays() throws {
        let inserter = DelaySpyInserter()
        let sink = TextOutputSink(
            output: TextOutput(inserter: inserter, writeStandardOutput: { _ in }),
            to: .cursor)

        try sink.emit("Klaar.", autoEnter: false)
        #expect(inserter.inserted == ["Klaar.", " "])
    }
}
