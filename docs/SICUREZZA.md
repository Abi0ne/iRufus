# Sicurezza e protezione dei dati

## Modello di minaccia
L'errore più grave possibile è scrivere sul disco sbagliato. Seguono la scrittura di dati corrotti
presentati come validi, l'esecuzione di codice non verificato e la fuga di dati personali nei log.

## Selezione del dispositivo
- Nessun disco viene mai selezionato automaticamente (`selectedDeviceID` parte da `nil` e torna `nil`
  se il disco scompare).
- `EligibilityPolicy.evaluate` (`app/Sources/IrufusCore/DeviceModel.swift`) esclude, in quest'ordine:
  dischi non identificati con certezza (BSD name non `diskN`, dimensione 0, blocco diverso da 512/4096,
  major/minor assenti), dischi che contengono il volume di avvio, il gruppo di volumi di sistema, la
  cartella Inizio, l'app stessa o un backup Time Machine, il disco che contiene l'immagine sorgente,
  contenitori APFS sintetizzati, immagini disco (salvo opt-in), dischi interni, connessioni diverse da
  USB/SD, supporti in sola lettura, HDD/SSD USB (salvo opt-in) ed esclusioni dell'utente.
- Il controllo "disco di avvio" confronta l'intero albero IOKit sotto il disco con i volumi protetti:
  funziona anche quando macOS è avviato da un disco esterno.

## Conferma
- Foglio di conferma con modello, capacità in byte, `/dev/diskN`, connessione e operazione.
- Casella "Ho capito che tutti i dati andranno persi" obbligatoria.
- Seconda conferma (digitare l'identificatore `diskN`) se il disco supera 128 GB, non riporta
  produttore/modello, non è un supporto rimovibile o è un'immagine disco (`ConfirmationLevel`).

## Prima di scrivere
1. Lo stato della descrizione Disk Arbitration viene riletto e confrontato con l'identità confermata
   (`DiskIdentity`: BSD name, dimensione, blocco, produttore, modello, percorso bus, major/minor).
2. Smontaggio dell'intero disco (non forzato) e registrazione di un *mount approval callback* che
   rifiuta ogni montaggio di quel disco fino al termine.
3. Seconda verifica dell'identità dopo lo smontaggio.
4. Apertura privilegiata del nodo raw, poi verifica del descrittore: `S_IFCHR`, `st_rdev` uguale a
   major/minor attesi; il motore riverifica dimensione e blocco via `DKIOCGETBLOCKCOUNT/SIZE`.

## Helper privilegiato
- Unico punto privilegiato: `/usr/libexec/authopen`, componente di sistema Apple basato su
  Authorization Services. iRufus chiede il diritto `sys.openfile.readwrite./dev/rdiskN`
  (o `readonly` per "salva immagine") con un messaggio che nomina il disco, e passa l'autorizzazione
  ad `authopen` con `-extauth`.
- Interfaccia tipizzata: `PrivilegeBroker.openDevice(DiskIdentity, AccessMode, prompt)`. Il percorso
  deve rispettare `^/dev/rdisk[0-9]{1,4}$` (solo dischi interi); argv fisso
  (`authopen -stdoutpipe -extauth -o <flags> <path>`), ambiente vuoto, `posix_spawn` senza shell.
- Il descrittore arriva via `SCM_RIGHTS` ed è l'unico privilegio ottenuto. I diritti vengono distrutti
  subito (`AuthorizationFree(…, .destroyRights)`); alla chiusura del descrittore non resta nulla.
- Partizionamento, formattazione e copia avvengono nel motore Rust, nel processo utente, su quel solo
  descrittore. Non esiste un daemon root installato. Un daemon `SMAppService` non è stato adottato:
  avrebbe ampliato la superficie d'attacco senza alcun beneficio funzionale (vedi `ANALISI.md` §4).

## Scrittura
- I/O solo a blocchi allineati, offset con controllo di overflow e limiti (`check_aligned`).
- Buffer allineati a 4 KiB; cache di scrittura per il file system con read-modify-write solo sui blocchi
  parzialmente scritti.
- `DKIOCSYNCHRONIZECACHE` al termine; verifica di rilettura (DD: SHA-256 dei byte; ISO: SHA-256 di ogni
  file da un montaggio nuovo, più CRC delle due copie GPT).
- `ENXIO`/`ENODEV` → errore "dispositivo scollegato"; annullamento cooperativo controllato a ogni blocco.
- Nessun dato viene scritto se lo spazio stimato non basta (ISO) o se la dimensione esatta supera il
  dispositivo (DD); per stream di dimensione ignota la scrittura si ferma prima di superare il limite.

## Parsing di immagini non fidate
Il motore applica limiti espliciti: profondità directory ≤ 64, voci ≤ 2 milioni, directory ≤ 64 MiB,
continuazioni SUSP ≤ 16, catene di allocazione UDF ≤ 1024, XML WIM ≤ 64 MiB, controllo delle estensioni
entro la partizione, rilevamento di cicli. Il motore non esegue mai contenuti dell'immagine.
Il panic Rust non attraversa l'FFI (`catch_unwind` → `IRUFUS_ERR_INTERNAL`).

## Rete
iRufus accede alla rete solo per il controllo degli aggiornamenti e per i download di sistemi operativi chiesti
dall'utente. Le voci Windows del menu "Scarica" aprono la pagina ufficiale Microsoft nel browser.

### Download di sistemi operativi
Finestra "Scarica un sistema operativo" (`app/Sources/IrufusCore/Downloads.swift`, `OpenPGP.swift`):
- solo HTTPS, anche nei redirect (un redirect verso `http:` interrompe la richiesta); sessione effimera,
  user agent `iRufus/<versione>`; niente di diverso da una normale richiesta del browser;
- **Ubuntu Desktop**: la serie LTS più recente da `changelogs.ubuntu.com/meta-release-lts` (il nome deve essere
  `^[a-z]{2,32}$`), poi `SHA256SUMS` e `SHA256SUMS.gpg` da `releases.ubuntu.com/<serie>/`. La firma è verificata
  in Swift (OpenPGP v4, RSA + SHA-256/384/512, Security.framework) con la sola chiave
  *Ubuntu CD Image Automatic Signing Key (2012)*, `8439 38DF 228D 22F7 B374 2BC0 D94A A3F0 EFE2 1092`, incorporata
  come pacchetto della chiave pubblica: l'impronta viene ricalcolata dal pacchetto e confrontata con quella fissata.
  Firme di altre chiavi, sottopacchetti critici sconosciuti, firme scadute o di tipo testo sono rifiutati;
- **SystemRescue**: la versione più recente linkata da `www.system-rescue.org/Download/`, mai inferiore a 13.02
  (una versione vecchia, pur firmata, non viene proposta); `.sha256` e `.asc` da `www.system-rescue.org/releases/<v>/`,
  la ISO da `fastly-cdn.system-rescue.org`. La firma riguarda la ISO stessa: prima del download si controlla che sia
  della chiave attesa, dopo il download e lo SHA-256 viene verificata sull'intero file (lettura a blocchi). Chiave
  fissata: la sottochiave di firma `6298 9046 EB5C 7E98 5ECD F5DD 3B0F EA9B E13C A3C9` di *Francois Dupoux 20210704*
  (primaria `0FF1 1AF0 81E9 8345 5948 1203 7091 115F 8320 B897`), confrontata tra il sito di SystemRescue e
  keyserver.ubuntu.com. La sottochiave è l'ancora di fiducia: il legame con la primaria non viene verificato;
- **FreeDOS 1.4**: release fissa, SHA-256 incorporato in iRufus (da `verify.txt` del progetto), nessuna firma
  necessaria;
- file di metadati al massimo 1 MiB; i nomi letti dagli elenchi devono rispettare `^[A-Za-z0-9._+-]+$` e il file
  finisce sempre nella cartella scelta, mai altrove;
- il download va in `.<nome>.irufus-part` nella cartella di destinazione; dopo il download il motore calcola lo
  SHA-256 e il file assume il nome finale **solo se coincide** (e, per le immagini firmate, se la firma è valida),
  altrimenti viene eliminato. Un file con lo stesso
  nome già presente viene prima verificato; se non coincide resta al suo posto finché la nuova copia non è
  verificata;
- spazio libero controllato prima di iniziare (dimensione annunciata dal server).
Kali Live non è offerta: Kali la pubblica solo via BitTorrent (nessun mirror HTTP né web seed).

### Aggiornamenti
Il controllo degli aggiornamenti si può disattivare in *Impostazioni › Aggiornamenti*:
- al massimo una volta al giorno legge `https://api.github.com/repos/Abi0ne/iRufus/releases/latest`
  (sessione effimera: niente cookie né cache; nessun dato inviato oltre all'indirizzo IP e allo user agent
  `iRufus/<versione>`);
- scarica `iRufus-<versione>.zip` e `.zip.sig` solo via HTTPS, con limite di 200 MiB;
- installa il pacchetto solo se la firma Ed25519 corrisponde alla chiave pubblica incorporata
  (`UpdateFeed.publicKey`); la chiave privata resta fuori dal repository (`~/.config/irufus`);
- dopo l'estrazione controlla identificativo del bundle, versione uguale a quella della release (niente
  ritorno a versioni precedenti) ed eseguibile, poi `codesign --verify --deep --strict`;
- non installa mai durante un'operazione: l'app viene sostituita alla chiusura o con "Riavvia ora";
  se lo spostamento fallisce viene ripristinata la versione precedente;
- rifiuta di aggiornarsi se macOS esegue l'app da una posizione temporanea (App Translocation) o se la
  cartella non è scrivibile.

## Log
- La cartella Inizio diventa `~`, `/Users/<nome>/` diventa `/Users/<user>/`, il nome dell'account
  Windows viene registrato come segreto e sostituito da `<redacted>` (`LogStore.redact`).
- Il file di risposta non viene mai scritto nel log; le opzioni Windows sono registrate solo come booleani.

## Segnalazioni
Vulnerabilità: aprire una segnalazione privata sul repository (non usare issue pubbliche).
