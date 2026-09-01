import Testing
@testable import PitchlabSpeech

/// Bewijst de microfoontoestemmings-gate (PL-740): tot deze taak vroeg de app nooit
/// toestemming — `startRunning()` slaagde zonder prompt en leverde stilte. Deze suite
/// draait de echte `HandsFreeController` met een geïnjecteerde toestemmingsstub (geen
/// echte TCC) en meet dat een geweigerde toestemming de keten niet start en een melding
/// oplevert, en dat een toegestane toestemming hem wél start. De beslissingslogica van
/// `ensureAccess` wordt daarnaast los per stand nagelopen.
///
/// De systeemprompt echt zien is een mensentest (buiten de check). Importeert bewust
/// géén Foundation: stubs en drivers staan in `MicrophonePermissionTestSupport.swift`.
@Suite struct MicrophonePermissionTests {

    // MARK: - Gate: keten start wel/niet

    /// Geweigerde toestemming: de keten start niet, de audiobron wordt niet aangesproken,
    /// de indicator blijft weg en de reden landt in `lastError` (menu-melding).
    @Test func deniedPermissionStopsTheChainWithNotice() async {
        let result = await MicrophonePermissionTestSupport.runGate(status: .denied)
        #expect(result.started == false)
        #expect(result.audioStarted == false)
        #expect(result.indicatorShowCount == 0)
        #expect(result.lastError != nil)
    }

    /// `.restricted` (bv. ouderlijk toezicht) weigert net als `.denied`: geen opname,
    /// wel een melding.
    @Test func restrictedPermissionStopsTheChainWithNotice() async {
        let result = await MicrophonePermissionTestSupport.runGate(status: .restricted)
        #expect(result.started == false)
        #expect(result.audioStarted == false)
        #expect(result.lastError != nil)
    }

    /// Toegestane toestemming: de keten start en de audiobron wordt aangesproken; geen
    /// prompt nodig, geen melding.
    @Test func authorizedPermissionStartsTheChain() async {
        let result = await MicrophonePermissionTestSupport.runGate(status: .authorized)
        #expect(result.started == true)
        #expect(result.audioStarted == true)
        #expect(result.requestCount == 0)
        #expect(result.lastError == nil)
    }

    /// `.notDetermined` + prompt toegestaan: de aanvraag wordt gedaan (macOS toont de
    /// prompt) en de keten start.
    @Test func notDeterminedThenGrantedStartsTheChain() async {
        let result = await MicrophonePermissionTestSupport.runGate(
            status: .notDetermined, grantOnRequest: true)
        #expect(result.requestCount == 1)
        #expect(result.started == true)
        #expect(result.audioStarted == true)
    }

    /// `.notDetermined` + prompt geweigerd: de aanvraag wordt gedaan, maar de keten
    /// start niet en er komt een melding.
    @Test func notDeterminedThenDeniedStopsTheChain() async {
        let result = await MicrophonePermissionTestSupport.runGate(
            status: .notDetermined, grantOnRequest: false)
        #expect(result.requestCount == 1)
        #expect(result.started == false)
        #expect(result.audioStarted == false)
        #expect(result.lastError != nil)
    }

    // MARK: - ensureAccess: beslissingslogica per stand

    /// Toegestaan levert `granted` zonder aanvraag.
    @Test func ensureAccessGrantsWhenAuthorized() async {
        let outcome = await MicrophonePermissionTestSupport.outcome(status: .authorized)
        #expect(outcome == .granted)
    }

    /// Geweigerd en beperkt leveren `denied` met een reden.
    @Test func ensureAccessDeniesWhenDeniedOrRestricted() async {
        let denied = await MicrophonePermissionTestSupport.outcome(status: .denied)
        let restricted = await MicrophonePermissionTestSupport.outcome(status: .restricted)
        #expect(denied == .denied(reason: AVCaptureMicrophonePermission.deniedNotice))
        #expect(restricted == .denied(reason: AVCaptureMicrophonePermission.deniedNotice))
    }

    /// `.notDetermined` volgt het antwoord op de prompt.
    @Test func ensureAccessFollowsThePrompt() async {
        let granted = await MicrophonePermissionTestSupport.outcome(
            status: .notDetermined, grantOnRequest: true)
        let refused = await MicrophonePermissionTestSupport.outcome(
            status: .notDetermined, grantOnRequest: false)
        #expect(granted == .granted)
        #expect(refused == .denied(reason: AVCaptureMicrophonePermission.deniedNotice))
    }

    // MARK: - Paneel-route (dezelfde als PL-739)

    /// De weigering-reden verschijnt onder de statusregel in het paneel via dezelfde
    /// `errorNotice`-route die PL-739 voor Accessibility gebruikt.
    @Test func deniedReasonShowsInPanel() {
        let model = MenuBarPanelModel(errorNotice: AVCaptureMicrophonePermission.deniedNotice)
        #expect(model.noticeLines().contains("⚠︎ \(AVCaptureMicrophonePermission.deniedNotice)"))
    }
}
