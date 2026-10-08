# Checklist manuale su hardware reale

Usare chiavette **senza dati da conservare**. Annotare modello, capacità, macOS, esito e allegare il log esportato.

| # | Prova | Atteso |
|---|---|---|
| M-1 | Avvio app, inserimento/rimozione di chiavetta USB e scheda SD | Compaiono/spariscono entro ~1 s; nessuna selezione automatica; disco interno in "Dispositivi nascosti" |
| M-2 | Espelli | Volumi smontati, dispositivo espulso dal Finder |
| M-3 | Scrittura con un file aperto sulla chiavetta (es. in Anteprima) | Errore di smontaggio comprensibile, nulla scritto |
| M-4 | DD di un'ISO Linux ibrida (Ubuntu, Fedora, Debian) | Richiesta password con nome disco; verifica OK; avvio UEFI e BIOS/CSM su PC x86-64 |
| M-5 | Modalità ISO con ISO Windows 11 ufficiale (install.wim > 4 GB), GPT | install.swm + install2.swm; avvio UEFI; installazione completa |
| M-6 | Come M-5 con bypass TPM, account locale, niente MSA su PC senza TPM 2.0 | Setup non blocca i requisiti; account locale creato; password richiesta al primo accesso |
| M-7 | Rimozione della chiavetta durante la scrittura | Errore "dispositivo scollegato"; app utilizzabile; nessun crash |
| M-8 | VoiceOver e sola tastiera: selezione dispositivo, immagine, avvio, conferma | Tutti i controlli raggiungibili e annunciati |
| M-9 | Annulla durante scrittura e durante verifica | Stato "Annullato", avviso di contenuto incompleto |
| M-10 | Bad blocks 1 passata su chiavetta sana e su chiavetta contraffatta nota | 0 settori / "capacità contraffatta" |
| M-11 | Salva dispositivo in .vhd e riscrivilo con DD su un'altra chiavetta | Contenuto identico (SHA-256 nel log) |
| M-12 | Disco esterno > 128 GB con "Mostra dischi rigidi USB" attivo | Richiesta di digitare l'identificatore |
| M-13 | Avvio di macOS da disco esterno USB | Il disco di avvio non compare tra i selezionabili |
| M-14 | Tema scuro/chiaro, lingua inglese (`defaults write io.github.abi0ne.iRufus AppleLanguages '(en)'`) | Testi leggibili e tradotti |

## Stato
In questa versione sono stati verificati automaticamente il percorso su dispositivo a caratteri reale
(disco virtuale, `scripts/e2e-virtual-disk.sh`) e l'enumerazione del disco virtuale nell'interfaccia.
Le prove M-1…M-14 su hardware fisico **non sono ancora state eseguite**.
