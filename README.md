# iRufus

Applicazione grafica nativa per macOS che porta su Mac le funzioni di
[Rufus](https://github.com/pbatard/rufus): creare chiavette USB e schede SD avviabili da ISO e
immagini disco, verificare checksum, testare blocchi difettosi e salvare dispositivi in immagine.

- **GUI**: Swift + SwiftUI (macOS 14+, Apple Silicon; Intel tramite build universale)
- **Motore**: Rust (`engine/`): parsing ISO 9660/Joliet/Rock Ridge/UDF/El Torito, WIM, MBR/GPT,
  formati compressi; partizionamento, FAT32, scrittura DD, split di `install.wim`, verifica
- **Privilegi**: solo l'apertura del disco raw, tramite `authopen` di Apple (vedi `docs/SICUREZZA.md`)
- **Licenza**: GPL-3.0-or-later (opera derivata da Rufus)

## Cosa fa
| | |
|---|---|
| Dispositivi | Rilevamento USB/SD a caldo, dettagli e partizioni, esclusione di dischi interni/avvio/backup, espulsione |
| Immagini | ISO, IMG/RAW, VHD fisso, gz/xz/zst/bz2/zip; riepilogo con tipo, architettura, modalità e firmware di destinazione |
| Scrittura | DD bit per bit con verifica; modalità ISO (GPT o MBR + FAT32, **solo UEFI**) con verifica file per file |
| Windows | File > 4 GB (split `install.wim`), bypass TPM/Secure Boot/RAM, niente account Microsoft, account locale, privacy, BitLocker, impostazioni regionali |
| Strumenti | MD5/SHA-1/SHA-256/SHA-512 con confronto, bad blocks e capacità contraffatta, azzeramento, salvataggio in .img/.vhd |
| Download | Ubuntu Desktop LTS, SystemRescue e FreeDOS dai server ufficiali, con verifica SHA-256 e firma OpenPGP (Ubuntu, SystemRescue), pausa/ripresa |
| Altro | Log esportabile senza dati personali, impostazioni persistenti, tema chiaro/scuro, italiano e inglese |

Cosa **non** fa (ancora o per scelta) è elencato in [`docs/MATRICE_FUNZIONI.md`](docs/MATRICE_FUNZIONI.md):
boot loader BIOS in modalità ISO, NTFS/exFAT/ext, persistenza Linux, Windows To Go, VHDX/FFU, download di Windows e macOS.

## Build rapida
```bash
scripts/build-app.sh && open build/iRufus.app
```
Dettagli, test, firma e notarizzazione: [`docs/BUILD.md`](docs/BUILD.md).

## Documentazione
- [`docs/ANALISI.md`](docs/ANALISI.md) — analisi di Rufus, matrice iniziale, licenze, architettura, piano per fasi
- [`docs/MATRICE_FUNZIONI.md`](docs/MATRICE_FUNZIONI.md) — stato reale, limitazioni e test di ogni funzione
- [`docs/SICUREZZA.md`](docs/SICUREZZA.md) — protezione dei dati e helper privilegiato
- [`docs/FFI.md`](docs/FFI.md) — interfaccia Swift ↔ Rust
- [`docs/TEST_MANUALI.md`](docs/TEST_MANUALI.md) — checklist per hardware reale
- [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md)

## Struttura
```
engine/          motore Rust (lib statica + test), vendor/fatfs con patch
app/             pacchetto Swift: IrufusCore (logica, Disk Arbitration, broker), iRufus (SwiftUI), IrufusCoreChecks
scripts/         build, CI, E2E su disco virtuale, localizzazione, licenze, archivio sorgenti
docs/            documentazione
```

iRufus non è affiliato con Rufus né con Akeo Consulting.
