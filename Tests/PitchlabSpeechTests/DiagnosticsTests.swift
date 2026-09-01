import Testing
@testable import PitchlabSpeech

/// Bewijst de diagnostiek (PL-743): tot deze taak was de app blind — in een .app gaat
/// stdout nergens heen, er is geen logbestand, en elke diagnose was gokken. Deze suite
/// meet drie dingen:
///  - de gebeurtenis draagt de juiste regel en ernst, en logt lengtes/tijden, nooit
///    transcript-inhoud;
///  - het logbestand schrijft de regels en kapt af (één generatie rotatie) zodat het
///    niet volloopt, en de diagnostiek-schakelaar leest de omgeving;
///  - de echte `HandsFreeController` schrijft de keten (permissie, apparaat, uiting,
///    transcript, uitvoer, fout) naar een geïnjecteerde afvoer — dezelfde regels die
///    PL-740 en PL-742 in een halve seconde zichtbaar hadden gemaakt.
///
/// Importeert bewust géén Foundation: bestand- en ketenhulp staat in
/// `DiagnosticsTestSupport.swift` (zie `Fixtures.swift` voor de reden).
@Suite struct DiagnosticsTests {

    // MARK: - Gebeurtenis: regel + ernst

    /// Elke case levert de verwachte regel; alleen `failure` is een fout.
    @Test func eventLinesAndLevels() {
        #expect(DiagnosticEvent.handsFreeOn(reason: "menu").line == "hands-free aan (menu)")
        #expect(DiagnosticEvent.handsFreeOff(reason: "sneltoets").line == "hands-free uit (sneltoets)")
        #expect(DiagnosticEvent.handsFreeRestored(on: true).line
            == "hands-free herstelde stand bij opstarten: aan")
        #expect(DiagnosticEvent.deviceSelected(name: nil).line == "apparaat gekozen: (systeemstandaard)")
        #expect(DiagnosticEvent.deviceSelected(name: "Studio").line == "apparaat gekozen: Studio")
        #expect(DiagnosticEvent.permission(kind: "microfoon", status: "toegestaan").line
            == "permissie microfoon: toegestaan")
        #expect(DiagnosticEvent.utteranceDetected(durationMs: 200).line
            == "uiting gedetecteerd, duur 200 ms")
        #expect(DiagnosticEvent.output(route: "cursor+stdout", succeeded: false).line
            == "uitvoer cursor+stdout: mislukt")

        #expect(DiagnosticEvent.permission(kind: "microfoon", status: "toegestaan").level == .info)
        #expect(DiagnosticEvent.failure(origin: "tekstuitvoer", message: "x").level == .error)
    }

    /// GEEN inhoud: de transcript-gebeurtenis draagt alleen aantal tekens en tijd, de
    /// tekst zelf staat er niet in — de case kan hem niet dragen.
    @Test func transcriptEventLogsLengthAndTimeNeverContent() {
        let line = DiagnosticEvent.transcribed(characters: 10, elapsedMs: 50).line
        #expect(line == "transcript 10 tekens in 50 ms")
    }

    // MARK: - Diagnostiek-schakelaar

    /// `--diagnostics` in de argumenten zet de stderr-spiegel aan.
    @Test func diagnosticsFlagEnables() {
        #expect(DiagnosticLog.diagnosticsEnabled(environment: [:], arguments: ["app", "--diagnostics"]))
    }

    /// De env-variabele: een echte waarde zet aan, `0`/`false`/leeg/afwezig niet.
    @Test func diagnosticsEnvParsing() {
        #expect(DiagnosticLog.diagnosticsEnabled(environment: ["PITCHLAB_SPEECH_DIAG": "1"], arguments: []))
        #expect(DiagnosticLog.diagnosticsEnabled(environment: ["PITCHLAB_SPEECH_DIAG": "yes"], arguments: []))
        #expect(!DiagnosticLog.diagnosticsEnabled(environment: ["PITCHLAB_SPEECH_DIAG": "0"], arguments: []))
        #expect(!DiagnosticLog.diagnosticsEnabled(environment: ["PITCHLAB_SPEECH_DIAG": "false"], arguments: []))
        #expect(!DiagnosticLog.diagnosticsEnabled(environment: ["PITCHLAB_SPEECH_DIAG": ""], arguments: []))
        #expect(!DiagnosticLog.diagnosticsEnabled(environment: [:], arguments: []))
    }

    // MARK: - Logbestand

    /// Het bestand krijgt per gebeurtenis één regel met de ernst en de tekst.
    @Test func fileWritesOneLinePerEvent() {
        let contents = DiagnosticsTestSupport.writeAndRead([
            .handsFreeOn(reason: "menu"),
            .failure(origin: "tekstuitvoer", message: "geen toegang"),
        ])
        #expect(contents.contains("INFO hands-free aan (menu)"))
        #expect(contents.contains("ERROR fout in tekstuitvoer: geen toegang"))
        let lineCount = contents.split(separator: "\n", omittingEmptySubsequences: true).count
        #expect(lineCount == 2)
    }

    /// Bij overschrijding van `maxBytes` roteert het bestand één keer: het huidige bestand
    /// is afgekapt en `.1` bestaat — het log loopt niet vol.
    @Test func fileRotatesWhenOverMaxBytes() {
        let result = DiagnosticsTestSupport.rotate(lineCount: 60, maxBytes: 200)
        #expect(result.rotatedExists)
        #expect(result.currentLineCount < 60)
    }

    // MARK: - Keten (bedrading in HandsFreeController)

    /// Een toegestane run door één uiting logt de hele keten in volgorde: permissie,
    /// apparaat, uiting met duur, transcript-lengte, en gelukte uitvoer.
    @Test func chainLogsFullSequenceOnSuccess() async {
        let events = await DiagnosticsTestSupport.chainEvents(transcript: "hallo daar")
        #expect(events.count == 5)
        #expect(events[0] == .permission(kind: "microfoon", status: "toegestaan"))
        #expect(events[1] == .deviceSelected(name: nil))
        #expect(events[2] == .utteranceDetected(durationMs: 200))
        if case .transcribed(let characters, _) = events[3] {
            #expect(characters == 10)
        } else {
            Issue.record("verwachtte een transcribed-gebeurtenis, kreeg \(events[3])")
        }
        #expect(events[4] == .output(route: "cursor+stdout", succeeded: true))
    }

    /// Een falende uitvoer valt luid: de mislukt-route en de fout met zijn plek staan
    /// beide in de log (R9, geen stil falen).
    @Test func chainLogsFailingOutputLoudly() async {
        let events = await DiagnosticsTestSupport.chainEvents(transcript: "test", emitFails: true)
        #expect(events.contains(.output(route: "cursor+stdout", succeeded: false)))
        let hasFailure = events.contains { event in
            if case .failure(let origin, _) = event { return origin == "tekstuitvoer" }
            return false
        }
        #expect(hasFailure)
    }

    /// Geweigerde microfoontoestemming logt de status en de fout met zijn plek in plaats
    /// van stil stilte te leveren (PL-740). De keten start niet, dus geen uiting-regels.
    @Test func chainLogsDeniedPermission() async {
        let events = await DiagnosticsTestSupport.chainEvents(status: .denied)
        #expect(events.contains(.permission(kind: "microfoon", status: "geweigerd")))
        let deniedFailure = events.contains { event in
            if case .failure(let origin, _) = event { return origin == "microfoontoestemming" }
            return false
        }
        #expect(deniedFailure)
        #expect(!events.contains { if case .utteranceDetected = $0 { return true }; return false })
    }
}
