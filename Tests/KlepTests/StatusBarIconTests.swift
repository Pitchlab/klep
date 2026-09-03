import Testing
@testable import Klep

/// Tests voor de statusbalk-glyphrij (`statusBarSymbols`): precies één mic-glyph in elke
/// combinatie van hands-free en app-state, met `waveform` die tijdens transcriberen die
/// ene mic vervangt in plaats van er een tweede naast te zetten (PL-947). De auto-enter-
/// pijl en de waarschuwingsdriehoek zijn geen microfoons en blijven ernaast staan.
///
/// Puur getest: `statusBarSymbols` raakt geen AppKit-runloop, dus dit draait in de gate.
/// Net als `MenuBarTests` importeert dit bestand bewust géén Foundation — `import Testing`
/// plus `import Foundation` triggert de cross-import overlay `_Testing_Foundation`, die in
/// de CLT-only toolchain ontbreekt.
@Suite struct StatusBarIconTests {

    /// De SF Symbols die als microfoon-glyph tellen: de mic-familie plus de `waveform` die
    /// de mic tijdens transcriberen vervangt. De auto-enter-pijl en de driehoek horen hier
    /// bewust niet bij — de test moet zien dat die niet als tweede mic meetellen.
    private func micGlyphs(_ symbols: [StatusSymbol]) -> [String] {
        symbols.map(\.systemName).filter { $0.hasPrefix("mic") || $0 == "waveform" }
    }

    private let allStates: [SpeechState] = [.idle, .listening, .transcribing]

    @Test func exactlyOneMicGlyphInEveryCombination() {
        for handsFree in [false, true] {
            for autoEnter in [false, true] {
                for state in allStates {
                    for missing in [false, true] {
                        let symbols = statusBarSymbols(
                            state: state,
                            status: HotkeyStatus(handsFree: handsFree, autoEnter: autoEnter),
                            permissionsMissing: missing)
                        #expect(
                            micGlyphs(symbols).count == 1,
                            "state=\(state) handsFree=\(handsFree) autoEnter=\(autoEnter) missing=\(missing)")
                    }
                }
            }
        }
    }

    @Test func remainingMicIsStatusSymbolsGlyphWhenNotTranscribing() {
        for state in [SpeechState.idle, .listening] {
            let off = statusBarSymbols(
                state: state,
                status: HotkeyStatus(handsFree: false, autoEnter: false),
                permissionsMissing: false)
            #expect(micGlyphs(off) == ["mic.slash"])

            let on = statusBarSymbols(
                state: state,
                status: HotkeyStatus(handsFree: true, autoEnter: false),
                permissionsMissing: false)
            #expect(micGlyphs(on) == ["mic.fill"])
        }
    }

    @Test func transcribingReplacesTheMicWithWaveform() {
        for handsFree in [false, true] {
            let symbols = statusBarSymbols(
                state: .transcribing,
                status: HotkeyStatus(handsFree: handsFree, autoEnter: false),
                permissionsMissing: false)
            #expect(micGlyphs(symbols) == ["waveform"])
        }
    }

    @Test func autoEnterArrowSurvivesAndIsNotCountedAsMic() {
        let symbols = statusBarSymbols(
            state: .idle,
            status: HotkeyStatus(handsFree: false, autoEnter: true),
            permissionsMissing: false)
        let arrows = symbols.map(\.systemName).filter { $0.hasPrefix("arrow") }
        #expect(arrows == ["arrow.turn.down.left"])
        #expect(micGlyphs(symbols).count == 1)
    }

    @Test func warningTriangleSurvivesAndIsNotCountedAsMic() {
        let symbols = statusBarSymbols(
            state: .idle,
            status: HotkeyStatus(handsFree: true, autoEnter: false),
            permissionsMissing: true)
        #expect(symbols.map(\.systemName).contains("exclamationmark.triangle.fill"))
        #expect(micGlyphs(symbols).count == 1)
    }
}
