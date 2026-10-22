# Changelog

## Unreleased

- Hands-free uitzetten terwijl het model nog opwarmde liet de microfoon daarna alsnog starten, zonder sessie die hem kon stoppen: Klep bleef transcriberen met hands-free uit. `requestStop` vóór de start slaat het starten nu over.
- Parakeet en het VAD-model staan nu in `~/Library/Application Support/Klep/Models/` in plaats van in de gedeelde FluidAudio-cache, zodat een andere app die die cache opruimt Klep niet meer zonder model zet.
- Publieke documentatie en broncommentaar opgeschoond: interne werkverwijzingen en persoonsgebonden notities verwijderd.
