/// Microfoontoestemming: lezen, aanvragen en de gate vóór de opname. Tot deze taak
/// vroeg de app nooit toestemming — `AVCaptureSession.startRunning()` slaagde zonder
/// prompt en leverde stilte: geen fout, geen samples, VAD zag nooit een uiting. Hier
/// wordt de toestemming eerst gecontroleerd en, bij `.notDetermined`, aangevraagd
/// zodat macOS de systeemprompt toont.
///
/// De hele beslissing zit achter `MicrophonePermission`, hetzelfde injecteerbare
/// patroon als de rest van de audio-invoer, zodat de suite hem test zonder echte TCC
/// (die per machine verschilt en niet vanuit een test te zetten is). De runtime-prompt
/// zelf is een mensentest; `ensureAccess` draagt de meetbare logica.
@preconcurrency import AVFoundation

// MARK: - Toestemmingsstand

/// De vier toestemmingsstanden voor de microfoon, losgekoppeld van AVFoundation zodat
/// de gate zonder echte TCC te testen is.
public enum MicrophoneAuthorization: Sendable, Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

/// Uitkomst van de gate vóór de opname: toegestaan, of geweigerd met de reden voor de
/// menu-melding.
public enum MicrophonePermissionOutcome: Sendable, Equatable {
    case granted
    case denied(reason: String)
}

// MARK: - Injecteerbare laag

/// Leest en vraagt microfoontoestemming. Protocol zodat de suite een stub injecteert
/// in plaats van de echte TCC-status te lezen.
public protocol MicrophonePermission: Sendable {
    /// De huidige toestemmingsstand.
    func authorizationStatus() -> MicrophoneAuthorization
    /// Vraagt toegang aan. Bij `.notDetermined` toont macOS de systeemprompt; geeft
    /// true als de gebruiker toestaat.
    func requestAccess() async -> Bool
}

extension MicrophonePermission {
    /// De menu-melding bij geweigerde toestemming gebruikt dezelfde `errorNotice`-route als Toegankelijkheid.
    public static var deniedNotice: String {
        "Microfoontoegang geweigerd. Sta Klep toe in Systeeminstellingen → Privacy & beveiliging → Microfoon."
    }

    /// Zorgt dat er toestemming is vóór de opname start. Bij `.notDetermined` vraagt
    /// hij aan zodat macOS de prompt toont; bij `.denied`/`.restricted` weigert hij
    /// meteen. Geen stil doorgaan: een weigering levert een reden voor het menu.
    public func ensureAccess() async -> MicrophonePermissionOutcome {
        switch authorizationStatus() {
        case .authorized:
            return .granted
        case .notDetermined:
            return await requestAccess() ? .granted : .denied(reason: Self.deniedNotice)
        case .denied, .restricted:
            return .denied(reason: Self.deniedNotice)
        }
    }
}

// MARK: - Echte laag (mensentest)

/// Echte toestemmingslaag via `AVCaptureDevice` (`.audio`). De runtime-prompt is een
/// mensentest; de beslissingslogica zit testbaar in `ensureAccess`.
public struct AVCaptureMicrophonePermission: MicrophonePermission {
    public init() {}

    public func authorizationStatus() -> MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    public func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
