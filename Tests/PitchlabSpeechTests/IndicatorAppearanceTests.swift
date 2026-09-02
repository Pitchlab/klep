import Testing
@testable import PitchlabSpeech

/// Tests voor het uiterlijk van de luister-stip (PL-747).
///
/// De klacht: hij reageerde wel, maar te subtiel om iets aan te hebben. Wat hier
/// vastligt is dus niet "er is een stip" maar dat het verschil tussen stilte en
/// praten meetbaar is, en dat de rand daar níét in meegaat — die is het enige waaraan
/// je een witte stip op een licht bureaublad nog terugvindt.
///
/// Het tekenen zelf (`IndicatorDotView.draw`) vraagt een runloop en is een mensentest
/// (ROE §2); hier staat de vertaling niveau → maat en dekking.
@Suite struct IndicatorAppearanceTests {

    // MARK: Anderhalf keer zo groot

    @Test func silenceMapsToTheNewMinimum() {
        #expect(ListeningIndicatorModel().diameter(for: .silent) == 21)
    }

    @Test func fullLevelMapsToTheNewMaximum() {
        #expect(ListeningIndicatorModel().diameter(for: AudioLevel(1)) == 63)
    }

    /// 14→21 en 42→63: allebei precies anderhalf keer de oude waarde.
    @Test func bothEndsAreOneAndAHalfTimesTheOldSize() {
        let model = ListeningIndicatorModel()
        #expect(model.minDiameter == 14 * 1.5)
        #expect(model.maxDiameter == 42 * 1.5)
    }

    /// De grootste stand moet in het venster passen. Klemt `draw` hem af, dan zie je
    /// een afgesneden cirkel en dat leest als kapot.
    @Test func thePanelIsBigEnoughForTheLargestDot() {
        let needed = ListeningIndicatorModel().maxDiameter + ListeningIndicatorModel.outlineWidth
        #expect(needed <= 72)
    }

    // MARK: De vulling volgt het niveau

    @Test func fillOpacityRunsFromQuarterToThreeQuarters() {
        let model = ListeningIndicatorModel()
        #expect(model.fillOpacity(for: .silent) == 0.25)
        #expect(model.fillOpacity(for: AudioLevel(1)) == 0.75)
    }

    /// Het tegenhangertje van `diameterGrowsMonotonicallyWithLevel`: harder praten mag
    /// nooit een dóffere stip geven.
    @Test func fillOpacityGrowsMonotonicallyWithLevel() {
        let model = ListeningIndicatorModel()
        var previous = model.fillOpacity(for: .silent)
        for step in 1...10 {
            let next = model.fillOpacity(for: AudioLevel(Double(step) / 10))
            #expect(next > previous)
            previous = next
        }
    }

    /// Blijft binnen 0…1, ook als het niveau buiten bereik binnenkomt.
    @Test func fillOpacityStaysWithinBounds() {
        let model = ListeningIndicatorModel()
        for value in [-1.0, 0.0, 0.5, 1.0, 2.0] {
            let opacity = model.fillOpacity(for: AudioLevel(value))
            #expect(opacity >= 0 && opacity <= 1)
        }
    }

    // MARK: De outline doet juist niet mee

    /// De rand heeft één breedte en één dekking, los van het niveau. Zou hij meevervagen
    /// met de vulling, dan verdwijnt de stip alsnog op een wit bureaublad — precies wat
    /// deze taak moest oplossen.
    @Test func theOutlineDoesNotFollowTheLevel() {
        #expect(ListeningIndicatorModel.outlineWidth > 0)
        #expect(ListeningIndicatorModel.outlineOpacity > ListeningIndicatorModel.maxFillOpacity)
    }

    /// De rand blijft ook bij de kleinste stip een zichtbaar deel van de breedte.
    @Test func theOutlineIsVisibleAtTheSmallestDiameter() {
        let share = ListeningIndicatorModel.outlineWidth / ListeningIndicatorModel().minDiameter
        #expect(share >= 0.05)
    }
}
