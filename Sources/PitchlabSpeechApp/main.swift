/// Executable-target voor de menubalk-app. Puur de instap: alle logica zit in de
/// library `PitchlabSpeech` (`MenuBarApp.swift`), zodat ze getest kan worden zonder
/// runloop. `scripts/build-app.sh` verpakt deze binary tot `PitchlabSpeech.app`.
import PitchlabSpeech

runMenuBarApp()
