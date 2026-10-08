# iRufus — Analisi iniziale di Rufus e piano di porting

Riferimento analizzato: `pbatard/rufus` @ `875f221d5b4f` (28 settembre 2026, versione 4.15),
più la wiki ufficiale (`FAQ`, `Security`, `Usage-Notes`, `Localization`).
File sorgente consultati: `src/rufus.h`, `format.c`, `iso.c`, `wue.c`, `drive.c`, `badblocks.c`,
`hash.c`, `vhd.c`, `net.c`, `license.h`, `res/*/readme.txt`.

## 1. Cosa significa "supporto avviabile"

iRufus dichiara compatibile una combinazione *immagine × modalità × schema × target* solo se:

1. la scrittura termina **e** la verifica di rilettura (hash del contenuto scritto) coincide;
2. la struttura risultante rispetta le regole del firmware target:
   - **UEFI**: tabella GPT valida (header + backup con CRC) o MBR con partizione attiva/tipo FAT,
     un file system FAT leggibile dal firmware (FAT32 obbligatorio per specifica UEFI 2.x §13.3)
     e il loader `\EFI\BOOT\BOOT<arch>.EFI` presente per l'architettura dichiarata;
   - **BIOS/CSM**: codice di boot MBR + record di boot di partizione che caricano un loader esistente;
   - **DD/ISOHybrid**: copia bit a bit verificata — l'avviabilità è quella progettata dall'autore dell'immagine;
3. iRufus mostra, prima dell'avvio, quali firmware target sono attesi (UEFI x64/ARM64/IA32/RISC-V,
   BIOS) e quali limiti noti esistono (Secure Boot, CSM assente sui PC recenti, Mac Apple Silicon
   che non avviano supporti esterni non-macOS).

La verifica del passo 3 su hardware reale è nella checklist manuale (`docs/TEST_MANUALI.md`).
Nessun test automatico avvia un PC: i test verificano la struttura on-disk.

## 2. Matrice funzioni Rufus → iRufus

Legenda: **✅ Supportata** · **🔁 Implementazione diversa** · **⚠️ Limitata** (macOS/hardware) ·
**⛔ Esclusa** (motivazione tecnica) · **🕓 Non disponibile in questa versione** (nascosta nell'interfaccia).
Lo stato effettivo a fine implementazione, con i test associati, è mantenuto in [`MATRICE_FUNZIONI.md`](MATRICE_FUNZIONI.md).

| # | Funzione Rufus | Implementazione in Rufus | Implementazione iRufus su macOS | Stato previsto |
|---|---|---|---|---|
| 1 | Enumerazione USB/SD, refresh hot-plug | SetupAPI + IOCTL, timer | Disk Arbitration (callback appear/disappear/description) + IOKit per albero di partizioni | ✅ |
| 2 | Esclusione dischi fissi/HDD USB (Alt-F, Ctrl-Alt-F) | euristiche `hdd_vs_ufd.h` | Esclusi interni, disco di avvio, dischi che ospitano l'immagine; HDD USB solo con opzione esplicita | 🔁 |
| 3 | Elenco esclusioni (GPT GUID) | registro | Esclusione per `MediaUUID`/serial + identificativo modello, persistita in preferenze | 🔁 |
| 4 | Espulsione sicura / Cycle port (Alt-C) | CM_Request_Device_Eject / IOCTL | `DADiskEject`; reset porta USB non esposto da API pubbliche | ⚠️ (reset porta ⛔) |
| 5 | Rilevamento VHD/VMware montati (Alt-G/W) | VDS | Immagini disco collegate con `hdiutil` mostrate solo con opzione "dispositivi virtuali" (utile per test) | 🔁 |
| 6 | Selezione ISO / immagini / compressi | libcdio, bled | Parser ISO9660 + Joliet + Rock Ridge + UDF + El Torito in Rust; gz/xz/zst/bz2/zip(64) | ✅ |
| 7 | Scrittura DD/raw | WriteFile su PhysicalDrive | `write` a blocchi allineati su `/dev/rdiskN` ottenuto via `authopen` | ✅ |
| 8 | Modalità ISO (estrazione file) | libcdio + FAT/NTFS | Estrazione in Rust su FAT32 scritta direttamente sul dispositivo (crate `fatfs`) | ✅ (FAT32) |
| 9 | Partizionamento MBR/GPT | IOCTL_DISK_SET_DRIVE_LAYOUT | Scrittura diretta MBR/GPT (con backup GPT e CRC32) dal motore Rust | ✅ |
| 10 | FAT16/FAT32 (incl. Large FAT32 > 32 GB) | fmifs / fat32format | Formattazione in Rust (`fatfs`), allineamento 1 MiB, cluster selezionabile | ✅ |
| 11 | exFAT | fmifs | `newfs_exfat` nativo è disponibile, ma l'uso richiede un comando esterno sul device: rinviato | 🕓 |
| 12 | NTFS | fmifs | macOS non scrive NTFS; nessuna implementazione distribuibile e verificata | ⛔ |
| 13 | ReFS | fmifs | Nessuna implementazione fuori da Windows | ⛔ |
| 14 | UDF (come FS di destinazione) | fmifs | `newfs_udf` esiste, ma nessun caso d'uso bootabile verificato | ⛔ |
| 15 | ext2/ext3/ext4 | e2fsprogs embedded | Nessun mkfs.ext nativo; richiede porting e2fsprogs (GPL) | 🕓 |
| 16 | Persistenza Linux (casper-rw / persistence) | ext3 + patch config | Dipende da 15 | 🕓 |
| 17 | Bootloader FreeDOS / MS-DOS | file embedded / download MS | Richiede PBR FAT specifici (ms-sys) e redistribuzione FreeDOS | 🕓 (MS-DOS ⛔: binari Microsoft) |
| 18 | Syslinux v4/v6 (BIOS, modalità ISO) | libinstaller + download | Patch `ldlinux.sys` con mappa settori: non portato | 🕓 |
| 19 | GRUB2 / Grub4DOS / ReactOS (BIOS, modalità ISO) | core.img embedded | Non portato; per ISO ibride usare DD | 🕓 |
| 20 | UEFI:NTFS | immagine FAT embedded | Dipende da NTFS/exFAT come FS dati | 🕓 |
| 21 | Avvio UEFI da ISO estratta | copia file | FAT32 + `\EFI\BOOT\BOOT*.EFI` verificato | ✅ |
| 22 | ISO Windows con file > 4 GB | NTFS + UEFI:NTFS, o split WIM con wimlib | Split di `install.wim` in `.swm` su FAT32 (implementato in Rust, copia raw delle risorse) | 🔁 |
| 23 | ISO Windows avviabile BIOS | MBR + PBR NTFS/FAT32 | Non portato (richiede PBR bootmgr) | 🕓 |
| 24 | Windows To Go | wimlib apply + bcdboot | Richiede NTFS e `bcdboot` (binario Windows) | ⛔ |
| 25 | WUE: bypass TPM/Secure Boot/RAM | registry offline in boot.wim o unattend | `Autounattend.xml` alla radice del supporto (ricerca implicita di Windows Setup, pass windowsPE) | 🔁 |
| 26 | WUE: niente account online, account locale, privacy, BitLocker, locale | unattend.xml | Stesso XML, generato e verificato in Rust | ✅ |
| 27 | WUE: dischi interni offline, S Mode | unattend offlineServicing | "Dischi interni offline" vale solo per Windows To Go (escluso); S Mode non portata | ⛔ |
| 28 | WUE: CA 2023 bootloaders, SkuSiPolicy, wrapper setup.exe upgrade | wimlib + binari Windows | Richiedono modifica di boot.wim e binari Microsoft | ⛔ |
| 29 | WUE: QoL, installazione silenziosa | unattend + PowerShell | Silenziosa esclusa (cancella dischi senza conferma: rischio dati); QoL rinviata | 🕓 |
| 30 | MD5/SHA-1/SHA-256/SHA-512 | hash.c | RustCrypto, SHA-256 predefinito, confronto con checksum fornito | ✅ |
| 31 | Verifica checksum file estratti (md5sum.txt) | hash.c | Verifica di rilettura dell'intero supporto o dei file copiati | 🔁 |
| 32 | Bad blocks (1–4 passate) + fake drive | badblocks.c (e2fsprogs) | Test distruttivo scrittura/lettura pattern + firma indirizzo per capacità falsa, in Rust | ✅ |
| 33 | Salva disco in VHD/DD | vhd.c | Salvataggio raw `.img` e VHD fisso (footer Connectix) | ✅ |
| 34 | VHDX / FFU | API Windows / DISM | Formati Microsoft senza API su macOS | ⛔ (VHDX 🕓 in lettura) |
| 35 | Salva unità in ISO (UDF), Dump ottico (Alt-O) | API Windows | Non portato | ⛔ |
| 36 | Download ISO Windows (Fido) | PowerShell remoto firmato | Fido è PowerShell e Microsoft blocca spesso l'accesso automatizzato; si apre la pagina ufficiale Microsoft | 🔁 |
| 37 | Download UEFI Shell | GitHub pbatard/UEFI-Shell | Rinviato (serve DB di hash fissati come in Rufus) | 🕓 |
| 38 | Controllo DBX / SBAT revocati | DB embedded + download UEFI.org | Rinviato | 🕓 |
| 39 | Controllo aggiornamenti | rufus.ie firmato | Rinviato (nessun canale firmato ancora) | 🕓 |
| 40 | Log, salvataggio log | finestra log | Pannello log con esportazione; nessun dato sensibile (username WUE mascherato) | ✅ |
| 41 | Impostazioni persistenti | registro / ini | `UserDefaults` | ✅ |
| 42 | Tema chiaro/scuro | darkmode.c | Nativo SwiftUI | ✅ |
| 43 | Localizzazione (38 lingue) | rufus.loc | Italiano e inglese (`Localizable.strings`); altre lingue aggiungibili | ⚠️ |
| 44 | Etichetta volume estesa, icona autorun.inf | autorun.inf | autorun.inf è specifico Windows; etichetta sì | 🔁 |
| 45 | Quick format / zap (Alt-Z) | IOCTL | Zero-fill completo come opzione "Azzera dispositivo" | ✅ |
| 46 | Disabilita controlli dimensione (Alt-S), ignora marker boot (Alt-M) | flag | Non esposti: potenzialmente distruttivi/fuorvianti | ⛔ |
| 47 | Joliet/Rock Ridge toggle (Alt-J/K) | libcdio | Rock Ridge preferito, poi Joliet, poi ISO9660; non esposto | 🔁 |
| 48 | Preserva timestamp (Alt-T) | flag | Timestamp ISO preservati sempre | 🔁 |
| 49 | Validazione runtime UEFI (uefi-md5sum) | bootloader dedicato | Non portato | 🕓 |
| 50 | Rilevamento processi che bloccano il disco | System Informer | DA dissenter: viene mostrato il messaggio di macOS sul processo che impedisce lo smontaggio | 🔁 |
| 51 | Riga di comando | parziale | Non richiesta (app grafica) | ⛔ |

## 3. Componenti di terze parti e licenze

| Componente | Uso in Rufus | Licenza | Decisione iRufus |
|---|---|---|---|
| Rufus (codice e logica) | — | GPL-3.0-or-later | iRufus è un'opera derivata (porting di logica e testi WUE): **GPL-3.0-or-later** |
| ms-sys | MBR/PBR | GPL-2.0-or-later | Non incluso in questa versione |
| libcdio | ISO/UDF | GPL-3.0-or-later | Non incluso: parser riscritto in Rust |
| wimlib | WIM | LGPL-3.0/GPL-3.0 | Non incluso: split WIM scritto in Rust; `wimlib-imagex` solo come oracolo opzionale nei test |
| Syslinux, GRUB, Grub4DOS, FreeDOS | bootloader | GPL-2.0+/GPL-3.0+ | Non inclusi in questa versione (nessun binario firmware distribuito) |
| UEFI:NTFS, EfiFs, ntfs-3g | boot NTFS/exFAT | GPL | Non inclusi |
| e2fsprogs | badblocks, ext | GPL | Algoritmo bad blocks riscritto (stessi pattern 0x55/0xAA/0xFF/0x00) |
| `fatfs` (crate) | — | MIT | Incluso (formattazione/scrittura FAT) |
| RustCrypto (`md-5`, `sha1`, `sha2`) | — | MIT/Apache-2.0 | Incluso |
| `flate2`, `zstd`, `xz2`/liblzma, `bzip2`, `zip`, `crc32fast`, `serde`, `serde_json` | — | MIT/Apache-2.0/BSD/0BSD | Inclusi (elenco completo in `THIRD_PARTY_LICENSES.md`, generato) |

Nessun binario Windows, script remoto o firmware viene copiato o scaricato da iRufus in questa versione.
Ogni futuro componente scaricato dovrà avere SHA-256 fissato nel codice (come `db.h` di Rufus) e firma verificata.

## 4. Architettura

```
┌──────────────────────── iRufus.app (utente, sandbox off, hardened runtime) ─────────────────┐
│ SwiftUI (MainWindow, LogView, Settings, Advanced)                                            │
│   │  @Observable AppModel                                                                    │
│   ├── DiskService  ── Disk Arbitration + IOKit (enumerazione, smontaggio, espulsione,        │
│   │                   approvazione mount negata durante la scrittura)                        │
│   ├── PrivilegeBroker ── /usr/libexec/authopen  (unico punto privilegiato: restituisce un    │
│   │                   descrittore O_RDWR|O_EXLOCK per /dev/rdiskN validato; nessuna shell)   │
│   └── EngineBridge ── FFI C (irufus.h) ──┐                                                   │
│                                          ▼                                                   │
│                     libirufus_engine.a (Rust)                                                │
│                     image/ (iso9660, udf, eltorito, mbr/gpt, compressione, zip)               │
│                     hash/  partition/  fat/  write/  verify/  wim/  wue/  badblocks/ save/    │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Helper privilegiato.** L'unica operazione che richiede privilegi è aprire il nodo raw del disco
in scrittura. Si usa `authopen` (componente di sistema Apple basato su Authorization Services):
l'app passa un argv fisso (`-stdoutpipe -o <O_RDWR|O_EXLOCK> /dev/rdiskN`), il percorso è
validato con l'espressione `^/dev/rdisk[0-9]+$` e confrontato con il disco selezionato; il
descrittore arriva via `SCM_RIGHTS` e, prima di scrivere, si verifica con `fstat` che `st_rdev`
coincida con major/minor del disco riportati da Disk Arbitration e che dimensione e blocco
coincidano. Nessun privilegio resta attivo dopo la chiusura del descrittore.
Un daemon `SMAppService` non è stato adottato: manterrebbe un processo root installato,
richiede firma Developer ID per la registrazione e non servirebbe a nulla di più, perché
partizionamento e formattazione avvengono nel motore Rust sullo stesso descrittore.

**Versione minima.** macOS 14 Sonoma: Observation (`@Observable`), API SwiftUI usate
(`inspector`, `ContentUnavailableView`), Disk Arbitration e `authopen` presenti da molto prima.
Apple Silicon (arm64) è il target primario. Intel (x86_64) è supportato dalla build universale
(`scripts/build-app.sh --universal`, richiede `rustup target add x86_64-apple-darwin`);
macOS 14 gira ancora su Mac Intel dal 2018 in poi.

## 5. Piano per fasi

| Fase | Contenuto | Rischi tecnici | Criterio di completamento |
|---|---|---|---|
| 1 | Analisi, matrice, licenze | Funzioni Windows-only | Questo documento |
| 2 | Architettura, FFI, motore Rust (parsing, hash, partizioni, FAT, scrittura, verifica, WIM split, WUE, bad blocks, salvataggio) | ISO con file > 4 GB (UDF), fedeltà del formato WIM | `cargo test` verde con fixture generate (hdiutil makehybrid, immagini sintetiche) |
| 3 | GUI SwiftUI + Disk Arbitration | Identificazione affidabile dei dischi | App compilabile, nessun disco interno selezionabile |
| 4 | Integrazione privilegiata (`authopen`) | Prompt di autorizzazione, accesso esclusivo, auto-mount | Scrittura end-to-end su disco virtuale `hdiutil attach` e verifica |
| 5 | Verifica e documentazione | Avviabilità reale | Test automatici + checklist manuale + doc build/firma/notarizzazione |
