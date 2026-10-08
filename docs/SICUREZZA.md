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
iRufus non scarica nulla: il menu "Scarica" apre solo la pagina ufficiale Microsoft nel browser.

## Log
- La cartella Inizio diventa `~`, `/Users/<nome>/` diventa `/Users/<user>/`, il nome dell'account
  Windows viene registrato come segreto e sostituito da `<redacted>` (`LogStore.redact`).
- Il file di risposta non viene mai scritto nel log; le opzioni Windows sono registrate solo come booleani.

## Segnalazioni
Vulnerabilità: aprire una segnalazione privata sul repository (non usare issue pubbliche).
