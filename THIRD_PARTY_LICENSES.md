# Componenti di terze parti / Third-party components

iRufus è distribuito con licenza GPL-3.0-or-later (vedi `LICENSE`). Il motore Rust include staticamente
i crate seguenti (grafo risolto per macOS, solo dipendenze di runtime); tutte le licenze sono compatibili
con la GPL-3.0. Generato da `scripts/third-party.py`.

| Crate | Versione | Licenza | Repository |
|---|---|---|---|
| adler2 | 2.0.1 | 0BSD OR MIT OR Apache-2.0 | https://github.com/oyvindln/adler2 |
| bitflags | 1.3.2 | MIT/Apache-2.0 | https://github.com/bitflags/bitflags |
| block-buffer | 0.12.1 | MIT OR Apache-2.0 | https://github.com/RustCrypto/utils |
| bumpalo | 3.20.3 | MIT OR Apache-2.0 | https://github.com/fitzgen/bumpalo |
| byteorder | 1.5.0 | Unlicense OR MIT | https://github.com/BurntSushi/byteorder |
| bzip2 | 0.6.1 | MIT OR Apache-2.0 | https://github.com/trifectatechfoundation/bzip2-rs |
| cfg-if | 1.0.5 | MIT OR Apache-2.0 | https://github.com/rust-lang/cfg-if |
| const-oid | 0.10.2 | Apache-2.0 OR MIT | https://github.com/RustCrypto/formats |
| cpufeatures | 0.3.1 | MIT OR Apache-2.0 | https://github.com/RustCrypto/utils |
| crc32fast | 1.5.2 | MIT OR Apache-2.0 | https://github.com/srijs/rust-crc32fast |
| crypto-common | 0.2.2 | MIT OR Apache-2.0 | https://github.com/RustCrypto/traits |
| digest | 0.11.3 | MIT OR Apache-2.0 | https://github.com/RustCrypto/traits |
| equivalent | 1.0.2 | Apache-2.0 OR MIT | https://github.com/indexmap-rs/equivalent |
| fatfs | 0.3.6 | MIT | https://github.com/rafalh/rust-fatfs |
| flate2 | 1.1.10 | MIT OR Apache-2.0 | https://github.com/rust-lang/flate2-rs |
| hashbrown | 0.17.1 | MIT OR Apache-2.0 | https://github.com/rust-lang/hashbrown |
| hybrid-array | 0.4.15 | MIT OR Apache-2.0 | https://github.com/RustCrypto/hybrid-array |
| indexmap | 2.14.2 | Apache-2.0 OR MIT | https://github.com/indexmap-rs/indexmap |
| itoa | 1.0.18 | MIT OR Apache-2.0 | https://github.com/dtolnay/itoa |
| libbz2-rs-sys | 0.2.5 | bzip2-1.0.6 | https://github.com/trifectatechfoundation/libbzip2-rs |
| libc | 0.2.190 | MIT OR Apache-2.0 | https://github.com/rust-lang/libc |
| log | 0.4.34 | MIT OR Apache-2.0 | https://github.com/rust-lang/log |
| lzma-sys | 0.1.20 | MIT/Apache-2.0 | https://github.com/alexcrichton/xz2-rs |
| md-5 | 0.11.0 | MIT OR Apache-2.0 | https://github.com/RustCrypto/hashes |
| memchr | 2.8.3 | Unlicense OR MIT | https://github.com/BurntSushi/memchr |
| miniz_oxide | 0.9.1 | MIT OR Zlib OR Apache-2.0 | https://github.com/Frommi/miniz_oxide/tree/master/miniz_oxide |
| proc-macro2 | 1.0.107 | MIT OR Apache-2.0 | https://github.com/dtolnay/proc-macro2 |
| quote | 1.0.47 | MIT OR Apache-2.0 | https://github.com/dtolnay/quote |
| serde | 1.0.229 | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| serde_core | 1.0.229 | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| serde_derive | 1.0.229 | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| serde_json | 1.0.151 | MIT OR Apache-2.0 | https://github.com/serde-rs/json |
| sha1 | 0.11.0 | MIT OR Apache-2.0 | https://github.com/RustCrypto/hashes |
| sha2 | 0.11.0 | MIT OR Apache-2.0 | https://github.com/RustCrypto/hashes |
| simd-adler32 | 0.3.10 | MIT | https://github.com/mcountryman/simd-adler32 |
| syn | 3.0.6 | MIT OR Apache-2.0 | https://github.com/dtolnay/syn |
| thiserror | 2.0.21 | MIT OR Apache-2.0 | https://github.com/dtolnay/thiserror |
| thiserror-impl | 2.0.21 | MIT OR Apache-2.0 | https://github.com/dtolnay/thiserror |
| typed-path | 0.12.3 | MIT OR Apache-2.0 | https://github.com/chipsenkbeil/typed-path |
| typenum | 1.20.1 | MIT OR Apache-2.0 | https://github.com/paholg/typenum |
| unicode-ident | 1.0.26 | (MIT OR Apache-2.0) AND Unicode-3.0 | https://github.com/dtolnay/unicode-ident |
| xz2 | 0.1.7 | MIT/Apache-2.0 | https://github.com/alexcrichton/xz2-rs |
| zip | 8.6.0 | MIT | https://github.com/zip-rs/zip2 |
| zlib-rs | 0.6.8 | Zlib | https://github.com/trifectatechfoundation/zlib-rs |
| zmij | 1.0.23 | MIT | https://github.com/dtolnay/zmij |
| zopfli | 0.8.3 | Apache-2.0 | https://github.com/zopfli-rs/zopfli |
| zstd | 0.13.3 | MIT | https://github.com/gyscos/zstd-rs |
| zstd | 0.14.0 | BSD-3-Clause | https://github.com/gyscos/zstd-rs |
| zstd-safe | 7.3.0 | BSD-3-Clause | https://github.com/gyscos/zstd-rs |
| zstd-safe | 8.0.0 | BSD-3-Clause | https://github.com/gyscos/zstd-rs |
| zstd-sys | 2.1.0+zstd.1.5.7 | BSD-3-Clause | https://github.com/gyscos/zstd-rs |

## Note

- **fatfs 0.3.6** (MIT) è incluso in `engine/vendor/fatfs` con una patch documentata in `engine/vendor/README.md`.
- **liblzma** (0BSD / pubblico dominio), **zstd** (BSD-3-Clause) e **libbzip2** (licenza bzip2, tipo BSD) sono compilati staticamente dai crate `*-sys`.
- La logica e i contenuti del file di risposta Windows sono portati da **Rufus** (GPL-3.0-or-later, © Pete Batard / Akeo Consulting).
- L'icona dell'applicazione (`app/Resources/AppIcon.icns`) è l'icona di **Rufus** (`res/icons/rufus-512.png`), di pubblico dominio, per gentile concessione di PC Unleashed.
- Strumenti usati solo nei test e non distribuiti: `wimlib-imagex` (GPL-3.0-or-later), `hdiutil` e `fsck_msdos` di macOS.
- Nessun binario Microsoft, firmware, boot loader (GRUB, Syslinux, FreeDOS, UEFI:NTFS) o script remoto è incluso o scaricato.
