import Testing
@testable import Klep

/// Bewijst de permissiesectie (PL-729): drie permissies (Microfoon, Toegankelijkheid,
/// Invoerbewaking) in één sectie, elk met live status, een eerlijke herstart-hint en een
/// knop naar het juiste Systeeminstellingen-paneel. De status wordt LIVE gelezen via een
/// geïnjecteerde stub (geen echte TCC): een omgezet vinkje moet kloppen zonder herstart.
/// Het echt openen van een Systeeminstellingen-paneel is een mensentest (buiten de check).
@Suite struct PermissionsScreenTests {

    // MARK: - Sectie-opbouw

    /// De sectie toont drie permissies in vaste volgorde met hun macOS-naam.
    @Test func modelHasThreePermissionsInFixedOrder() {
        let model = PermissionsModel(
            microphoneGranted: true, accessibilityGranted: true, inputMonitoringGranted: true)
        #expect(model.items.map(\.kind) == [.microphone, .accessibility, .inputMonitoring])
        #expect(model.items.map(\.title) == ["Microfoon", "Tekst-uitvoer", "Sneltoetsen"])
    }

    /// Elke permissie zegt wat er zonder werkt en niet werkt — geen lege effect-tekst.
    @Test func everyPermissionExplainsWhatBreaksWithoutIt() {
        for kind in PermissionKind.allCases {
            #expect(!kind.effect.isEmpty)
        }
    }

    // MARK: - Live status

    /// De statusstand volgt de geïnjecteerde booleans, met de juiste statustekst.
    @Test func statusMapsFromInjectedFlags() {
        let model = PermissionsModel(
            microphoneGranted: true, accessibilityGranted: false, inputMonitoringGranted: true)
        #expect(model.items[0].isGranted == true)
        #expect(model.items[0].statusLabel == "✓ toegestaan")
        #expect(model.items[1].isGranted == false)
        #expect(model.items[1].statusLabel == "⚠︎ ontbreekt")
    }

    /// Ontbreekt er één, dan meldt het model dat (voor het statusitem, zonder het menu).
    @Test func anyMissingReportsTheGapForTheStatusItem() {
        let complete = PermissionsModel(
            microphoneGranted: true, accessibilityGranted: true, inputMonitoringGranted: true)
        #expect(complete.anyMissing == false)
        #expect(complete.missingKinds.isEmpty)

        let gap = PermissionsModel(
            microphoneGranted: true, accessibilityGranted: false, inputMonitoringGranted: false)
        #expect(gap.anyMissing == true)
        #expect(gap.missingKinds == [.accessibility, .inputMonitoring])
    }

    /// De probe cachet niets: een vinkje dat na de eerste lezing omgaat, klopt bij de
    /// tweede lezing — precies de eis dat terugkomen zonder herstart moet werken.
    @Test func probeReadsLiveAndDoesNotCache() {
        let source = StubPermissionStatusSource(
            microphone: false, accessibility: false, inputMonitoring: false)
        let probe = PermissionsProbe(source: source)

        let before = probe.snapshot()
        #expect(before.anyMissing == true)
        #expect(before.items.allSatisfy { !$0.isGranted })

        source.microphone = true
        source.accessibility = true
        source.inputMonitoring = true

        let after = probe.snapshot()
        #expect(after.anyMissing == false)
        #expect(after.items.allSatisfy { $0.isGranted })
    }

    // MARK: - Herstart-hint (eerlijk per permissie)

    /// Microfoon vraagt geen herstart (de prompt werkt live); Toegankelijkheid en
    /// Invoerbewaking wel — de al draaiende client pakt de trust pas na een herstart.
    @Test func restartIsRequiredWhereItActuallyIs() {
        #expect(PermissionKind.microphone.requiresRestart == false)
        #expect(PermissionKind.accessibility.requiresRestart == true)
        #expect(PermissionKind.inputMonitoring.requiresRestart == true)
    }

    /// De herstart-hint verschijnt alleen zolang de permissie ontbreekt: gegeven zwijgt hij,
    /// zodat een dode hint nooit blijft staan.
    @Test func restartHintShowsOnlyWhileMissing() {
        let missing = PermissionItem(kind: .inputMonitoring, isGranted: false)
        #expect(missing.restartHint != nil)

        let granted = PermissionItem(kind: .inputMonitoring, isGranted: true)
        #expect(granted.restartHint == nil)

        let noRestart = PermissionItem(kind: .microphone, isGranted: false)
        #expect(noRestart.restartHint == nil)
    }

    // MARK: - Systeeminstellingen-knop

    /// Elke permissie richt zijn URL op zijn eigen Privacy-deelvenster; de drie ankers
    /// verschillen en de URL draagt het systeeminstellingen-schema. De knop opent zelf
    /// niets in de test — mensentest.
    @Test func settingsURLTargetsTheRightPane() {
        let anchors = PermissionKind.allCases.map(\.settingsAnchor)
        #expect(Set(anchors).count == PermissionKind.allCases.count)
        #expect(PermissionKind.microphone.settingsAnchor == "Privacy_Microphone")
        #expect(PermissionKind.accessibility.settingsAnchor == "Privacy_Accessibility")
        #expect(PermissionKind.inputMonitoring.settingsAnchor == "Privacy_ListenEvent")
        for kind in PermissionKind.allCases {
            #expect(kind.settingsURLString.hasPrefix("x-apple.systempreferences:"))
            #expect(kind.settingsURLString.contains(kind.settingsAnchor))
        }
    }

    // MARK: - Eerste start

    /// De sectie biedt zich alleen bij de eerste start aan; daarna niet meer.
    @Test func firstRunOffersOnceThenStopsOffering() {
        #expect(FirstRunGate.shouldOffer(hasLaunchedBefore: false) == true)
        #expect(FirstRunGate.shouldOffer(hasLaunchedBefore: true) == false)
    }
    // MARK: - Het bannertje voor het hoofdpaneel (PL-788)

    /// Alles gegeven: geen banner, en dus geen ruis in een paneel dat over dicteren gaat.
    @Test func bannerIsAbsentWhenEverythingIsGranted() {
        let model = PermissionsModel(
            microphoneGranted: true, accessibilityGranted: true, inputMonitoringGranted: true)
        #expect(model.bannerText == nil)
    }

    /// Eén ontbrekende permissie wordt bij naam genoemd — "een permissie ontbreekt" laat
    /// je zoeken.
    @Test func bannerNamesTheSingleMissingPermission() {
        let model = PermissionsModel(
            microphoneGranted: true, accessibilityGranted: false, inputMonitoringGranted: true)
        #expect(model.bannerText == "Tekst-uitvoer ontbreekt.")
    }

    /// Meerdere ontbrekende permissies staan in de vaste volgorde van de sectie.
    @Test func bannerListsSeveralMissingPermissionsInOrder() {
        let model = PermissionsModel(
            microphoneGranted: false, accessibilityGranted: true, inputMonitoringGranted: false)
        #expect(model.bannerText == "Ontbreekt: Microfoon, Sneltoetsen.")
    }
    // MARK: - De titel zegt waaróm, de systeemnaam waar je hem vindt

    /// De rij-titel noemt het nut, niet de macOS-term: "Toegankelijkheid" zegt niets over
    /// wat je eraan hebt.
    @Test func titlesNameThePurpose() {
        #expect(PermissionKind.microphone.title == "Microfoon")
        #expect(PermissionKind.accessibility.title == "Tekst-uitvoer")
        #expect(PermissionKind.inputMonitoring.title == "Sneltoetsen")
    }

    /// En de macOS-naam blijft bestaan, want zonder die term vind je het vinkje niet
    /// terug in Systeeminstellingen.
    @Test func systemNamesStayAvailableForFindingTheSetting() {
        #expect(PermissionKind.microphone.systemName == "Microfoon")
        #expect(PermissionKind.accessibility.systemName == "Toegankelijkheid")
        #expect(PermissionKind.inputMonitoring.systemName == "Invoerbewaking")
    }

    /// De toelichting noemt de macOS-naam ook, zodat hij in beeld staat zonder dat je
    /// een tooltip hoeft te openen.
    @Test func effectTextMentionsTheSystemName() {
        for kind in PermissionKind.allCases {
            #expect(kind.effect.contains(kind.systemName))
        }
    }
}
