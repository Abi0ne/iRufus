# Changelog

## 0.1.0 — 2026-10-08
Prima versione.
- Motore Rust: ISO 9660/Joliet/Rock Ridge/UDF/El Torito, WIM, MBR/GPT; gz/xz/zstd/bz2/zip, VHD fisso.
- Scrittura DD e modalità ISO (GPT/MBR + FAT32, solo UEFI) con verifica di rilettura; split di install.wim.
- File di risposta Windows (bypass TPM/Secure Boot/RAM, niente account Microsoft, account locale, privacy, BitLocker, impostazioni regionali).
- Checksum MD5/SHA-1/SHA-256/SHA-512, bad blocks con rilevamento capacità contraffatta, azzeramento, salvataggio .img/.vhd.
- App SwiftUI (macOS 14+): Disk Arbitration, accesso privilegiato via authopen, conferma rinforzata, log senza dati personali, italiano e inglese.
- Non ancora provata su hardware fisico (vedi docs/TEST_MANUALI.md).
