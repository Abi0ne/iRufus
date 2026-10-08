# Interfaccia FFI Swift ↔ Rust (ABI 1)

Contratto: `engine/include/irufus.h` (C) ↔ `engine/src/ffi.rs` ↔ `app/Sources/IrufusCore/Engine.swift`.

- Stringhe UTF-8; quelle restituite dal motore si liberano con `irufus_string_free`.
- Errori tipizzati: `IrufusError { code, message }`, codici stabili `IRUFUS_ERR_*` ↔ `EngineErrorCode`.
- Panic Rust intercettati (`catch_unwind`) e restituiti come `IRUFUS_ERR_INTERNAL`.
- Callback di progresso/log chiamate in modo sincrono dal thread chiamante (Swift le riporta sul main
  actor); annullamento con `IrufusCancel` da qualsiasi thread.
- `irufus_device_from_fd` prende possesso del descrittore e lo chiude anche in caso di errore.

## Modelli JSON (camelCase)
| Funzione | Ingresso | Uscita |
|---|---|---|
| `irufus_analyze` | percorso | `ImageReport` (`schemaVersion` = 1) |
| `irufus_hash_file` | percorso, maschera 1/2/4/8 | `HashResult` |
| `irufus_parse_checksum` | testo | `{digest, algorithm}` |
| `irufus_write_image` | `WriteRequest {mode: dd\|isoExtract, verify, scheme: mbr\|gpt, clusterSize, label, wue}` | `DdSummary` o `ExtractSummary` |
| `irufus_zero_device` | verify | `{}` |
| `irufus_bad_blocks` | passate 1–4 | `BadBlocksReport` |
| `irufus_save_device` | percorso, 0 raw / 1 VHD | `SaveSummary` |
| `irufus_fat32_options` | byte, blocco, schema | `{default, valid, partitionBytes}` |
| `irufus_wue_preview` | `WueOptions` | `{path, xml}` o `{}` |
| `irufus_sanitize_account_name` | nome | nome ripulito o errore |

Le strutture Swift corrispondenti sono in `EngineModels.swift`. Una modifica incompatibile richiede di
incrementare `IRUFUS_ABI_VERSION` (l'app rifiuta un motore con ABI diversa) o `REPORT_SCHEMA_VERSION`.

`ImageReport.notes` contiene codici (`noEfiLoader`, `wimWillBeSplit`, …) con argomenti; l'interfaccia li
traduce (`noteText` in `MainView.swift`).
