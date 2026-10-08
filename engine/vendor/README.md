# Vendored crates

## fatfs 0.3.6 (MIT, © Rafał Harabień)

Upstream: https://crates.io/crates/fatfs/0.3.6 — copied verbatim except for one
patch in `src/dir.rs` (`create_dir`, marked "iRufus patch"):

- the `.` and `..` entries of a new directory are written as plain short-name
  entries, without the LFN entries that 0.3.6 placed in front of them;
- `..` points to cluster 0 when the parent is the root directory
  (`FileSystem::bpb` made `pub(crate)` in `src/fs.rs` for this).

Without the patch `fsck_msdos` reports every subdirectory as damaged
("does not appear to be a subdirectory", "`..' entry has non-zero start cluster").
The test `macos_recognises_written_media` covers it.
