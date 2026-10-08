//! FAT32 formatter (layout follows Microsoft's FAT specification and
//! fat32format: 2 FATs, data region aligned to 1 MiB like Rufus' "Large FAT32")
//! and helpers to mount the result with the `fatfs` driver.

use serde::Serialize;

use crate::device::{AlignedBuf, BlockDevice};
use crate::error::{EngineError, IoContext, Result};
use crate::partition::{MIB, random_bytes, zero_range};
use crate::regionio::RegionIo;

pub const FAT32_MAX_FILE: u64 = 0xFFFF_FFFF;
const MIN_CLUSTERS: u64 = 65_525;
const MAX_CLUSTERS: u64 = 0x0FFF_FFF4;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Fat32Geometry {
    pub bytes_per_sector: u32,
    pub sectors_per_cluster: u32,
    pub reserved_sectors: u32,
    pub fat_sectors: u32,
    pub total_sectors: u32,
    pub clusters: u32,
    pub hidden_sectors: u32,
}

impl Fat32Geometry {
    pub fn cluster_bytes(&self) -> u32 {
        self.bytes_per_sector * self.sectors_per_cluster
    }
    pub fn data_start_bytes(&self) -> u64 {
        (self.reserved_sectors as u64 + 2 * self.fat_sectors as u64) * self.bytes_per_sector as u64
    }
}

/// Microsoft's default FAT32 cluster sizes.
pub fn default_cluster_size(volume_bytes: u64) -> u32 {
    match volume_bytes {
        b if b <= 64 * MIB => 512,
        b if b <= 128 * MIB => 1024,
        b if b <= 256 * MIB => 2048,
        b if b <= 8 << 30 => 4096,
        b if b <= 16 << 30 => 8192,
        b if b <= 32 << 30 => 16384,
        _ => 32768,
    }
}

/// Valid cluster sizes for a volume (used by the UI's cluster size menu).
pub fn valid_cluster_sizes(volume_bytes: u64, bytes_per_sector: u32) -> Vec<u32> {
    [512u32, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
        .into_iter()
        .filter(|&c| {
            c >= bytes_per_sector && compute_geometry(volume_bytes, bytes_per_sector, c, 0).is_ok()
        })
        .collect()
}

pub fn compute_geometry(
    volume_bytes: u64,
    bytes_per_sector: u32,
    cluster_bytes: u32,
    hidden_sectors: u32,
) -> Result<Fat32Geometry> {
    if !matches!(bytes_per_sector, 512 | 1024 | 2048 | 4096) {
        return Err(EngineError::InvalidArgument(format!(
            "FAT32 cannot use {bytes_per_sector}-byte sectors"
        )));
    }
    if cluster_bytes < bytes_per_sector || !cluster_bytes.is_power_of_two() || cluster_bytes > 65536
    {
        return Err(EngineError::InvalidArgument(format!(
            "invalid FAT32 cluster size {cluster_bytes}"
        )));
    }
    let bps = bytes_per_sector as u64;
    let total = volume_bytes / bps;
    if total > u32::MAX as u64 {
        return Err(EngineError::Unsupported(
            "FAT32 volume larger than 2^32 sectors".into(),
        ));
    }
    let spc = (cluster_bytes / bytes_per_sector) as u64;
    let align = MIB / bps;
    let mut reserved = 32u64;
    // fat32format: FatSz = 4 * (Total - Reserved) / (ClusterBytes + 4 * NumFATs) + 1
    let fat_sz = (4 * (total.saturating_sub(reserved))).div_ceil(spc * bps + 8) + 1;
    reserved = (reserved + 2 * fat_sz).div_ceil(align) * align - 2 * fat_sz;
    if reserved > u16::MAX as u64 {
        return Err(EngineError::Internal(
            "FAT32 reserved area too large".into(),
        ));
    }
    let data_start = reserved + 2 * fat_sz;
    if data_start >= total {
        return Err(EngineError::InsufficientSpace {
            needed: (data_start + spc * MIN_CLUSTERS) * bps,
            available: volume_bytes,
        });
    }
    let clusters = (total - data_start) / spc;
    if clusters < MIN_CLUSTERS {
        return Err(EngineError::Unsupported(format!(
            "volume too small for FAT32 with {cluster_bytes}-byte clusters ({clusters} clusters)"
        )));
    }
    if clusters > MAX_CLUSTERS {
        return Err(EngineError::Unsupported(format!(
            "too many clusters ({clusters}) for FAT32: use larger clusters"
        )));
    }
    if fat_sz * bps / 4 < clusters + 2 {
        return Err(EngineError::Internal(
            "FAT too small for cluster count".into(),
        ));
    }
    Ok(Fat32Geometry {
        bytes_per_sector,
        sectors_per_cluster: spc as u32,
        reserved_sectors: reserved as u32,
        fat_sectors: fat_sz as u32,
        total_sectors: total as u32,
        clusters: clusters as u32,
        hidden_sectors,
    })
}

/// Turn an arbitrary string into a valid FAT volume label (≤ 11 OEM bytes).
pub fn sanitize_label(input: &str) -> String {
    let mut out = String::new();
    for c in input.chars() {
        let c = c.to_ascii_uppercase();
        let mapped = if c.is_ascii_alphanumeric() || " !#$%&'()-@^_`{}~".contains(c) {
            c
        } else {
            '_'
        };
        if out.len() < 11 {
            out.push(mapped);
        }
    }
    let trimmed = out.trim_end().to_string();
    if trimmed.trim_matches('_').is_empty() {
        "IRUFUS".to_string()
    } else {
        trimmed
    }
}

fn label_bytes(label: &str) -> [u8; 11] {
    let mut b = [b' '; 11];
    for (i, c) in sanitize_label(label).bytes().take(11).enumerate() {
        b[i] = c;
    }
    b
}

/// Format the region [start, start+len) of `dev` as FAT32.
pub fn format(
    dev: &dyn BlockDevice,
    start: u64,
    len: u64,
    cluster_bytes: Option<u32>,
    label: &str,
) -> Result<Fat32Geometry> {
    let bps = dev.block_size();
    let cluster = cluster_bytes.unwrap_or_else(|| default_cluster_size(len).max(bps));
    let hidden = u32::try_from(start / bps as u64).unwrap_or(u32::MAX);
    let g = compute_geometry(len, bps, cluster, hidden)?;
    let bpsu = bps as usize;

    // Zero reserved area, both FATs and the root directory cluster.
    zero_range(dev, start, g.data_start_bytes() + g.cluster_bytes() as u64)?;

    let label = label_bytes(label);
    let mut bs = vec![0u8; bpsu];
    bs[0..3].copy_from_slice(&[0xEB, 0x58, 0x90]);
    bs[3..11].copy_from_slice(b"MSWIN4.1");
    bs[11..13].copy_from_slice(&(bps as u16).to_le_bytes());
    bs[13] = g.sectors_per_cluster as u8;
    bs[14..16].copy_from_slice(&(g.reserved_sectors as u16).to_le_bytes());
    bs[16] = 2;
    bs[21] = 0xF8;
    bs[24..26].copy_from_slice(&63u16.to_le_bytes());
    bs[26..28].copy_from_slice(&255u16.to_le_bytes());
    bs[28..32].copy_from_slice(&g.hidden_sectors.to_le_bytes());
    bs[32..36].copy_from_slice(&g.total_sectors.to_le_bytes());
    bs[36..40].copy_from_slice(&g.fat_sectors.to_le_bytes());
    bs[44..48].copy_from_slice(&2u32.to_le_bytes());
    bs[48..50].copy_from_slice(&1u16.to_le_bytes());
    bs[50..52].copy_from_slice(&6u16.to_le_bytes());
    bs[64] = 0x80;
    bs[66] = 0x29;
    bs[67..71].copy_from_slice(&random_bytes::<4>());
    bs[71..82].copy_from_slice(&label);
    bs[82..90].copy_from_slice(b"FAT32   ");
    // Boot code: INT 18h (let the BIOS try the next boot device), then hang.
    bs[90..94].copy_from_slice(&[0xCD, 0x18, 0xEB, 0xFE]);
    bs[510] = 0x55;
    bs[511] = 0xAA;

    let mut fsinfo = vec![0u8; bpsu];
    fsinfo[0..4].copy_from_slice(&0x4161_5252u32.to_le_bytes());
    fsinfo[484..488].copy_from_slice(&0x6141_7272u32.to_le_bytes());
    fsinfo[488..492].copy_from_slice(&(g.clusters - 1).to_le_bytes());
    fsinfo[492..496].copy_from_slice(&3u32.to_le_bytes());
    fsinfo[508..512].copy_from_slice(&0xAA55_0000u32.to_le_bytes());

    let mut third = vec![0u8; bpsu];
    third[510] = 0x55;
    third[511] = 0xAA;

    let mut reserved = AlignedBuf::new(8 * bpsu);
    reserved[0..bpsu].copy_from_slice(&bs);
    reserved[bpsu..2 * bpsu].copy_from_slice(&fsinfo);
    reserved[2 * bpsu..3 * bpsu].copy_from_slice(&third);
    reserved[6 * bpsu..7 * bpsu].copy_from_slice(&bs);
    reserved[7 * bpsu..8 * bpsu].copy_from_slice(&fsinfo);
    dev.write_at(start, &reserved)
        .ctx("device FAT32 boot sector write")?;

    let mut fat0 = AlignedBuf::new(bpsu);
    fat0[0..4].copy_from_slice(&0x0FFF_FFF8u32.to_le_bytes());
    fat0[4..8].copy_from_slice(&0x0FFF_FFFFu32.to_le_bytes());
    fat0[8..12].copy_from_slice(&0x0FFF_FFFFu32.to_le_bytes());
    for i in 0..2u64 {
        let off = start + (g.reserved_sectors as u64 + i * g.fat_sectors as u64) * bps as u64;
        dev.write_at(off, &fat0).ctx("device FAT write")?;
    }

    // Volume label entry in the root directory.
    let mut root = AlignedBuf::new(bpsu);
    root[0..11].copy_from_slice(&label);
    root[11] = 0x08;
    dev.write_at(start + g.data_start_bytes(), &root)
        .ctx("device root directory write")?;
    Ok(g)
}

pub type FatFs<'d> = fatfs::FileSystem<RegionIo<'d>>;

pub fn mount<'d>(io: RegionIo<'d>) -> Result<FatFs<'d>> {
    fatfs::FileSystem::new(io, fatfs::FsOptions::new().update_accessed_date(false))
        .ctx("mounting FAT32 volume")
}

/// Convert an ISO/UDF timestamp to a FAT one, clamped to FAT's 1980–2107 range.
pub fn fat_datetime(ts: crate::image::fstree::Timestamp) -> fatfs::DateTime {
    let year = ts.year.clamp(1980, 2107);
    fatfs::DateTime {
        date: fatfs::Date {
            year,
            month: ts.month.clamp(1, 12) as u16,
            day: ts.day.clamp(1, 31) as u16,
        },
        time: fatfs::Time {
            hour: ts.hour.min(23) as u16,
            min: ts.minute.min(59) as u16,
            sec: ts.second.min(59) as u16,
            millis: 0,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device::FileDevice;
    use std::io::{Read, Write};

    #[test]
    fn geometry_matches_spec_constraints() {
        for (size, bps) in [
            (64 * MIB, 512),
            (8 << 30, 512),
            (64u64 << 30, 512),
            ((2u64 << 40) - MIB, 512),
            (32u64 << 30, 4096),
        ] {
            let c = default_cluster_size(size).max(bps);
            let g = compute_geometry(size, bps, c, 2048).unwrap();
            assert_eq!(
                g.data_start_bytes() % MIB,
                0,
                "data region aligned for {size}"
            );
            assert!(g.clusters as u64 >= MIN_CLUSTERS);
            assert!(g.fat_sectors as u64 * bps as u64 / 4 >= g.clusters as u64 + 2);
        }
        assert!(compute_geometry(16 * MIB, 512, 512, 0).is_err());
        assert!(compute_geometry(1 << 30, 512, 300, 0).is_err());
        assert!(valid_cluster_sizes(4 << 30, 512).contains(&4096));
    }

    #[test]
    fn labels_are_sanitized() {
        assert_eq!(sanitize_label("Ubuntu 24.04.1 LTS amd64"), "UBUNTU 24_0");
        assert_eq!(sanitize_label("CCCOMA_X64FRE_IT-IT_DV9"), "CCCOMA_X64F");
        assert_eq!(sanitize_label("ü"), "IRUFUS");
        assert_eq!(sanitize_label(""), "IRUFUS");
    }

    #[test]
    fn formatted_volume_mounts_and_stores_files() {
        let dir = tempfile::tempdir().unwrap();
        let size = 100 * MIB;
        let dev = FileDevice::create(&dir.path().join("f.img"), size, 512).unwrap();
        let g = format(&dev, MIB, size - MIB, None, "Test Vol").unwrap();
        assert_eq!(g.hidden_sectors, 2048);
        let data: Vec<u8> = (0..3_000_000u32).map(|i| (i % 253) as u8).collect();
        {
            let fs = mount(RegionIo::new(&dev, MIB, size - MIB).unwrap()).unwrap();
            assert_eq!(fs.fat_type(), fatfs::FatType::Fat32);
            assert_eq!(fs.volume_label(), "TEST VOL");
            let root = fs.root_dir();
            root.create_dir("EFI").unwrap();
            root.create_dir("EFI/BOOT").unwrap();
            let mut f = root.create_file("EFI/BOOT/bootx64.efi").unwrap();
            f.write_all(&data).unwrap();
            drop(f);
            root.create_file("A very long file name.txt")
                .unwrap()
                .write_all(b"hi")
                .unwrap();
            drop(root);
            fs.unmount().unwrap();
        }
        let fs = mount(RegionIo::new(&dev, MIB, size - MIB).unwrap()).unwrap();
        let mut back = Vec::new();
        fs.root_dir()
            .open_file("efi/boot/BOOTX64.EFI")
            .unwrap()
            .read_to_end(&mut back)
            .unwrap();
        assert_eq!(back, data);
        assert!(fs.root_dir().open_file("A very long file name.txt").is_ok());
    }

    #[test]
    fn macos_fsck_accepts_volume() {
        if !std::path::Path::new("/sbin/fsck_msdos").exists() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v.img");
        let size = 200 * MIB;
        let dev = FileDevice::create(&path, size, 512).unwrap();
        format(&dev, 0, size, None, "FSCK").unwrap();
        {
            let fs = mount(RegionIo::new(&dev, 0, size).unwrap()).unwrap();
            for i in 0..50 {
                fs.root_dir()
                    .create_file(&format!("file number {i}.bin"))
                    .unwrap()
                    .write_all(&vec![i as u8; 70_000])
                    .unwrap();
            }
            fs.unmount().unwrap();
        }
        let out = std::process::Command::new("/sbin/fsck_msdos")
            .arg("-n")
            .arg(&path)
            .output()
            .unwrap();
        let text = String::from_utf8_lossy(&out.stdout).to_string()
            + &String::from_utf8_lossy(&out.stderr);
        assert!(out.status.success(), "fsck_msdos failed: {text}");
    }
}
