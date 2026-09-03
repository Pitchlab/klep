/// Executable-target voor de menubalk-app. Puur de instap: alle logica zit in de
/// library `Klep` (`MenuBarApp.swift`), zodat ze getest kan worden zonder
/// runloop. `scripts/build-app.sh` verpakt deze binary tot `Klep.app`.
import Klep

runMenuBarApp()
