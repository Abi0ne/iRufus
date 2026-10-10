# Changelog

## 0.1.3 — 2026-10-10
- Nuova finestra "Scarica un sistema operativo" (menu SELEZIONA ▾) che scarica dai server degli editori:
  - **Windows 11** x64 e Arm, ultima versione (oggi 26H2), lingua a scelta, verificata con lo SHA-256 che Microsoft
    pubblica sulla pagina di download. Se Microsoft rifiuta la richiesta (errore 715-123130) si apre la sua pagina;
  - **Ubuntu Desktop**, ultima LTS: SHA-256 da `SHA256SUMS` con firma OpenPGP verificata (chiave Ubuntu incorporata);
  - **SystemRescue**, live di soccorso: firma OpenPGP della ISO stessa verificata dopo il download;
  - **FreeDOS 1.4** USB Lite/Full: SHA-256 fissato in iRufus.
- L'immagine prende il nome finale solo dopo la verifica; pausa e ripresa, cartella di destinazione a scelta,
  controllo dello spazio libero; un file già presente viene verificato invece di essere scaricato di nuovo.
- Kali Live non è offerta: Kali la distribuisce solo via BitTorrent.

## 0.1.2 — 2026-10-08
- Aggiornamenti automatici dalle release GitHub di Abi0ne/iRufus: controllo giornaliero, download,
  verifica della firma Ed25519 e sostituzione dell'app alla chiusura (o con "Riavvia ora").
  Nuova scheda *Impostazioni › Aggiornamenti* e voce di menu "Controlla aggiornamenti…".
- La barra di avanzamento ora si muove anche mentre `install.wim` viene diviso in parti (prima restava
  ferma per diversi minuti e poi saltava in avanti).
- Icona dell'app: quella di Rufus (pubblico dominio).

## 0.1.1 — 2026-10-08
- Interfaccia ridisegnata con la disposizione di Rufus: "Opzioni unità", "Opzioni formattazione", "Stato",
  opzioni avanzate a scomparsa, barra di stato grande (PRONTO), icone in basso, AVVIA/CHIUDI, barra inferiore.
- Pulsante ✓ per i checksum e menu SELEZIONA ▾ (selezione file, pagine ufficiali Windows).
- Opzioni Windows in una finestra dopo AVVIA, come la "Windows User Experience" di Rufus.
- Test dei blocchi difettosi opzionale prima della scrittura (1/2/4 passaggi).

## 0.1.0 — 2026-10-08
Prima versione.
- Motore Rust: ISO 9660/Joliet/Rock Ridge/UDF/El Torito, WIM, MBR/GPT; gz/xz/zstd/bz2/zip, VHD fisso.
- Scrittura DD e modalità ISO (GPT/MBR + FAT32, solo UEFI) con verifica di rilettura; split di install.wim.
- File di risposta Windows (bypass TPM/Secure Boot/RAM, niente account Microsoft, account locale, privacy, BitLocker, impostazioni regionali).
- Checksum MD5/SHA-1/SHA-256/SHA-512, bad blocks con rilevamento capacità contraffatta, azzeramento, salvataggio .img/.vhd.
- App SwiftUI (macOS 14+): Disk Arbitration, accesso privilegiato via authopen, conferma rinforzata, log senza dati personali, italiano e inglese.
- Non ancora provata su hardware fisico (vedi docs/TEST_MANUALI.md).
