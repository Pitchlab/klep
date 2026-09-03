/// Tekstuitvoer: het transcript verschijnt op twee bestemmingen, tegelijk
/// toegestaan — ingevoegd bij de cursor van het venster met focus, en op stdout.
///
/// Invoegen bij de cursor: **CGEvent met `keyboardSetUnicodeString`**, niet
/// pasteboard+Cmd-V. Reden:
/// - Geen pasteboard-clobber. Pasteboard+Cmd-V overschrijft het klembord van de
///   gebruiker; dat vraagt om opslaan-en-herstellen met race-gevoelige timing.
///   Een dicteer-app die elke uiting het klembord aanraakt is vervelend.
/// - Lengte-onafhankelijk. `keyboardSetUnicodeString` draagt de hele string in
///   één synthetische key-event, dus geen `for`-lus van één event per teken.
/// - Willekeurige unicode. De volledige UTF-16 string gaat mee (Nederlandse
///   leestekens, diakrieten), zonder afhankelijk te zijn van keyboard-layout of
///   van of de app Cmd-V op plakken heeft gebonden.
/// Beide routes vereisen Accessibility (TCC); dat verschil is er niet. Deze route
/// wint op de klembord- en robuustheidspunten.
///
/// De toetsaanslag-laag zit achter `KeystrokeInserter` zodat de invoeg-route te
/// testen is zonder echte events te posten — die vereisen Accessibility en horen
/// niet in een headless suite (rules-of-engagement §2). Het echt posten van
/// events is een mensentest.
///
/// Ontbrekende Accessibility-permissie geeft een expliciete `TextOutputError`,
/// nooit een stille mislukking: de cursor-route gooit voordat hij iets probeert.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif

/// Fouten die de tekstuitvoer expliciet naar buiten brengt.
public enum TextOutputError: Error, CustomStringConvertible, Equatable {
    /// Het proces heeft geen Accessibility-toestemming, dus toetsaanslagen posten
    /// mag niet. Geen stille mislukking: de aanroeper krijgt deze fout terug.
    case accessibilityNotAuthorized
    /// Het aanmaken van de synthetische toetsenbord-event mislukte (CGEventSource
    /// of CGEvent gaf nil terug).
    case eventCreationFailed

    public var description: String {
        switch self {
        case .accessibilityNotAuthorized:
            return "Geen Accessibility-toestemming: tekst kan niet bij de cursor "
                + "worden ingevoegd. Geef Klep toegang in "
                + "Systeeminstellingen → Privacy en beveiliging → Toegankelijkheid."
        case .eventCreationFailed:
            return "Kon de toetsenbord-event niet aanmaken (CGEvent gaf nil)."
        }
    }
}

/// Scheiding tussen twee opeenvolgende uitingen bij de cursor, zodat ze niet aan
/// elkaar plakken ('eindelijk.En werkt').
///
/// BESLIST (Erik, 2026-09-01): eindigt een uiting op een zinseinde (`.` `?` of `!`),
/// zet er dan ONVOORWAARDELIJK een spatie ACHTER — achteraan, niet vooraan. Reden: de
/// cursor staat daarna meteen goed om verder te typen, ook als er nooit een tweede
/// uiting komt. De Nederlandse afkortingspunt ('bijv.') gaat hierin mee — onderscheid
/// maken kost meer dan het oplevert. Dit is een cursor-keuze (waar staat de cursor),
/// dus alleen de cursor-route; stdout blijft verbatim (de aanroeper bepaalt de opmaak).
///
/// Met auto-enter aan volgt er al een Return achter de uiting; dan géén extra spatie,
/// anders staat er een spatie vóór de nieuwe regel.
public enum UtteranceSeparator {
    /// De tekens die het einde van een zin markeren: punt, vraagteken, uitroepteken.
    static let sentenceEndings: Set<Character> = [".", "?", "!"]

    /// True als `text` op een zinseinde eindigt.
    public static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return sentenceEndings.contains(last)
    }
}

/// Hoelang de app wacht tussen de ingevoegde tekst en de Return van auto-enter.
///
/// WAAROM DIT BESTAAT (Erik, eerste echte gebruik): auto-enter stuurde de Return
/// meteen achter het transcript aan, midden in een zin. Er zit nu een instelbare
/// pauze tussen, zodat je kunt doorpraten voordat de regel verstuurd wordt.
///
/// DIT IS NIET DE VAD-STILTE. `SilenceThreshold` bepaalt WANNEER een uiting als
/// afgerond geldt en getranscribeerd wordt; deze waarde bepaalt hoelang daarna de
/// Return uitblijft. Dicteren in een lopende tekst wil een korte knip en een lange
/// Return-vertraging, dus de twee staan los van elkaar en delen geen waarde.
///
/// Een `enum` zonder cases: puur een namespace met statics. Geen instantie, dus ook
/// geen Sendable-vraag als de hands-free-actor de waarde opvraagt.
public enum AutoEnterDelay {
    /// De ondergrens. Bewust boven nul: op nul is auto-enter terug bij het gedrag
    /// waar de klacht over ging, en dat moet je niet per ongeluk kunnen instellen.
    public static let minimum: TimeInterval = 0.2
    public static let maximum: TimeInterval = 5.0
    /// De waarde als er nog nooit iets is ingesteld.
    public static let fallback: TimeInterval = 1.5

    public static let defaultsKey = "pitchlab.speech.autoEnterDelaySeconds"

    /// Houdt een waarde binnen de grenzen. Ook op de leesroute toegepast, zodat een
    /// met de hand aangepaste plist de app niet buiten zijn bereik zet.
    public static func clamp(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, minimum), maximum)
    }

    /// De ingestelde waarde, of `fallback` als er niets staat. `double(forKey:)` geeft
    /// 0 voor een ontbrekende sleutel, en 0 is hier een geldige-ogende maar verkeerde
    /// waarde — vandaar `object(forKey:)` om "niet gezet" te onderscheiden.
    public static func stored(in defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.object(forKey: defaultsKey) != nil else { return fallback }
        return clamp(defaults.double(forKey: defaultsKey))
    }

    public static func store(_ seconds: TimeInterval, in defaults: UserDefaults = .standard) {
        defaults.set(clamp(seconds), forKey: defaultsKey)
    }

    /// De naam van de rij in het instellingenvenster.
    public static let settingsTitle = "Wachten voor Return"

    /// De waarde als tekst, door `SpeechFormat.seconds` — dezelfde ene formatter als de
    /// rest van het venster, zodat er geen `1.50s` naast `1,50s` ontstaat.
    public static func valueLabel(_ seconds: TimeInterval) -> String {
        SpeechFormat.seconds(clamp(seconds))
    }
}

/// De toetsaanslag-laag, achter een protocol zodat de invoeg-route te testen is
/// zonder echte events te posten (Accessibility/TCC — rules-of-engagement §2).
/// `Sendable` zodat `TextOutput` (en de `TextOutputSink` erboven) over actorgrenzen
/// mag reizen: de hands-free-keten draait in een actor.
public protocol KeystrokeInserter: Sendable {
    /// True zodra het proces Accessibility-toestemming heeft.
    var isAuthorized: Bool { get }
    /// Voegt `text` in bij de cursor van het venster met focus. Gooit
    /// `TextOutputError.accessibilityNotAuthorized` als de toestemming ontbreekt.
    func insert(_ text: String) throws
    /// Stuurt een Return bij de cursor (auto-enter na een afgeronde uiting).
    func insertReturn() throws
}

public extension KeystrokeInserter {
    /// Standaard-Return: een newline via `insert`. De echte CGEvent-route overschrijft
    /// dit met een Return-keycode zodat een chatvenster de invoer verstuurt.
    func insertReturn() throws { try insert("\n") }
}

/// Waarheen het transcript gaat. Beide tegelijk toegestaan.
public struct TextDestinations: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Invoegen bij de cursor van het venster met focus.
    public static let cursor = TextDestinations(rawValue: 1 << 0)
    /// Schrijven naar stdout.
    public static let standardOutput = TextDestinations(rawValue: 1 << 1)
    /// Beide bestemmingen tegelijk.
    public static let both: TextDestinations = [.cursor, .standardOutput]
}

/// Stuurt een transcript naar de gekozen bestemming(en). De cursor-route hangt
/// af van Accessibility en zit achter een injecteerbare `KeystrokeInserter`; de
/// stdout-route zit achter een injecteerbare schrijf-closure. Zo is `emit` te
/// testen zonder systeemtoestemming.
public struct TextOutput: Sendable {
    private let inserter: KeystrokeInserter
    private let writeStandardOutput: @Sendable (String) -> Void

    /// - Parameters:
    ///   - inserter: de toetsaanslag-laag. Standaard de echte CGEvent-route.
    ///   - writeStandardOutput: schrijft de string naar stdout. Standaard
    ///     `FileHandle.standardOutput`, verbatim (geen toegevoegde newline: de
    ///     aanroeper bepaalt de opmaak).
    public init(
        inserter: KeystrokeInserter = CGEventKeystrokeInserter(),
        writeStandardOutput: @escaping @Sendable (String) -> Void = { text in
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    ) {
        self.inserter = inserter
        self.writeStandardOutput = writeStandardOutput
    }

    /// Stuurt `text` naar `destinations`. Stdout gaat eerst en heeft geen
    /// toestemming nodig; als beide bestemmingen zijn gevraagd en Accessibility
    /// ontbreekt, is de tekst dus al op stdout geschreven vóór de fout. De
    /// cursor-route gooit `TextOutputError.accessibilityNotAuthorized` in plaats
    /// van stil te falen.
    ///
    /// Bij de cursor krijgt een uiting die op een zinseinde eindigt een spatie
    /// achteraan (tenzij `pressReturn`), zodat twee uitingen niet aan elkaar plakken —
    /// zie `UtteranceSeparator`. Stdout blijft verbatim.
    ///
    /// `suppressSeparator` onderdrukt die spatie zonder zelf een Return te sturen. Dat
    /// is de auto-enter-route sinds de Return een eigen aanroep werd (`emitReturn`):
    /// de tekst gaat er nu meteen in, de Return pas na `AutoEnterDelay`. Zonder deze
    /// vlag zou er in die tussentijd een spatie achter de zin staan die vlak daarna
    /// vóór de nieuwe regel belandt.
    public func emit(
        _ text: String, to destinations: TextDestinations = .both, pressReturn: Bool = false,
        suppressSeparator: Bool = false
    ) throws {
        if destinations.contains(.standardOutput) {
            writeStandardOutput(text)
            if pressReturn { writeStandardOutput("\n") }
        }
        if destinations.contains(.cursor) {
            guard inserter.isAuthorized else {
                throw TextOutputError.accessibilityNotAuthorized
            }
            try inserter.insert(text)
            if pressReturn {
                try inserter.insertReturn()
            } else if !suppressSeparator && UtteranceSeparator.endsSentence(text) {
                // Zinseinde en geen auto-enter: een spatie erachter zodat de volgende
                // uiting niet aan deze plakt. Zie `UtteranceSeparator`.
                try inserter.insert(" ")
            }
        }
    }

    /// Stuurt alleen de Return, los van de tekst.
    ///
    /// Bestaat zodat de auto-enter-vertraging ergens kan zitten: de keten voegt de
    /// tekst in, wacht, en roept dit aan. Zat de Return nog in `emit`, dan kon de
    /// pauze alleen vóór de tekst of helemaal niet.
    public func emitReturn(to destinations: TextDestinations = .both) throws {
        if destinations.contains(.standardOutput) {
            writeStandardOutput("\n")
        }
        if destinations.contains(.cursor) {
            guard inserter.isAuthorized else {
                throw TextOutputError.accessibilityNotAuthorized
            }
            try inserter.insertReturn()
        }
    }
}

#if canImport(CoreGraphics) && canImport(ApplicationServices)
/// De echte invoeg-route: één synthetische key-down + key-up die de volledige
/// unicode-string draagt via `keyboardSetUnicodeString`. Geen pasteboard, dus
/// geen clobber; één event ongeacht de lengte. Zie de bestand-doc-comment voor de
/// keuze CGEvent boven pasteboard+Cmd-V.
///
/// Niet in de testsuite: `post(tap:)` levert echte toetsaanslagen aan het systeem
/// en vereist Accessibility. Mensentest.
public struct CGEventKeystrokeInserter: KeystrokeInserter {
    public init() {}

    /// `AXIsProcessTrusted()` — of het proces in de Accessibility-lijst staat en
    /// aangevinkt is. Kan zichzelf niet toekennen (TCC).
    public var isAuthorized: Bool { AXIsProcessTrusted() }

    public func insert(_ text: String) throws {
        guard isAuthorized else { throw TextOutputError.accessibilityNotAuthorized }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw TextOutputError.eventCreationFailed
        }
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            throw TextOutputError.eventCreationFailed
        }
        let utf16 = Array(text.utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Stuurt een echte Return: virtuele keycode 36 (kVK_Return), zodat een
    /// chatvenster de zojuist ingevoegde uiting verstuurt (auto-enter).
    public func insertReturn() throws {
        guard isAuthorized else { throw TextOutputError.accessibilityNotAuthorized }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw TextOutputError.eventCreationFailed
        }
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        else {
            throw TextOutputError.eventCreationFailed
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
#endif
