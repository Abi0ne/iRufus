#!/bin/bash
# Build build/release/iRufus-<version>.dmg: a drag-to-install disk image with the app,
# a link to /Applications and a text file explaining how to open an unsigned app.
# Usage: make-dmg.sh [app]   (default: build/iRufus.app)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(grep -m1 '^version' "$ROOT/engine/Cargo.toml" | cut -d'"' -f2)"
APP="${1:-$ROOT/build/iRufus.app}"
OUT="$ROOT/build/release"
DMG="$OUT/iRufus-$VERSION.dmg"
README="LEGGIMI - Come aprire iRufus.txt"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/iRufus.app"
ln -s /Applications "$STAGE/Applicazioni"

cat > "$STAGE/$README" <<TXT
iRufus $VERSION
===============

INSTALLAZIONE
1. Trascina "iRufus" sulla cartella "Applicazioni" in questa finestra.
2. Espelli l'immagine disco "iRufus".

PERCHÉ macOS BLOCCA L'APP AL PRIMO AVVIO
iRufus è un progetto open source e non è firmato con un certificato Apple Developer
né notarizzato da Apple. Per questo, al primo avvio macOS mostra un avviso come
"Impossibile aprire iRufus" o "Apple non può verificare che iRufus non contenga
malware" e non la apre. Non è un errore dell'app: va solo autorizzata una volta.

COME CONSENTIRNE L'ESECUZIONE (macOS 15 Sequoia e successivi)
1. Apri iRufus da Applicazioni: compare l'avviso. Premi "Fine" (non "Sposta nel Cestino").
2. Apri Impostazioni di Sistema › Privacy e sicurezza.
3. Scorri fino alla sezione "Sicurezza": c'è il messaggio
   "iRufus è stato bloccato per proteggere il Mac". Premi "Apri comunque".
4. Inserisci la password (o Touch ID) e conferma con "Apri comunque".
Dai lanci successivi iRufus si apre normalmente.

macOS 14 Sonoma: in alternativa, nel Finder fai clic destro (o Ctrl-clic) su iRufus
in Applicazioni, scegli "Apri" e conferma con "Apri".

ALTERNATIVA DA TERMINALE
Rimuove l'attributo di quarantena che il browser aggiunge al download:
    xattr -dr com.apple.quarantine /Applications/iRufus.app

REQUISITI
macOS 14 o successivo, Mac con Apple Silicon.

AGGIORNAMENTI
iRufus controlla da solo le nuove versioni su GitHub e verifica la firma Ed25519
di ogni aggiornamento prima di installarlo.

Codice sorgente e segnalazioni: https://github.com/Abi0ne/iRufus
Licenza: GPL-3.0-or-later (opera derivata da Rufus).


-------------------------------------------------------------------------------
ENGLISH

INSTALL: drag "iRufus" onto the "Applicazioni" (Applications) folder in this window.

iRufus is open source and is not signed with an Apple Developer certificate nor
notarized, so macOS blocks it on first launch. To allow it (macOS 15 and later):
open iRufus once and press "Done", then go to System Settings › Privacy & Security,
scroll to "Security" and click "Open Anyway" next to "iRufus was blocked...",
then confirm with your password. On macOS 14 you can instead right-click the app
in Applications and choose "Open". From Terminal:
    xattr -dr com.apple.quarantine /Applications/iRufus.app

Requires macOS 14 or later on Apple Silicon.
TXT

mkdir -p "$OUT"
rm -f "$DMG"
hdiutil create -quiet -volname "iRufus" -srcfolder "$STAGE" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 "$DMG"
hdiutil verify -quiet "$DMG"
echo "$DMG"
