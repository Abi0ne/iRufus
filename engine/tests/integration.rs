//! Integration tests on reproducible fixtures built at test time with macOS
//! tools (`hdiutil makehybrid`, `hdiutil attach -nomount`, `fsck_msdos`) and,
//! when installed, `wimlib-imagex` as an independent WIM oracle.
//! No test touches a real disk: devices are image files or RAM-less virtual
//! disks attached without mounting.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use irufus_engine::device::{BlockDevice, FileDevice};
use irufus_engine::error::EngineError;
use irufus_engine::fat32;
use irufus_engine::image::{self, ImageKind, WriteMode, source};
use irufus_engine::ops::{dd, extract};
use irufus_engine::partition::{self, MIB, Scheme, SinglePartitionPlan};
use irufus_engine::progress::{CancelToken, NullSink, OpContext};
use irufus_engine::regionio::RegionIo;
use irufus_engine::wim;
use irufus_engine::wue::WueOptions;

fn ctx() -> OpContext<'static> {
    OpContext::new(&NullSink, CancelToken::new())
}

fn run(cmd: &mut Command) -> String {
    let out = cmd.output().expect("spawn");
    assert!(
        out.status.success(),
        "{:?} failed: {}{}",
        cmd,
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).to_string()
}

fn has_tool(path: &str) -> bool {
    Path::new(path).exists()
}

fn pseudo_random(len: usize, seed: u32) -> Vec<u8> {
    let mut x = seed.wrapping_mul(2654435761).max(1);
    (0..len)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            x as u8
        })
        .collect()
}

/// A Linux-like tree with an x64 UEFI loader and a grub.cfg referencing the ISO label.
fn linux_tree(root: &Path) {
    std::fs::create_dir_all(root.join("EFI/BOOT")).unwrap();
    std::fs::create_dir_all(root.join("boot/grub")).unwrap();
    std::fs::create_dir_all(root.join("casper")).unwrap();
    std::fs::create_dir_all(root.join("a/b/c/d/e/f")).unwrap();
    std::fs::write(root.join("EFI/BOOT/BOOTX64.EFI"), pseudo_random(300_000, 1)).unwrap();
    std::fs::write(root.join("EFI/BOOT/grub.cfg"), "search --set=root --label MY_LINUX_LIVE_2026\nlinux /casper/vmlinuz root=live:CDLABEL=MY_LINUX_LIVE_2026 quiet\n").unwrap();
    std::fs::write(root.join("boot/grub/grub.cfg"), "set default=0\n").unwrap();
    std::fs::write(
        root.join("casper/filesystem.squashfs"),
        pseudo_random(3 * MIB as usize + 123, 2),
    )
    .unwrap();
    std::fs::write(root.join("casper/empty"), b"").unwrap();
    std::fs::write(root.join("a/b/c/d/e/f/deep.txt"), b"deep").unwrap();
    std::fs::write(
        root.join("Questo è un nome di file decisamente lungo per Joliet e UDF.txt"),
        b"lungo",
    )
    .unwrap();
}

fn make_iso(src: &Path, out: &Path, label: &str, udf: bool) {
    let mut cmd = Command::new("/usr/bin/hdiutil");
    cmd.args(["makehybrid", "-ov", "-iso", "-joliet"]);
    if udf {
        cmd.args(["-udf", "-udf-version", "1.02", "-udf-volume-name", label]);
    }
    cmd.args([
        "-iso-volume-name",
        label,
        "-joliet-volume-name",
        label,
        "-o",
    ])
    .arg(out)
    .arg(src);
    run(&mut cmd);
}

/// Compare every regular file of `src` with the FAT volume on `dev`.
fn assert_volume_matches(
    dev: &FileDevice,
    plan_start: u64,
    plan_len: u64,
    src: &Path,
    skip: &[&str],
) -> usize {
    let fs = fat32::mount(RegionIo::new(dev, plan_start, plan_len).unwrap()).unwrap();
    let root = fs.root_dir();
    let mut count = 0;
    let mut stack = vec![src.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                stack.push(p);
                continue;
            }
            let rel = p.strip_prefix(src).unwrap().to_string_lossy().to_string();
            if skip.iter().any(|s| rel == *s) {
                continue;
            }
            let mut f = root
                .open_file(&rel)
                .unwrap_or_else(|e| panic!("{rel} missing: {e}"));
            let mut got = Vec::new();
            f.read_to_end(&mut got).unwrap();
            assert_eq!(got, std::fs::read(&p).unwrap(), "{rel} content");
            count += 1;
        }
    }
    count
}

#[test]
fn linux_like_iso_analysis_and_extraction_gpt_and_mbr() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("src");
    linux_tree(&src);
    for udf in [true, false] {
        let iso = dir.path().join(format!("linux-{udf}.iso"));
        make_iso(&src, &iso, "MY_LINUX_LIVE_2026", udf);

        let r = image::analyze(&iso).unwrap();
        assert_eq!(r.kind, ImageKind::Iso);
        assert_eq!(r.label.as_deref(), Some("MY_LINUX_LIVE_2026"));
        let iso_r = r.iso.as_ref().unwrap();
        assert_eq!(iso_r.has_udf, udf);
        assert_eq!(iso_r.efi_loaders.len(), 1);
        assert_eq!(iso_r.efi_loaders[0].arch, "x64");
        assert!(iso_r.linux.as_ref().unwrap().casper);
        assert!(!iso_r.isohybrid);
        assert_eq!(
            r.modes,
            vec![WriteMode::IsoExtract],
            "non-hybrid ISO: extraction only"
        );
        assert_eq!(r.extract_targets, vec!["uefi-x64"]);
        assert!(r.notes.iter().any(|n| n.code == "notHybridIso"));

        for scheme in [Scheme::Gpt, Scheme::Mbr] {
            let size = 200 * MIB;
            let dev =
                FileDevice::create(&dir.path().join(format!("dev-{udf}-{scheme:?}")), size, 512)
                    .unwrap();
            let opts = extract::ExtractOptions {
                scheme,
                cluster_size: None,
                label: None,
                wue: None,
                verify: true,
            };
            let s = extract::write_iso_extract(&iso, &dev, &opts, &ctx()).unwrap();
            assert!(s.verified);
            assert_eq!(s.label, "MY_LINUX_LI");
            assert_eq!(s.patched_files, vec!["/EFI/BOOT/grub.cfg".to_string()]);
            let plan = SinglePartitionPlan::new(scheme, size, 512).unwrap();
            let n = assert_volume_matches(&dev, plan.start, plan.len, &src, &["EFI/BOOT/grub.cfg"]);
            assert_eq!(n, 6);
            let fs = fat32::mount(RegionIo::new(&dev, plan.start, plan.len).unwrap()).unwrap();
            let mut cfg = String::new();
            fs.root_dir()
                .open_file("EFI/BOOT/grub.cfg")
                .unwrap()
                .read_to_string(&mut cfg)
                .unwrap();
            assert!(cfg.contains("CDLABEL=MY_LINUX_LI "), "{cfg}");
            assert_eq!(fs.volume_label(), "MY_LINUX_LI");
        }
    }
}

#[test]
fn extraction_refuses_small_device_before_writing() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("src");
    linux_tree(&src);
    std::fs::write(
        src.join("casper/big.bin"),
        pseudo_random(60 * MIB as usize, 9),
    )
    .unwrap();
    let iso = dir.path().join("l.iso");
    make_iso(&src, &iso, "BIG", false);
    let size = 48 * MIB;
    let dev = FileDevice::create(&dir.path().join("dev"), size, 512).unwrap();
    dev.write_at(0, &[0xCC; 512]).unwrap();
    let opts = extract::ExtractOptions {
        scheme: Scheme::Gpt,
        cluster_size: None,
        label: None,
        wue: None,
        verify: true,
    };
    let err = extract::write_iso_extract(&iso, &dev, &opts, &ctx()).unwrap_err();
    assert!(
        matches!(err, EngineError::InsufficientSpace { .. }),
        "{err:?}"
    );
    let mut s = [0u8; 512];
    dev.read_at(0, &mut s).unwrap();
    assert_eq!(s, [0xCC; 512], "nothing written when the plan does not fit");
}

#[test]
fn extraction_cancellation_returns_cancelled() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("src");
    linux_tree(&src);
    let iso = dir.path().join("l.iso");
    make_iso(&src, &iso, "X", true);
    let dev = FileDevice::create(&dir.path().join("dev"), 100 * MIB, 512).unwrap();
    let c = ctx();
    c.cancel.cancel();
    let opts = extract::ExtractOptions {
        scheme: Scheme::Gpt,
        cluster_size: None,
        label: None,
        wue: None,
        verify: true,
    };
    assert!(matches!(
        extract::write_iso_extract(&iso, &dev, &opts, &c),
        Err(EngineError::Cancelled)
    ));
}

#[test]
fn iso_without_efi_loader_is_not_extractable() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("src");
    std::fs::create_dir_all(&src).unwrap();
    std::fs::write(src.join("readme.txt"), b"data only").unwrap();
    let iso = dir.path().join("d.iso");
    make_iso(&src, &iso, "DATA", false);
    let r = image::analyze(&iso).unwrap();
    assert!(r.modes.is_empty());
    assert!(r.notes.iter().any(|n| n.code == "noEfiLoader"));
    assert!(r.notes.iter().any(|n| n.code == "noUsableMode"));
}

/// ISO made "hybrid" by placing an MBR in its (unused) system area, as isohybrid does.
#[test]
fn hybrid_iso_is_offered_dd_and_written_bit_for_bit() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("src");
    linux_tree(&src);
    let iso = dir.path().join("h.iso");
    make_iso(&src, &iso, "HYBRID", false);
    let mut bytes = std::fs::read(&iso).unwrap();
    bytes[0] = 0xEB; // boot code present
    bytes[446] = 0x80;
    bytes[446 + 4] = 0x17;
    bytes[446 + 8..446 + 12].copy_from_slice(&0u32.to_le_bytes());
    let sectors = (bytes.len() / 512) as u32;
    bytes[446 + 12..446 + 16].copy_from_slice(&sectors.to_le_bytes());
    bytes[462 + 4] = 0xEF;
    bytes[462 + 8..462 + 12].copy_from_slice(&100u32.to_le_bytes());
    bytes[462 + 12..462 + 16].copy_from_slice(&10u32.to_le_bytes());
    bytes[510] = 0x55;
    bytes[511] = 0xAA;
    std::fs::write(&iso, &bytes).unwrap();
    let r = image::analyze(&iso).unwrap();
    assert!(r.iso.as_ref().unwrap().isohybrid);
    assert_eq!(r.modes, vec![WriteMode::Dd, WriteMode::IsoExtract]);
    assert_eq!(r.recommended_mode, Some(WriteMode::Dd));
    assert_eq!(r.dd_targets, vec!["bios", "uefi"]);
    assert!(r.notes.iter().any(|n| n.code == "ddRecommendedLinux"));

    let dev = FileDevice::create(&dir.path().join("dev"), 64 * MIB, 512).unwrap();
    let info = source::probe(&iso).unwrap();
    let s = dd::write_dd(&iso, &info, &dev, true, &ctx()).unwrap();
    assert!(s.verified);
    assert_eq!(s.sha256, irufus_engine::hash::sha256_of(&bytes));

    // A compressed copy is DD-only.
    let xz = dir.path().join("h.iso.xz");
    let mut e = xz2::write::XzEncoder::new(Vec::new(), 1);
    e.write_all(&bytes).unwrap();
    std::fs::write(&xz, e.finish().unwrap()).unwrap();
    let r = image::analyze(&xz).unwrap();
    assert_eq!(r.kind, ImageKind::Iso);
    assert_eq!(r.modes, vec![WriteMode::Dd]);
    assert_eq!(r.image_size, Some(bytes.len() as u64));
}

/// Capture a real WIM with wimlib, split it with our code, and let wimlib
/// verify and apply the split set.
#[test]
fn wim_split_is_accepted_by_wimlib() {
    if !has_tool("/opt/homebrew/bin/wimlib-imagex") {
        eprintln!("wimlib-imagex not installed: skipping oracle test");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let content = dir.path().join("content");
    std::fs::create_dir_all(content.join("Windows/System32")).unwrap();
    for i in 0..12 {
        std::fs::write(
            content.join(format!("Windows/System32/file{i}.dll")),
            pseudo_random(1_500_000, i + 10),
        )
        .unwrap();
    }
    std::fs::write(
        content.join("Windows/notes.txt"),
        "repetitive ".repeat(50_000),
    )
    .unwrap();
    let wim_path = dir.path().join("install.wim");
    run(Command::new("/opt/homebrew/bin/wimlib-imagex")
        .args(["capture"])
        .arg(&content)
        .arg(&wim_path)
        .args(["Windows 11 Pro", "--compress=LZX"]));
    run(Command::new("/opt/homebrew/bin/wimlib-imagex")
        .args(["append"])
        .arg(&content)
        .arg(&wim_path)
        .args(["Windows 11 Home"]));

    let info = wim::inspect(&mut std::fs::File::open(&wim_path).unwrap()).unwrap();
    assert_eq!(info.image_count, 2);
    assert_eq!(info.images[0].name, "Windows 11 Pro");

    let out = dir.path().join("split");
    std::fs::create_dir_all(&out).unwrap();
    let parts = wim::split_to_dir(
        &mut std::fs::File::open(&wim_path).unwrap(),
        &out,
        "install",
        4 * MIB,
        &ctx(),
    )
    .unwrap();
    assert!(parts.len() >= 3, "{} parts", parts.len());
    for p in &parts {
        assert!(std::fs::metadata(p).unwrap().len() <= 4 * MIB);
    }
    let reference = format!("--ref={}/install*.swm", out.display());
    run(Command::new("/opt/homebrew/bin/wimlib-imagex")
        .arg("verify")
        .arg(&parts[0])
        .arg(&reference));
    let info_txt = run(Command::new("/opt/homebrew/bin/wimlib-imagex")
        .arg("info")
        .arg(&parts[0]));
    assert!(info_txt.contains("Windows 11 Home"));
    let applied = dir.path().join("applied");
    run(Command::new("/opt/homebrew/bin/wimlib-imagex")
        .arg("apply")
        .arg(&parts[0])
        .arg("2")
        .arg(&applied)
        .arg(&reference));
    for i in 0..12 {
        let rel = format!("Windows/System32/file{i}.dll");
        assert_eq!(
            std::fs::read(applied.join(&rel)).unwrap(),
            std::fs::read(content.join(&rel)).unwrap()
        );
    }
}

#[test]
fn windows_like_iso_with_answer_file() {
    if !has_tool("/opt/homebrew/bin/wimlib-imagex") {
        eprintln!("wimlib-imagex not installed: skipping");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("src");
    std::fs::create_dir_all(src.join("sources")).unwrap();
    std::fs::create_dir_all(src.join("efi/boot")).unwrap();
    std::fs::create_dir_all(src.join("content")).unwrap();
    std::fs::write(src.join("bootmgr"), pseudo_random(4096, 3)).unwrap();
    std::fs::write(src.join("efi/boot/bootx64.efi"), pseudo_random(8192, 4)).unwrap();
    std::fs::write(src.join("sources/boot.wim"), pseudo_random(8192, 5)).unwrap();
    std::fs::write(src.join("content/a.txt"), b"hello").unwrap();
    run(Command::new("/opt/homebrew/bin/wimlib-imagex")
        .arg("capture")
        .arg(src.join("content"))
        .arg(src.join("sources/install.wim"))
        .args([
            "Windows 11 Pro",
            "--image-property",
            "WINDOWS/ARCH=9",
            "--image-property",
            "WINDOWS/VERSION/BUILD=26100",
        ]));
    std::fs::remove_dir_all(src.join("content")).unwrap();
    let iso = dir.path().join("win.iso");
    make_iso(&src, &iso, "CCCOMA_X64FRE_IT-IT_DV9", true);

    let r = image::analyze(&iso).unwrap();
    let w = r.iso.as_ref().unwrap().windows.as_ref().unwrap();
    assert!(w.is_windows11, "{w:?}");
    assert_eq!(w.unattend_arch.as_deref(), Some("amd64"));
    assert!(!w.needs_wim_split);
    assert_eq!(r.recommended_mode, Some(WriteMode::IsoExtract));
    assert!(r.architectures.contains(&"x64".to_string()));

    let size = 128 * MIB;
    let dev = FileDevice::create(&dir.path().join("dev"), size, 512).unwrap();
    let wue = WueOptions {
        arch: "amd64".into(),
        bypass_requirements: true,
        no_online_account: true,
        ..Default::default()
    };
    let opts = extract::ExtractOptions {
        scheme: Scheme::Gpt,
        cluster_size: None,
        label: None,
        wue: Some(wue),
        verify: true,
    };
    let s = extract::write_iso_extract(&iso, &dev, &opts, &ctx()).unwrap();
    assert_eq!(s.answer_file.as_deref(), Some("/Autounattend.xml"));
    let plan = SinglePartitionPlan::new(Scheme::Gpt, size, 512).unwrap();
    let fs = fat32::mount(RegionIo::new(&dev, plan.start, plan.len).unwrap()).unwrap();
    let mut xml = String::new();
    fs.root_dir()
        .open_file("Autounattend.xml")
        .unwrap()
        .read_to_string(&mut xml)
        .unwrap();
    assert!(xml.contains("BypassTPMCheck") && xml.contains("BypassNRO"));
}

/// Attach a written image as a virtual disk (no mount) so that macOS itself
/// parses the partition table and `fsck_msdos` checks the FAT32 volume.
#[test]
fn macos_recognises_written_media() {
    if !has_tool("/sbin/fsck_msdos") {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("src");
    linux_tree(&src);
    let iso = dir.path().join("l.iso");
    make_iso(&src, &iso, "MACOS_CHECK", true);
    let img = dir.path().join("disk.img");
    let size = 160 * MIB;
    {
        let dev = FileDevice::create(&img, size, 512).unwrap();
        let opts = extract::ExtractOptions {
            scheme: Scheme::Gpt,
            cluster_size: None,
            label: None,
            wue: None,
            verify: true,
        };
        extract::write_iso_extract(&iso, &dev, &opts, &ctx()).unwrap();
    }
    let out = Command::new("/usr/bin/hdiutil")
        .args([
            "attach",
            "-nomount",
            "-imagekey",
            "diskimage-class=CRawDiskImage",
        ])
        .arg(&img)
        .output()
        .unwrap();
    if !out.status.success() {
        eprintln!(
            "hdiutil attach unavailable here: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        return;
    }
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    let whole = text
        .split_whitespace()
        .find(|t| t.starts_with("/dev/disk") && !t[9..].contains('s'))
        .unwrap()
        .to_string();
    let detach = scopeguard(whole.clone());
    assert!(text.contains("GUID_partition_scheme"), "{text}");
    assert!(text.contains("Microsoft Basic Data"), "{text}");
    let part = format!("{}s1", whole.replace("/dev/disk", "/dev/rdisk"));
    let fsck = Command::new("/sbin/fsck_msdos")
        .arg("-n")
        .arg(&part)
        .output()
        .unwrap();
    assert!(
        fsck.status.success(),
        "fsck_msdos: {}{}",
        String::from_utf8_lossy(&fsck.stdout),
        String::from_utf8_lossy(&fsck.stderr)
    );
    drop(detach);
}

struct Detach(String);
impl Drop for Detach {
    fn drop(&mut self) {
        let _ = Command::new("/usr/bin/hdiutil")
            .args(["detach", "-force", &self.0])
            .output();
    }
}
fn scopeguard(dev: String) -> Detach {
    Detach(dev)
}

#[test]
fn gpt_written_by_engine_matches_partition_plan() {
    let dir = tempfile::tempdir().unwrap();
    let dev = FileDevice::create(&dir.path().join("d"), 512 * MIB, 4096).unwrap();
    let plan = SinglePartitionPlan::new(Scheme::Gpt, dev.size(), 4096).unwrap();
    partition::write_single(&dev, &plan, 0x0C, "x").unwrap();
    partition::validate_gpt(&dev).unwrap();
    let g = fat32::format(&dev, plan.start, plan.len, None, "4K").unwrap();
    assert_eq!(g.bytes_per_sector, 4096);
    let fs = fat32::mount(RegionIo::new(&dev, plan.start, plan.len).unwrap()).unwrap();
    fs.root_dir()
        .create_file("x.bin")
        .unwrap()
        .write_all(&[1; 10_000])
        .unwrap();
}

/// Very large fixture (≈4.3 GB): ISO 9660 multi-extent/UDF file above the FAT32 limit.
/// Run with `cargo test -- --ignored`.
#[test]
#[ignore]
fn oversized_file_is_reported_and_refused() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("src");
    linux_tree(&src);
    let big = src.join("casper/huge.squashfs");
    let f = std::fs::File::create(&big).unwrap();
    f.set_len((4u64 << 30) + 4096).unwrap();
    drop(f);
    let iso = dir.path().join("big.iso");
    make_iso(&src, &iso, "BIGFILE", true);
    let r = image::analyze(&iso).unwrap();
    let iso_r = r.iso.unwrap();
    assert_eq!(iso_r.oversized_files.len(), 1);
    assert_eq!(iso_r.oversized_files[0].size, (4u64 << 30) + 4096);
    assert!(!r.modes.contains(&WriteMode::IsoExtract));
    assert!(r.notes.iter().any(|n| n.code == "fileTooLargeForFat32"));
    let _: PathBuf = big;
}

/// End-to-end on a real character device. Runs only when
/// `IRUFUS_E2E_RDISK=/dev/rdiskN` points to a virtual disk created by
/// `scripts/e2e-virtual-disk.sh` (which verifies it is an hdiutil-attached image).
#[test]
fn e2e_raw_character_device() {
    let Ok(path) = std::env::var("IRUFUS_E2E_RDISK") else {
        eprintln!("IRUFUS_E2E_RDISK not set: skipping");
        return;
    };
    assert!(path.starts_with("/dev/rdisk"), "refusing {path}");
    let iso = PathBuf::from(std::env::var("IRUFUS_E2E_ISO").expect("IRUFUS_E2E_ISO"));
    let open = |p: &str| {
        let f = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(p)
            .expect("open rdisk");
        std::os::fd::IntoRawFd::into_raw_fd(f)
    };
    // Geometry comes from the kernel (DKIOCGETBLOCKCOUNT/SIZE); a wrong expectation must be refused.
    let probe = unsafe { irufus_engine::device::FdDevice::from_raw_fd(open(&path), 0, 0) }.unwrap();
    let (size, bs) = (probe.size(), probe.block_size());
    drop(probe);
    assert!(
        unsafe { irufus_engine::device::FdDevice::from_raw_fd(open(&path), size - 512, bs) }
            .is_err()
    );
    let dev =
        unsafe { irufus_engine::device::FdDevice::from_raw_fd(open(&path), size, bs) }.unwrap();
    assert!(dev.rdev().is_some());

    let opts = extract::ExtractOptions {
        scheme: Scheme::Gpt,
        cluster_size: None,
        label: Some("IRUFUS E2E".into()),
        wue: None,
        verify: true,
    };
    let s = extract::write_iso_extract(&iso, &dev, &opts, &ctx()).unwrap();
    assert!(s.verified);
    partition::validate_gpt(&dev).unwrap();
    eprintln!(
        "E2E: {} files copied to {path} ({} bytes, block {bs})",
        s.files_copied, size
    );
}
