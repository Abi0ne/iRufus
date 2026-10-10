# Matrice delle funzioni — stato reale (v0.1.0)

Legenda: **✅ Supportata** · **🔁 Implementazione diversa** · **⚠️ Limitata** · **⛔ Esclusa** · **🕓 Non disponibile** (nascosta nell'interfaccia).
"Test" indica dove la funzione è verificata: `R:` test Rust (`engine/`), `I:` test d'integrazione Rust (`engine/tests/integration.rs`),
`S:` controlli Swift (`swift run IrufusCoreChecks`), `E2E:` `scripts/e2e-virtual-disk.sh`, `M:` checklist manuale (`docs/TEST_MANUALI.md`).

## Dispositivi

| Funzione | Stato | Limitazioni | Test |
|---|---|---|---|
| Rilevamento hot-plug USB/SD (Disk Arbitration) | ✅ | Solo dischi interi con BSD name, dimensione, blocco 512/4096 e major/minor | S: eligibility, M-1 |
| Nome, produttore/modello, capacità, identificatore, connessione, partizioni | ✅ | Numero di serie non mostrato | M-1 |
| Esclusione dischi interni, disco di avvio, cartella Inizio, Time Machine, disco dell'immagine, contenitori APFS | ✅ | Albero IOKit discendente confrontato con i volumi protetti | S: eligibility |
| HDD/SSD USB, immagini disco collegate | ✅ (opt-in) | Disattivati per impostazione predefinita | S: eligibility |
| Thunderbolt/PCIe esterni, SATA | ⛔ | Rufus li elenca solo con un cheat mode "non supportato" | S: eligibility |
| Elenco dispositivi esclusi | ✅ | Identità = produttore+modello+capacità+percorso bus | S: eligibility |
| Espulsione sicura | ✅ | | M-2 |
| Reset porta USB (Alt-C) | ⛔ | Nessuna API pubblica macOS | — |
| Smontaggio, blocco del montaggio automatico durante la scrittura | ✅ | Smontaggio non forzato; il messaggio di macOS indica il volume in uso | M-3 |
| Verifica identità prima della scrittura (2 volte) e del descrittore (`st_rdev`, dimensione, blocco) | ✅ | | S: identity, R: device, E2E |

## Immagini

| Funzione | Stato | Limitazioni | Test |
|---|---|---|---|
| ISO 9660 + Joliet + Rock Ridge (NM, SL, CL/RE, CE) + multi-extent | ✅ | Rock Ridge usato solo se i nomi NM sono presenti | R: iso9660, I: linux_like |
| UDF 1.02–2.01 (ISO Windows, file > 4 GB) | ✅ | Partizioni metadata UDF 2.50+ non supportate (ripiego ISO 9660 con avviso) | I: linux_like, windows_like, oversized (ignorato, 4,3 GB) |
| El Torito BIOS/EFI | ✅ (analisi) | Estrazione dell'immagine EFI El Torito non supportata | I |
| Rilevamento Windows (WIM/ESD: edizioni, architettura, build) e Linux (casper, live, grub, syslinux) | ✅ | | R: wim, I: windows_like |
| Immagini raw/IMG, MBR/GPT | ✅ | | R: partition, S: analyze |
| gzip, xz (dimensione esatta da indice), zstd, bzip2, ZIP/ZIP64 (Stored/Deflate/Bzip2/Zstd) | ✅ | ISO compresse solo in DD; ZIP con più immagini rifiutati | R: source |
| VHD fisso | ✅ | VHD dinamici/differenziali rifiutati | R: source, save |
| VHDX, FFU | ⛔ | Formati Microsoft senza API su macOS | R: source (VHDX rifiutato) |

## Scrittura

| Funzione | Stato | Limitazioni | Test |
|---|---|---|---|
| DD con verifica di rilettura SHA-256, pulizia GPT di backup obsoleta | ✅ | | R: dd, I: hybrid, S, E2E |
| Spazio insufficiente (noto in anticipo o durante lo stream), immagine corrotta, annullamento, disconnessione (ENXIO/ENODEV) | ✅ | | R: dd, I: extraction_refuses_small_device, extraction_cancellation |
| Modalità ISO: GPT o MBR, FAT32 allineato 1 MiB, copia file, verifica per file, validazione GPT | ✅ | **Solo UEFI** (nessun boot loader BIOS) | I: linux_like, macos_recognises, E2E |
| Patch etichetta nei config Linux (`LABEL=`/`CDLABEL=`) | ✅ | Solo file `.cfg`/`.conf` ≤ 1 MiB in /EFI, /boot, /isolinux, /syslinux, /loader | R: extract, I |
| Split `install.wim` > 4 GB in `.swm` | 🔁 | ESD/solid non suddivisibili; parti da 3800 MiB | R: wim, I: wim_split_is_accepted_by_wimlib |
| Dimensione cluster, etichetta volume | ✅ | | R: fat32 |
| FAT16, exFAT, NTFS, ReFS, UDF, ext2/3/4 come destinazione | ⛔/🕓 | Vedi ANALISI.md righe 10–15 | — |
| Boot loader BIOS (Syslinux, GRUB, Grub4DOS, FreeDOS, MS-DOS, ReactOS), UEFI:NTFS | 🕓/⛔ | Per ISO ibride usare DD | — |
| Persistenza Linux | 🕓 | Richiede ext3/4 | — |
| Windows To Go | ⛔ | Richiede NTFS e bcdboot | — |

## Windows (file di risposta)

| Opzione | Stato | Note | Test |
|---|---|---|---|
| Bypass TPM/Secure Boot/RAM (solo Windows 11) | 🔁 | `/Autounattend.xml` (pass windowsPE) invece di modificare boot.wim; solo avvio dalla chiavetta | R: wue, I: windows_like |
| Niente account Microsoft (BypassNRO) | ✅ | | R: wue |
| Account locale (password vuota, cambio al primo accesso, nomi riservati rifiutati) | ✅ | Nome escluso dal log | R: wue, S |
| Disattiva raccolta dati, BitLocker automatico, impostazioni regionali | ✅ | Fuso orario non copiato | R: wue |
| Dischi interni offline, S Mode, CA 2023, SkuSiPolicy, QoL, installazione silenziosa, wrapper setup.exe | ⛔ | Solo WTG / richiedono boot.wim o binari Windows / rischio dati | — |
| Effetto reale in Windows Setup | ⚠️ | Verificabile solo su PC reale | M-6 |

## Strumenti e altro

| Funzione | Stato | Limitazioni | Test |
|---|---|---|---|
| MD5/SHA-1/SHA-256/SHA-512 (SHA-256 predefinito), confronto con checksum incollato | ✅ | Integrità ≠ autenticità (spiegato nell'interfaccia) | R: hash, S |
| Bad blocks distruttivo 1/2/4 passate + capacità contraffatta | ✅ | Avviso e conferma; durata lunga | R: badblocks (drive finto simulato) |
| Azzeramento dispositivo con verifica | ✅ | | R: dd |
| Salva dispositivo in .img / .vhd | ✅ | Accesso in sola lettura; il file non può stare sul disco letto | R: save |
| Download ISO Windows | 🔁 | Apre la pagina ufficiale Microsoft; nessuno script remoto | — |
| Download Ubuntu Desktop (ultima LTS) | ✅ | Solo amd64; versione e SHA-256 da `SHA256SUMS` con firma OpenPGP verificata (chiave Ubuntu fissata); pausa/ripresa | S: downloads |
| Download FreeDOS 1.4 USB Lite/Full | ✅ | SHA-256 fissato in iRufus (release fissa); immagine DD, solo BIOS/CSM | S: downloads |
| Download SystemRescue (ultima versione) | ✅ | Solo amd64, versione ≥ 13.02; firma OpenPGP della ISO verificata dopo il download (sottochiave fissata) oltre allo SHA-256; pausa/ripresa | S: downloads |
| Download Kali Live | ⛔ | Kali distribuisce la ISO live solo via BitTorrent (nessun mirror HTTP né web seed); SystemRescue come alternativa per il recupero | — |
| Download MS-DOS / PC-DOS | ⛔ | MS-DOS 4.0 (MIT) esiste solo come sorgente e floppy; PC-DOS non è ridistribuibile | — |
| Aggiornamenti automatici da GitHub (Abi0ne/iRufus) | 🔁 | Pacchetto firmato Ed25519; sostituzione dell'app alla chiusura o con "Riavvia ora" | S: updates |
| Download UEFI Shell, controllo DBX/SBAT | 🕓 | Nascosti | — |
| Log consultabile ed esportabile, senza dati personali | ✅ | | S: log |
| Impostazioni persistenti, tema chiaro/scuro (sistema), unità binarie/decimali | ✅ | | M-1 |
| Localizzazione | ⚠️ | Italiano e inglese | `scripts/localization.py check` |
| Accessibilità (VoiceOver, tastiera) | ✅ | | M-8 |
