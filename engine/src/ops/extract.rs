//! "ISO mode": partition the device (MBR or GPT), create a FAT32 volume and
//! copy the ISO content, splitting an oversized `install.wim`, adding the
//! Windows answer file and patching Linux boot labels when needed.
//! Every copied file is re-read from the device and compared by SHA-256.

use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::path::Path;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::device::{BlockDevice, align_up};
use crate::error::{EngineError, IoContext, Result};
use crate::fat32::{self, FAT32_MAX_FILE};
use crate::hash::hex;
use crate::image::fstree::{Entry, ExtentReader};
use crate::image::{self, IsoImage};
use crate::ops::dd::sync;
use crate::partition::{self, Scheme, SinglePartitionPlan};
use crate::progress::{OpContext, Phase};
use crate::regionio::RegionIo;
use crate::wim;
use crate::wue::{self, WueOptions};

/// Size of each `.swm` part. Below 4 GiB with margin, like Rufus/wimlib usage.
pub const WIM_PART_SIZE: u64 = 3800 << 20;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractOptions {
    pub scheme: Scheme,
    #[serde(default)]
    pub cluster_size: Option<u32>,
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default)]
    pub wue: Option<WueOptions>,
    #[serde(default = "yes")]
    pub verify: bool,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractSummary {
    pub label: String,
    pub files_copied: u64,
    pub bytes_copied: u64,
    pub wim_parts: Vec<String>,
    pub patched_files: Vec<String>,
    pub answer_file: Option<String>,
    pub skipped: Vec<String>,
    pub verified: bool,
}

/// Characters that are not allowed in FAT long file names.
fn fat_component(name: &str) -> String {
    let s: String = name
        .chars()
        .map(|c| {
            if "\\/:*?\"<>|".contains(c) || c.is_control() {
                '_'
            } else {
                c
            }
        })
        .collect();
    let s = s.trim_end_matches([' ', '.']).to_string();
    if s.is_empty() { "_".into() } else { s }
}

fn fat_path(iso_path: &str) -> String {
    iso_path
        .split('/')
        .filter(|c| !c.is_empty())
        .map(fat_component)
        .collect::<Vec<_>>()
        .join("/")
}

/// Configuration files whose boot label references may need patching.
fn is_boot_config(path: &str) -> bool {
    let p = path.to_ascii_lowercase();
    (p.ends_with(".cfg") || p.ends_with(".conf"))
        && (p.starts_with("/efi/")
            || p.starts_with("/boot/")
            || p.starts_with("/isolinux/")
            || p.starts_with("/syslinux/")
            || p.starts_with("/loader/"))
}

/// Replace `LABEL=<iso label>` (raw or with spaces escaped as `\x20`) by the
/// FAT label, as Rufus does, so that live systems find their media.
pub fn patch_label(content: &str, iso_label: &str, fat_label: &str) -> Option<String> {
    if iso_label.is_empty() || iso_label == fat_label {
        return None;
    }
    let variants = [
        iso_label.to_string(),
        iso_label.replace(' ', "\\x20"),
        iso_label.replace(' ', "\\\\x20"),
    ];
    let mut out = content.to_string();
    let mut changed = false;
    for v in variants.iter().collect::<HashSet<_>>() {
        let needle = format!("LABEL={v}");
        if out.contains(&needle) {
            out = out.replace(
                &needle,
                &format!("LABEL={}", fat_label.replace(' ', "\\x20")),
            );
            changed = true;
        }
    }
    changed.then_some(out)
}

struct Planned<'a> {
    entry: &'a Entry,
    dest: String,
}

/// Space needed on FAT32 with `cluster` bytes per cluster.
fn space_needed(files: &[(u64, bool)], dirs: usize, cluster: u64) -> u64 {
    files
        .iter()
        .map(|&(s, _)| align_up(s.max(1), cluster))
        .sum::<u64>()
        + (dirs as u64 + 1) * cluster * 2
}

pub fn write_iso_extract(
    iso_path: &Path,
    dev: &dyn BlockDevice,
    opts: &ExtractOptions,
    ctx: &OpContext,
) -> Result<ExtractSummary> {
    let (iso, notes) = image::open_iso(iso_path)?;
    for n in &notes {
        ctx.log(format!("Note: {} {:?}", n.code, n.args));
    }
    let IsoImage { file, volume, tree } = &iso;
    ctx.log(format!(
        "ISO '{}' read via {:?}: {} entries",
        volume.label,
        tree.source,
        tree.entries.len()
    ));

    if !tree
        .list_dir("/efi/boot")
        .any(|e| image::efi_arch_of(e.path.rsplit('/').next().unwrap_or("")).is_some())
    {
        return Err(EngineError::Unsupported(
            "the ISO has no UEFI boot loader in /EFI/BOOT; ISO mode would not boot".into(),
        ));
    }

    // Windows install image that must be split.
    let install = tree
        .find("/sources/install.wim")
        .filter(|e| e.size > FAT32_MAX_FILE);
    if let Some(e) = tree
        .files()
        .find(|e| e.size > FAT32_MAX_FILE && install.is_none_or(|i| i.path != e.path))
    {
        return Err(EngineError::FileTooLarge {
            path: e.path.clone(),
            size: e.size,
        });
    }
    let wue_xml = match &opts.wue {
        Some(w) if !w.is_empty() => {
            if tree.find("/autounattend.xml").is_some() {
                return Err(EngineError::Unsupported(
                    "the ISO already contains an answer file (autounattend.xml)".into(),
                ));
            }
            wue::build_unattend(w)?.map(|x| (w.target_path(), x))
        }
        _ => None,
    };

    // Plan destination paths, detecting case-insensitive collisions.
    let mut seen: HashMap<String, String> = HashMap::new();
    let mut planned = Vec::new();
    let mut skipped = Vec::new();
    for e in &tree.entries {
        let dest = fat_path(&e.path);
        if dest.is_empty() {
            continue;
        }
        let key = dest.to_lowercase();
        if let Some(prev) = seen.get(&key) {
            if !e.is_dir {
                ctx.log(format!(
                    "WARNING: '{}' collides with '{}' on FAT (case-insensitive); skipped",
                    e.path, prev
                ));
                skipped.push(e.path.clone());
            }
            continue;
        }
        seen.insert(key, e.path.clone());
        planned.push(Planned { entry: e, dest });
    }

    let plan = SinglePartitionPlan::new(opts.scheme, dev.size(), dev.block_size())?;
    let cluster = opts
        .cluster_size
        .unwrap_or_else(|| fat32::default_cluster_size(plan.len).max(dev.block_size()));
    let geometry = fat32::compute_geometry(plan.len, dev.block_size(), cluster, 0)?;
    let file_sizes: Vec<(u64, bool)> = planned
        .iter()
        .filter(|p| !p.entry.is_dir)
        .map(|p| (p.entry.size, false))
        .collect();
    let dirs = planned.iter().filter(|p| p.entry.is_dir).count();
    let needed = space_needed(&file_sizes, dirs, cluster as u64)
        + wue_xml.as_ref().map_or(0, |_| 3 * cluster as u64);
    let available = geometry.clusters as u64 * cluster as u64;
    if needed > available {
        return Err(EngineError::InsufficientSpace { needed, available });
    }

    let fat_label = fat32::sanitize_label(opts.label.as_deref().unwrap_or(&volume.label));
    ctx.log(format!(
        "Partition scheme {:?}, FAT32 cluster {} bytes, label '{}'",
        opts.scheme, cluster, fat_label
    ));

    // --- Destructive part starts here ---
    ctx.check()?;
    let t = ctx.phase(Phase::Partitioning, 0);
    partition::wipe_labels(dev)?;
    partition::write_single(dev, &plan, 0x0C, "Main Data Partition")?;
    t.finish();
    let t = ctx.phase(Phase::Formatting, 0);
    fat32::format(dev, plan.start, plan.len, Some(cluster), &fat_label)?;
    t.finish();

    let total_bytes: u64 = planned
        .iter()
        .filter(|p| !p.entry.is_dir)
        .map(|p| p.entry.size)
        .sum();
    let mut expected: Vec<(String, String, u64)> = Vec::new();
    let mut wim_parts = Vec::new();
    let mut patched = Vec::new();
    let mut files_copied = 0u64;
    {
        let io = RegionIo::new(dev, plan.start, plan.len)
            .ctx("opening FAT region")?
            .with_cancel(ctx.cancel.clone());
        let fs = fat32::mount(io)?;
        let root = fs.root_dir();
        let mut tracker = ctx.phase(Phase::CopyingFiles, total_bytes);
        let mut buf = vec![0u8; 1 << 20];
        for p in &planned {
            ctx.check()?;
            let e = p.entry;
            if e.is_dir {
                root.create_dir(&p.dest)
                    .ctx(format!("creating directory {}", p.dest))?;
                continue;
            }
            if install.is_some_and(|i| i.path == e.path) {
                // install.wim → install.swm, install2.swm, ...
                let mut src = ExtentReader::new(file, &e.extents, e.size);
                let split = wim::plan_split(&mut src, WIM_PART_SIZE)?;
                ctx.log(format!(
                    "Splitting {} ({} bytes) into {} parts",
                    e.path,
                    e.size,
                    split.part_count()
                ));
                let dir = p
                    .dest
                    .rsplit_once('/')
                    .map(|(d, _)| d.to_string())
                    .unwrap_or_default();
                for part in 1..=split.part_count() {
                    let name = wim::part_name("install", part);
                    let dest = if dir.is_empty() {
                        name.clone()
                    } else {
                        format!("{dir}/{name}")
                    };
                    let mut f = root.create_file(&dest).ctx(format!("creating {dest}"))?;
                    let mut hw = HashingWriter {
                        inner: &mut f,
                        hasher: Sha256::new(),
                        count: 0,
                    };
                    let mut src_bytes = 0u64;
                    wim::write_part(&split, part, &mut src, &mut hw, ctx, &mut |n| {
                        src_bytes += n;
                    })?;
                    tracker.advance(src_bytes.min(e.size));
                    let digest = hex(&hw.hasher.finalize());
                    let count = hw.count;
                    if let Some(ts) = e.mtime {
                        set_times(&mut f, ts);
                    }
                    f.flush().ctx("flushing WIM part")?;
                    expected.push((dest.clone(), digest, count));
                    wim_parts.push(format!("/{dest}"));
                    files_copied += 1;
                }
                continue;
            }
            let mut src = ExtentReader::new(file, &e.extents, e.size);
            let mut f = root
                .create_file(&p.dest)
                .ctx(format!("creating {}", p.dest))?;
            let mut hasher = Sha256::new();
            let mut written = 0u64;
            let small_config = is_boot_config(&e.path) && e.size <= 1 << 20;
            if small_config {
                let mut content = Vec::new();
                src.read_to_end(&mut content)
                    .ctx(format!("reading {} from ISO", e.path))?;
                let data = match std::str::from_utf8(&content)
                    .ok()
                    .and_then(|t| patch_label(t, &volume.label, &fat_label))
                {
                    Some(new) => {
                        ctx.log(format!("Patched boot label in {}", e.path));
                        patched.push(e.path.clone());
                        new.into_bytes()
                    }
                    None => content,
                };
                f.write_all(&data).ctx(format!("writing {}", p.dest))?;
                hasher.update(&data);
                written = data.len() as u64;
                tracker.advance(e.size);
            } else {
                loop {
                    let n = src
                        .read(&mut buf)
                        .ctx(format!("reading {} from ISO", e.path))?;
                    if n == 0 {
                        break;
                    }
                    f.write_all(&buf[..n]).ctx(format!("writing {}", p.dest))?;
                    hasher.update(&buf[..n]);
                    written += n as u64;
                    tracker.advance(n as u64);
                }
                if written != e.size {
                    return Err(EngineError::CorruptImage(format!(
                        "{}: read {written} of {} bytes",
                        e.path, e.size
                    )));
                }
            }
            if let Some(ts) = e.mtime {
                set_times(&mut f, ts);
            }
            f.flush().ctx("flushing file")?;
            expected.push((p.dest.clone(), hex(&hasher.finalize()), written));
            files_copied += 1;
        }
        tracker.finish();

        if let Some((target, xml)) = &wue_xml {
            let dest = target.trim_start_matches('/');
            if let Some((dir, _)) = dest.rsplit_once('/') {
                let mut acc = String::new();
                for comp in dir.split('/') {
                    acc = if acc.is_empty() {
                        comp.to_string()
                    } else {
                        format!("{acc}/{comp}")
                    };
                    root.create_dir(&acc).ctx(format!("creating {acc}"))?;
                }
            }
            let mut f = root.create_file(dest).ctx(format!("creating {dest}"))?;
            f.write_all(xml.as_bytes()).ctx("writing answer file")?;
            f.flush().ctx("flushing answer file")?;
            expected.push((
                dest.to_string(),
                crate::hash::sha256_of(xml.as_bytes()),
                xml.len() as u64,
            ));
            if let Some(w) = &opts.wue {
                ctx.log(format!(
                    "Windows answer file written to {target}: {}",
                    wue::describe(w).join(", ")
                ));
            }
        }
        drop(root);
        let t = ctx.phase(Phase::Finalizing, 0);
        fs.unmount().ctx("finalising FAT32 volume")?;
        t.finish();
    }
    sync(dev, ctx)?;

    let mut verified = false;
    if opts.verify {
        verify_files(dev, &plan, &expected, ctx)?;
        if opts.scheme == Scheme::Gpt {
            partition::validate_gpt(dev)?;
        }
        verified = true;
        ctx.log(format!("Verified {} files on the device", expected.len()));
    }
    let bytes_copied = expected.iter().map(|e| e.2).sum();
    Ok(ExtractSummary {
        label: fat_label,
        files_copied,
        bytes_copied,
        wim_parts,
        patched_files: patched,
        answer_file: wue_xml.map(|(t, _)| t.to_string()),
        skipped,
        verified,
    })
}

/// fatfs deprecates these setters in favour of a custom `TimeProvider`, but
/// they still work when called after the last write and before `flush`.
#[allow(deprecated)]
fn set_times<T: fatfs::ReadWriteSeek>(
    f: &mut fatfs::File<'_, T>,
    ts: crate::image::fstree::Timestamp,
) {
    f.set_modified(fat32::fat_datetime(ts));
    f.set_created(fat32::fat_datetime(ts));
}

struct HashingWriter<'a, W: Write> {
    inner: &'a mut W,
    hasher: Sha256,
    count: u64,
}

impl<W: Write> Write for HashingWriter<'_, W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let n = self.inner.write(buf)?;
        self.hasher.update(&buf[..n]);
        self.count += n as u64;
        Ok(n)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

/// Re-read every file from a freshly mounted volume (no cached data).
fn verify_files(
    dev: &dyn BlockDevice,
    plan: &SinglePartitionPlan,
    expected: &[(String, String, u64)],
    ctx: &OpContext,
) -> Result<()> {
    let io = RegionIo::new(dev, plan.start, plan.len).ctx("opening FAT region")?;
    let fs = fat32::mount(io)?;
    let root = fs.root_dir();
    let total: u64 = expected.iter().map(|e| e.2).sum();
    let mut tracker = ctx.phase(Phase::Verifying, total);
    let mut buf = vec![0u8; 1 << 20];
    for (path, digest, size) in expected {
        ctx.check()?;
        let mut f = root
            .open_file(path)
            .map_err(|e| EngineError::VerifyFailed(format!("{path} missing on device: {e}")))?;
        let mut hasher = Sha256::new();
        let mut n_total = 0u64;
        loop {
            let n = f.read(&mut buf).ctx(format!("reading back {path}"))?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
            n_total += n as u64;
            tracker.advance(n as u64);
        }
        if n_total != *size || hex(&hasher.finalize()) != *digest {
            return Err(EngineError::VerifyFailed(format!(
                "{path} differs on the device"
            )));
        }
    }
    tracker.finish();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fat_names_are_cleaned() {
        assert_eq!(fat_path("/a:b/c*d.txt"), "a_b/c_d.txt");
        assert_eq!(fat_path("/dir./file. "), "dir/file");
        assert_eq!(fat_path("/EFI/BOOT/BOOTX64.EFI"), "EFI/BOOT/BOOTX64.EFI");
    }

    #[test]
    fn label_patching() {
        let cfg =
            "linux /images/pxeboot/vmlinuz root=live:CDLABEL=Fedora-WS-Live-40 rd.live.image\n";
        let out = patch_label(cfg, "Fedora-WS-Live-40", "FEDORA-WS-L").unwrap();
        assert!(out.contains("CDLABEL=FEDORA-WS-L "));
        let spaced = "search --label 'My Distro' ; linux /vmlinuz root=LABEL=My\\x20Distro\n";
        let out = patch_label(spaced, "My Distro", "MY DISTRO").unwrap();
        assert!(out.contains("LABEL=MY\\x20DISTRO"));
        assert!(patch_label("nothing here", "X", "Y").is_none());
        assert!(patch_label("LABEL=SAME", "SAME", "SAME").is_none());
    }

    #[test]
    fn boot_config_detection() {
        assert!(is_boot_config("/EFI/BOOT/grub.cfg"));
        assert!(is_boot_config("/boot/grub/loopback.cfg"));
        assert!(is_boot_config("/isolinux/isolinux.cfg"));
        assert!(!is_boot_config("/casper/filesystem.squashfs"));
        assert!(!is_boot_config("/README.cfg"));
    }
}
