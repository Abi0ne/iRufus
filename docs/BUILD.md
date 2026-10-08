# Build, firma, notarizzazione e distribuzione

## Requisiti
- macOS 14 o successivo (build e esecuzione), Apple Silicon. Intel: vedi "Build universale".
- Swift 6 (Xcode o Command Line Tools), Rust stabile ≥ 1.85 (`rustup`).
- Facoltativi per i test: `wimlib` (`brew install wimlib`), usato solo come oracolo.

## Comandi

```bash
scripts/build-engine.sh                      # libreria statica Rust → engine/target/irufus/
scripts/build-app.sh                         # build/iRufus.app (arm64, firma ad-hoc)
open build/iRufus.app

# Test
(cd engine && cargo test)                    # unitari + integrazione (ISO generate con hdiutil)
(cd engine && cargo test --release -- --ignored)   # fixture da 4,3 GB
(cd app && swift run IrufusCoreChecks)       # logica Swift + ponte FFI
scripts/e2e-virtual-disk.sh                  # E2E su disco virtuale hdiutil (nessun disco reale)
scripts/localization.py check                # traduzioni complete e segnaposto coerenti

# Controlli statici
(cd engine && cargo fmt --check && cargo clippy --all-targets -- -D warnings)
scripts/ci.sh                                # tutto quanto sopra, come in CI
```

### Solo Command Line Tools (senza Xcode)
- L'SDK più recente dei CLT può dichiarare `@State` come macro il cui plugin è incluso solo in Xcode;
  `build-app.sh` sceglie automaticamente l'SDK più recente in cui `State` è un property wrapper
  (oppure impostare `IRUFUS_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`).
- Per lo stesso motivo il plugin di Swift Testing non è utilizzabile: i test Swift sono un eseguibile
  (`IrufusCoreChecks`) senza macro.

### Build universale (Intel)
```bash
rustup target add x86_64-apple-darwin
scripts/build-app.sh --universal     # richiede Xcode per lo swift build multi-architettura
```
macOS 14 supporta i Mac Intel dal 2018 in poi; l'app non usa API specifiche di Apple Silicon.
Il binario Intel non è stato provato su hardware Intel in questa versione.

## Versione minima: macOS 14
Motivo: framework Observation (`@Observable`), `SettingsLink`, `Window`, `dropDestination` di SwiftUI.
Disk Arbitration, IOKit, Authorization Services e `authopen` sono disponibili da molto prima.

## Permessi
- L'app **non** è in sandbox: deve accedere a `/dev/rdiskN` tramite `authopen`.
- Hardened Runtime attivo, nessuna entitlement speciale.
- Nessun accesso a rete, fotocamera, contatti, ecc. Il permesso "Accesso completo al disco" non serve.
- Al momento della scrittura macOS mostra la richiesta di password di amministratore (Authorization
  Services) con il nome del disco.

## Firma e notarizzazione
```bash
export IRUFUS_SIGN_IDENTITY="Developer ID Application: Nome Cognome (TEAMID)"
scripts/build-app.sh
ditto -c -k --keepParent build/iRufus.app build/iRufus.zip
xcrun notarytool submit build/iRufus.zip --keychain-profile NOTARY --wait
xcrun stapler staple build/iRufus.app
spctl -a -vv build/iRufus.app
```
Con firma ad-hoc l'app funziona sul Mac che l'ha compilata; per distribuirla serve Developer ID +
notarizzazione (altrimenti Gatekeeper la blocca).

## Distribuzione e GPL
iRufus è GPL-3.0-or-later. Chi distribuisce il binario deve fornire il sorgente corrispondente:
`scripts/make-source-archive.sh` produce `build/iRufus-<versione>-source.tar.gz` (include il crate
`fatfs` modificato e `Cargo.lock`). L'app contiene in `Contents/Resources/LICENSES` il testo GPL,
l'elenco dei componenti di terze parti e la licenza MIT di fatfs.

## Risoluzione dei problemi
| Sintomo | Causa / rimedio |
|---|---|
| `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found` | SDK dei CLT troppo nuovo: usare `IRUFUS_SDK` (vedi sopra) o Xcode |
| `library 'irufus_engine' not found` | eseguire prima `scripts/build-engine.sh` |
| Nessun dispositivo elencato | solo USB/SD rimovibili; vedere "Dispositivi nascosti" e le Impostazioni |
| "Impossibile smontare il dispositivo" | un'app tiene aperto un file sul volume: chiuderla (il messaggio di macOS è nel log) |
| "Il dispositivo aperto non corrisponde…" | il disco è stato scambiato tra conferma e scrittura: riselezionarlo |
| Verifica fallita | chiavetta difettosa o contraffatta: usare *Strumenti › Verifica blocchi difettosi* |
| La chiavetta ISO non si avvia su un PC vecchio | la modalità ISO è solo UEFI: abilitare UEFI, provare MBR o usare DD se l'ISO è ibrida |
| La chiavetta non si avvia su un Mac Apple Silicon | i Mac Apple Silicon avviano solo macOS da dischi esterni |
