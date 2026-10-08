//! Image analysis: what an image is, how it can be written, and for which
//! firmware targets the result is expected to boot.

pub mod fstree;
pub mod iso9660;
pub mod source;
pub mod udf;

use std::fs::File;
use std::path::Path;

use serde::Serialize;

use crate::error::{EngineError, Result};
use crate::fat32::FAT32_MAX_FILE;
use crate::partition::{Layout, parse_layout};
use crate::wim::{self, WimInfo};
use fstree::{ExtentReader, FsTree, TreeSource};
use iso9660::{ElTorito, IsoVolume};
use source::{Container, SourceInfo};

pub const REPORT_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ImageKind {
    Iso,
    DiskImage,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WriteMode {
    /// Bit-for-bit copy of the image to the whole device.
    Dd,
    /// Partition + FAT32 + copy files from the ISO (UEFI boot).
    IsoExtract,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum NoteLevel {
    Info,
    Warning,
    Error,
}

/// A localisable message: the UI maps `code` to a translated string and
/// substitutes `args` in order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Note {
    pub level: NoteLevel,
    pub code: String,
    pub args: Vec<String>,
}

fn note(level: NoteLevel, code: &str, args: &[&str]) -> Note {
    Note {
        level,
        code: code.into(),
        args: args.iter().map(|s| s.to_string()).collect(),
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileRef {
    pub path: String,
    pub size: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EfiLoader {
    pub path: String,
    pub arch: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowsReport {
    pub install_image: Option<FileRef>,
    pub wim: Option<WimInfo>,
    pub is_windows11: bool,
    pub needs_wim_split: bool,
    pub has_boot_wim: bool,
    pub has_existing_answer_file: bool,
    /// Windows architecture for unattend.xml (`amd64`, `arm64`, `x86`).
    pub unattend_arch: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LinuxReport {
    pub distro_hint: Option<String>,
    pub casper: bool,
    pub debian_live: bool,
    pub syslinux: bool,
    pub grub: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IsoReport {
    pub tree_source: TreeSource,
    pub has_joliet: bool,
    pub has_rock_ridge: bool,
    pub has_udf: bool,
    pub el_torito: ElTorito,
    pub isohybrid: bool,
    pub file_count: u64,
    pub dir_count: u64,
    pub total_file_bytes: u64,
    pub largest_file: Option<FileRef>,
    pub oversized_files: Vec<FileRef>,
    pub efi_loaders: Vec<EfiLoader>,
    pub windows: Option<WindowsReport>,
    pub linux: Option<LinuxReport>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageReport {
    pub schema_version: u32,
    pub path: String,
    pub file_name: String,
    pub source: SourceInfo,
    pub kind: ImageKind,
    pub label: Option<String>,
    /// Bytes that DD mode writes to the device (None if unknown).
    pub image_size: Option<u64>,
    pub iso: Option<IsoReport>,
    pub layout: Option<Layout>,
    pub architectures: Vec<String>,
    pub modes: Vec<WriteMode>,
    pub recommended_mode: Option<WriteMode>,
    /// Firmware targets expected to boot the result of each mode.
    pub dd_targets: Vec<String>,
    pub extract_targets: Vec<String>,
    pub notes: Vec<Note>,
}

/// Opened ISO, kept by write operations (tree already built).
pub struct IsoImage {
    pub file: File,
    pub volume: IsoVolume,
    pub tree: FsTree,
}

pub fn efi_arch_of(file_name: &str) -> Option<&'static str> {
    match file_name.to_ascii_lowercase().as_str() {
        "bootx64.efi" => Some("x64"),
        "bootia32.efi" => Some("ia32"),
        "bootaa64.efi" => Some("arm64"),
        "bootarm.efi" => Some("arm"),
        "bootriscv64.efi" => Some("riscv64"),
        "bootloongarch64.efi" => Some("loongarch64"),
        _ => None,
    }
}

/// Open an uncompressed ISO and build its file tree (UDF preferred when the
/// ISO 9660 view cannot represent the content, i.e. Windows media).
pub fn open_iso(path: &Path) -> Result<(IsoImage, Vec<Note>)> {
    let file =
        File::open(path).map_err(|e| EngineError::io(format!("opening {}", path.display()), e))?;
    if !iso9660::probe(&file) {
        return Err(EngineError::UnsupportedImage(
            "not an ISO 9660 image".into(),
        ));
    }
    let volume = IsoVolume::open(&file)?;
    let mut notes = Vec::new();
    let mut tree = if volume.has_rock_ridge {
        volume.tree(&file)?
    } else if volume.has_udf {
        match udf::UdfVolume::open(&file).and_then(|u| u.tree(&file)) {
            Ok(t) => t,
            Err(e) => {
                notes.push(note(NoteLevel::Warning, "udfFallback", &[&e.to_string()]));
                volume.tree(&file)?
            }
        }
    } else {
        volume.tree(&file)?
    };
    let resolved = tree.resolve_symlinks();
    if !resolved.is_empty() {
        let dropped = resolved.iter().filter(|r| r.1.is_none()).count();
        notes.push(note(
            NoteLevel::Info,
            "symlinksResolved",
            &[
                &(resolved.len() - dropped).to_string(),
                &dropped.to_string(),
            ],
        ));
    }
    Ok((IsoImage { file, volume, tree }, notes))
}

pub fn analyze(path: &Path) -> Result<ImageReport> {
    let source = source::probe(path)?;
    let file_name = path
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    let mut notes = Vec::new();
    let head = source::read_head(path, &source, 64 * 1024)?;
    if head.len() < 512 {
        return Err(EngineError::UnsupportedImage(
            "image is smaller than one sector".into(),
        ));
    }
    let layout = parse_layout(&head, 512);
    let is_iso = head.len() >= 0x8006 && &head[0x8001..0x8006] == b"CD001";
    let image_size = source.data_size.filter(|_| source.size_is_exact);
    if source.container.is_compressed() && !source.size_is_exact {
        notes.push(note(NoteLevel::Info, "sizeUnknown", &[]));
    }

    let mut report = ImageReport {
        schema_version: REPORT_SCHEMA_VERSION,
        path: path.to_string_lossy().into(),
        file_name,
        source: source.clone(),
        kind: if is_iso {
            ImageKind::Iso
        } else {
            ImageKind::DiskImage
        },
        label: None,
        image_size,
        iso: None,
        layout: Some(layout.clone()).filter(|l| l.scheme.is_some()),
        architectures: vec![],
        modes: vec![],
        recommended_mode: None,
        dd_targets: vec![],
        extract_targets: vec![],
        notes: vec![],
    };

    let hybrid = layout.scheme.is_some();
    if !is_iso {
        report.modes.push(WriteMode::Dd);
        report.recommended_mode = Some(WriteMode::Dd);
        if !layout.has_boot_signature {
            notes.push(note(NoteLevel::Warning, "noBootSignature", &[]));
        } else {
            report.dd_targets = dd_targets(&layout, None);
        }
        report.notes = notes;
        return Ok(report);
    }

    if source.container != Container::Raw {
        // A compressed ISO cannot be browsed without decompressing it first.
        notes.push(note(NoteLevel::Info, "compressedIsoDdOnly", &[]));
        if hybrid {
            report.modes.push(WriteMode::Dd);
            report.recommended_mode = Some(WriteMode::Dd);
            report.dd_targets = dd_targets(&layout, None);
        } else {
            notes.push(note(NoteLevel::Error, "notHybridIso", &[]));
        }
        report.notes = notes;
        return Ok(report);
    }

    let (iso, mut open_notes) = open_iso(path)?;
    notes.append(&mut open_notes);
    let et = iso.volume.el_torito(&iso.file)?;
    let tree = &iso.tree;
    report.label = Some(iso.volume.label.clone()).filter(|l| !l.is_empty());

    let mut efi_loaders = Vec::new();
    for e in tree.list_dir("/efi/boot") {
        let name = e.path.rsplit('/').next().unwrap_or("");
        if let Some(arch) = efi_arch_of(name)
            && !e.is_dir
            && e.size > 0
        {
            efi_loaders.push(EfiLoader {
                path: e.path.clone(),
                arch: arch.into(),
            });
        }
    }
    let files: Vec<_> = tree.files().collect();
    let largest = files.iter().max_by_key(|e| e.size).map(|e| FileRef {
        path: e.path.clone(),
        size: e.size,
    });
    let oversized: Vec<FileRef> = files
        .iter()
        .filter(|e| e.size > FAT32_MAX_FILE)
        .map(|e| FileRef {
            path: e.path.clone(),
            size: e.size,
        })
        .collect();

    // Windows detection.
    let install = [
        "/sources/install.wim",
        "/sources/install.esd",
        "/sources/install.swm",
    ]
    .iter()
    .find_map(|p| tree.find(p));
    let is_windows = install.is_some()
        || (tree.find("/bootmgr").is_some() && tree.find("/sources/boot.wim").is_some());
    let mut windows = None;
    if is_windows {
        let wim_info = install.and_then(|e| {
            let mut r = ExtentReader::new(&iso.file, &e.extents, e.size);
            match wim::inspect(&mut r) {
                Ok(i) => Some(i),
                Err(err) => {
                    notes.push(note(
                        NoteLevel::Warning,
                        "wimUnreadable",
                        &[&err.to_string()],
                    ));
                    None
                }
            }
        });
        let is_win11 = wim_info.as_ref().is_some_and(|w| {
            w.images.iter().any(|i| {
                let n = i.name.to_ascii_lowercase();
                n.contains("windows 11") || (i.build.unwrap_or(0) >= 22000 && !n.contains("server"))
            })
        });
        let unattend_arch = wim_info
            .as_ref()
            .and_then(|w| w.images.first())
            .and_then(|i| i.arch.as_deref())
            .and_then(|a| match a {
                "x64" => Some("amd64"),
                "arm64" => Some("arm64"),
                "x86" => Some("x86"),
                _ => None,
            })
            .map(String::from);
        let needs_split = install.is_some_and(|e| e.size > FAT32_MAX_FILE);
        windows = Some(WindowsReport {
            install_image: install.map(|e| FileRef {
                path: e.path.clone(),
                size: e.size,
            }),
            is_windows11: is_win11,
            needs_wim_split: needs_split,
            has_boot_wim: tree.find("/sources/boot.wim").is_some(),
            has_existing_answer_file: tree.find("/autounattend.xml").is_some(),
            unattend_arch,
            wim: wim_info,
        });
    }

    let linux = if !is_windows {
        let casper = tree.find("/casper").is_some_and(|e| e.is_dir);
        let debian_live = tree.find("/live").is_some_and(|e| e.is_dir);
        let syslinux = tree.find("/isolinux").is_some()
            || tree.find("/syslinux").is_some()
            || tree.find("/boot/syslinux").is_some();
        let grub = tree.find("/boot/grub").is_some() || tree.find("/efi/boot/grub.cfg").is_some();
        let distro_hint = tree.find("/.disk/info").and_then(|e| {
            if e.size > 4096 {
                return None;
            }
            let mut buf = Vec::new();
            use std::io::Read;
            ExtentReader::new(&iso.file, &e.extents, e.size)
                .read_to_end(&mut buf)
                .ok()?;
            Some(String::from_utf8_lossy(&buf).trim().to_string()).filter(|s| !s.is_empty())
        });
        (casper || debian_live || syslinux || grub).then_some(LinuxReport {
            distro_hint,
            casper,
            debian_live,
            syslinux,
            grub,
        })
    } else {
        None
    };

    let mut archs: Vec<String> = efi_loaders.iter().map(|l| l.arch.clone()).collect();
    if let Some(a) = windows
        .as_ref()
        .and_then(|w| w.wim.as_ref())
        .and_then(|w| w.images.first())
        .and_then(|i| i.arch.clone())
        && !archs.contains(&a)
    {
        archs.push(a);
    }
    report.architectures = archs;

    // Mode selection.
    let wim_splittable = windows.as_ref().is_some_and(|w| {
        w.needs_wim_split
            && w.wim.as_ref().is_some_and(|i| !i.solid)
            && w.install_image
                .as_ref()
                .is_some_and(|f| f.path.to_ascii_lowercase().ends_with(".wim"))
    });
    let other_oversized: Vec<&FileRef> = oversized
        .iter()
        .filter(|f| {
            !(wim_splittable
                && windows
                    .as_ref()
                    .and_then(|w| w.install_image.as_ref())
                    .is_some_and(|i| i.path == f.path))
        })
        .collect();
    let mut extract_ok = !efi_loaders.is_empty();
    if efi_loaders.is_empty() {
        if et.efi_bootable {
            notes.push(note(NoteLevel::Warning, "efiOnlyInElTorito", &[]));
        } else {
            notes.push(note(NoteLevel::Warning, "noEfiLoader", &[]));
        }
    }
    for f in &other_oversized {
        extract_ok = false;
        notes.push(note(
            NoteLevel::Error,
            "fileTooLargeForFat32",
            &[&f.path, &f.size.to_string()],
        ));
    }
    if wim_splittable {
        notes.push(note(NoteLevel::Info, "wimWillBeSplit", &[]));
    }
    if windows.as_ref().is_some_and(|w| w.has_existing_answer_file) {
        notes.push(note(NoteLevel::Info, "existingAnswerFile", &[]));
    }
    if hybrid {
        report.modes.push(WriteMode::Dd);
        report.dd_targets = dd_targets(&layout, Some(&et));
    } else {
        notes.push(note(NoteLevel::Info, "notHybridIso", &[]));
    }
    if extract_ok {
        report.modes.push(WriteMode::IsoExtract);
        report.extract_targets = efi_loaders
            .iter()
            .map(|l| format!("uefi-{}", l.arch))
            .collect();
        report.extract_targets.dedup();
        notes.push(note(NoteLevel::Info, "isoModeUefiOnly", &[]));
    }
    report.recommended_mode = if windows.is_some() && extract_ok {
        Some(WriteMode::IsoExtract)
    } else if hybrid {
        if linux.is_some() && extract_ok {
            notes.push(note(NoteLevel::Info, "ddRecommendedLinux", &[]));
        }
        Some(WriteMode::Dd)
    } else if extract_ok {
        Some(WriteMode::IsoExtract)
    } else {
        None
    };
    if report.modes.is_empty() {
        notes.push(note(NoteLevel::Error, "noUsableMode", &[]));
    }

    report.iso = Some(IsoReport {
        tree_source: tree.source,
        has_joliet: iso.volume.joliet_root.is_some(),
        has_rock_ridge: iso.volume.has_rock_ridge,
        has_udf: iso.volume.has_udf,
        el_torito: et,
        isohybrid: hybrid,
        file_count: files.len() as u64,
        dir_count: tree.entries.iter().filter(|e| e.is_dir).count() as u64,
        total_file_bytes: tree.total_file_bytes(),
        largest_file: largest,
        oversized_files: oversized,
        efi_loaders,
        windows,
        linux,
    });
    report.notes = notes;
    Ok(report)
}

/// Expected boot targets for a DD-written image, from its partition table and
/// (for ISOs) El Torito catalog.
fn dd_targets(layout: &Layout, et: Option<&ElTorito>) -> Vec<String> {
    let mut t = Vec::new();
    if layout.has_mbr_boot_code && layout.has_boot_signature {
        t.push("bios".to_string());
    }
    let has_esp = layout.partitions.iter().any(|p| {
        p.type_id == "0xEF"
            || p.type_id.eq_ignore_ascii_case(crate::partition::GUID_ESP)
            || p.type_id == "0x0C"
            || p.type_id == "0x0B"
    });
    if has_esp || et.is_some_and(|e| e.efi_bootable) {
        t.push("uefi".to_string());
    }
    t
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn efi_arch_names() {
        assert_eq!(efi_arch_of("BOOTX64.EFI"), Some("x64"));
        assert_eq!(efi_arch_of("bootaa64.efi"), Some("arm64"));
        assert_eq!(efi_arch_of("grubx64.efi"), None);
    }

    #[test]
    fn raw_disk_image_without_signature_is_dd_with_warning() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("data.img");
        std::fs::write(&p, vec![0u8; 1 << 20]).unwrap();
        let r = analyze(&p).unwrap();
        assert_eq!(r.kind, ImageKind::DiskImage);
        assert_eq!(r.modes, vec![WriteMode::Dd]);
        assert!(r.notes.iter().any(|n| n.code == "noBootSignature"));
        assert_eq!(r.image_size, Some(1 << 20));
    }

    #[test]
    fn tiny_file_is_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("tiny.img");
        std::fs::write(&p, b"abc").unwrap();
        assert!(matches!(analyze(&p), Err(EngineError::UnsupportedImage(_))));
    }
}
