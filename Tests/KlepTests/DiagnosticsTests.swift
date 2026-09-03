import Testing
@testable import Klep

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

    /// GEEN inhoud, ook in de JSON-vorm: de transcript-gebeurtenis draagt alleen aantal
    /// tekens en tijd — als getal — en de tekst zelf staat er niet in; de case kan hem niet
    /// dragen. De privacyregel geldt op het record, niet alleen op de zin.
    @Test func transcriptEventLogsLengthAndTimeNeverContent() {
        #expect(DiagnosticEvent.transcribed(characters: 10, elapsedMs: 50).line == "transcript 10 tekens in 50 ms")
        let record = DiagnosticsTestSupport.decodeTranscribed(
            characters: 10, elapsedMs: 50, secret: "geheime woorden")
        #expect(record.decoded)
        #expect(record.event == "transcribed")
        #expect(record.characters == 10)
        #expect(record.elapsedMs == 50)
        #expect(!record.containsSecret)
    }

    /// De machine-namen zijn het contract en veranderen niet met de zin.
    @Test func eventNamesAreStable() {
        #expect(DiagnosticEvent.handsFreeOn(reason: "x").name == "hands_free_on")
        #expect(DiagnosticEvent.handsFreeOff(reason: "x").name == "hands_free_off")
        #expect(DiagnosticEvent.handsFreeRestored(on: true).name == "hands_free_restored")
        #expect(DiagnosticEvent.deviceSelected(name: nil).name == "device_selected")
        #expect(DiagnosticEvent.permission(kind: "m", status: "s").name == "permission")
        #expect(DiagnosticEvent.utteranceDetected(durationMs: 1).name == "utterance_detected")
        #expect(DiagnosticEvent.transcribed(characters: 1, elapsedMs: 1).name == "transcribed")
        #expect(DiagnosticEvent.output(route: "r", succeeded: true).name == "output")
        #expect(DiagnosticEvent.failure(origin: "o", message: "m").name == "failure")
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

    /// Het bestand is JSONL: per gebeurtenis één regel die als JSON parseert, met de
    /// stabiele `event`-naam, `level`, de getypeerde velden en `msg` met de zin.
    @Test func fileWritesOneJSONRecordPerEvent() {
        let lines = DiagnosticsTestSupport.recordLines([
            .handsFreeOn(reason: "menu"),
            .failure(origin: "tekstuitvoer", message: "geen toegang"),
        ])
        #expect(lines.count == 2)
        #expect(lines.allSatisfy(DiagnosticsTestSupport.isJSON))
        #expect(lines[0].contains("\"event\":\"hands_free_on\""))
        #expect(lines[0].contains("\"reason\":\"menu\""))
        #expect(lines[0].contains("\"level\":\"INFO\""))
        #expect(lines[0].contains("\"msg\":\"hands-free aan (menu)\""))
        #expect(lines[1].contains("\"event\":\"failure\""))
        #expect(lines[1].contains("\"origin\":\"tekstuitvoer\""))
        #expect(lines[1].contains("\"message\":\"geen toegang\""))
        #expect(lines[1].contains("\"level\":\"ERROR\""))
    }

    /// Getallen staan als getal in het record, niet als string: een strikte decode van
    /// `characters` en `elapsed_ms` slaagt (een string zou gooien).
    @Test func numericFieldsAreTypedNumbers() {
        let record = DiagnosticsTestSupport.decodeTranscribed(characters: 10, elapsedMs: 50, secret: "x")
        #expect(record.decoded)
        #expect(record.characters == 10)
        #expect(record.elapsedMs == 50)
    }

    /// `succeeded` staat als boolean in het record: een strikte decode naar `Bool` slaagt
    /// voor beide standen.
    @Test func booleanFieldIsTypedBoolean() {
        let ok = DiagnosticsTestSupport.decodeOutput(route: "cursor+stdout", succeeded: true)
        #expect(ok.decoded)
        #expect(ok.event == "output")
        #expect(ok.route == "cursor+stdout")
        #expect(ok.succeeded)
        let failed = DiagnosticsTestSupport.decodeOutput(route: "cursor+stdout", succeeded: false)
        #expect(failed.decoded)
        #expect(!failed.succeeded)
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
    /// apparaat, de eerste sample, uiting met duur, transcript-lengte, en gelukte
    /// uitvoer.
    @Test func chainLogsFullSequenceOnSuccess() async {
        let events = await DiagnosticsTestSupport.chainEvents(transcript: "hallo daar")
        #expect(events.count == 6)
        #expect(events[0] == .permission(kind: "microfoon", status: "toegestaan"))
        #expect(events[1] == .deviceSelected(name: nil))
        // PL-765: de tijd tot de eerste sample. De waarde is een meting en dus niet te
        // pinnen; dát hij er staat, en vóór de eerste uiting, is wat hier telt.
        if case .captureReady = events[2] {} else {
            Issue.record("verwachtte capture_ready, kreeg \(events[2])")
        }
        #expect(events[3] == .utteranceDetected(durationMs: 200))
        if case .transcribed(let characters, _) = events[4] {
            #expect(characters == 10)
        } else {
            Issue.record("verwachtte een transcribed-gebeurtenis, kreeg \(events[4])")
        }
        #expect(events[5] == .output(route: "cursor+stdout", succeeded: true))
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
