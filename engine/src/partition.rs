//! MBR and GPT: parsing existing layouts and writing new ones.

use serde::{Deserialize, Serialize};

use crate::device::{AlignedBuf, BlockDevice, align_down, align_up};
use crate::error::{EngineError, IoContext, Result};

pub const MIB: u64 = 1 << 20;
const GPT_ENTRIES: usize = 128;
const GPT_ENTRY_SIZE: usize = 128;

/// Microsoft Basic Data, used by Rufus for FAT32 data partitions on GPT.
pub const GUID_BASIC_DATA: &str = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7";
pub const GUID_ESP: &str = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Scheme {
    Mbr,
    Gpt,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PartitionInfo {
    pub index: u32,
    pub start: u64,
    pub size: u64,
    /// MBR type byte as "0x0C" or GPT type GUID.
    pub type_id: String,
    pub name: Option<String>,
    pub bootable: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Layout {
    pub scheme: Option<Scheme>,
    pub partitions: Vec<PartitionInfo>,
    pub has_boot_signature: bool,
    /// True if an MBR contains non-zero boot code (BIOS bootable image).
    pub has_mbr_boot_code: bool,
}

pub fn guid_to_bytes(s: &str) -> Result<[u8; 16]> {
    let hex: String = s.chars().filter(|c| *c != '-').collect();
    if hex.len() != 32 {
        return Err(EngineError::InvalidArgument(format!("bad GUID {s}")));
    }
    let mut raw = [0u8; 16];
    for i in 0..16 {
        raw[i] = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16)
            .map_err(|_| EngineError::InvalidArgument(format!("bad GUID {s}")))?;
    }
    let mut out = raw;
    out[0..4].reverse();
    out[4..6].reverse();
    out[6..8].reverse();
    Ok(out)
}

pub fn guid_to_string(b: &[u8]) -> String {
    format!(
        "{:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
        b[3],
        b[2],
        b[1],
        b[0],
        b[5],
        b[4],
        b[7],
        b[6],
        b[8],
        b[9],
        b[10],
        b[11],
        b[12],
        b[13],
        b[14],
        b[15]
    )
}

pub fn random_bytes<const N: usize>() -> [u8; N] {
    let mut b = [0u8; N];
    unsafe { libc::arc4random_buf(b.as_mut_ptr().cast(), N) };
    b
}

fn random_guid() -> [u8; 16] {
    let mut g = random_bytes::<16>();
    g[7] = (g[7] & 0x0F) | 0x40; // version 4 (stored little-endian in field 3)
    g[8] = (g[8] & 0x3F) | 0x80;
    g
}

/// Parse the partition layout from the first sectors of a disk/image.
/// `head` must contain at least LBA 0..=33 (for 512-byte sectors) or LBA 0..=5 (4K).
pub fn parse_layout(head: &[u8], block_size: usize) -> Layout {
    let mut layout = Layout {
        scheme: None,
        partitions: vec![],
        has_boot_signature: false,
        has_mbr_boot_code: false,
    };
    if head.len() < 512 {
        return layout;
    }
    layout.has_boot_signature = head[510] == 0x55 && head[511] == 0xAA;
    if !layout.has_boot_signature {
        return layout;
    }
    layout.has_mbr_boot_code = head[..440].iter().any(|&b| b != 0);
    let entry = |i: usize| &head[446 + i * 16..446 + (i + 1) * 16];
    let protective = (0..4).any(|i| entry(i)[4] == 0xEE);
    if protective
        && head.len() >= block_size * 2
        && &head[block_size..block_size + 8] == b"EFI PART"
    {
        let h = &head[block_size..block_size + 92];
        let entries_lba = u64::from_le_bytes(h[72..80].try_into().unwrap());
        let count = u32::from_le_bytes(h[80..84].try_into().unwrap()) as usize;
        let esize = u32::from_le_bytes(h[84..88].try_into().unwrap()) as usize;
        let start = entries_lba as usize * block_size;
        layout.scheme = Some(Scheme::Gpt);
        if esize >= 128 && count <= 1024 {
            for i in 0..count {
                let o = start + i * esize;
                if o + 128 > head.len() {
                    break;
                }
                let e = &head[o..o + 128];
                if e[..16].iter().all(|&b| b == 0) {
                    continue;
                }
                let first = u64::from_le_bytes(e[32..40].try_into().unwrap());
                let last = u64::from_le_bytes(e[40..48].try_into().unwrap());
                let units: Vec<u16> = e[56..128]
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .map(|c| u16::from_le_bytes([c[0], c[1]]))
                    .take_while(|&u| u != 0)
                    .collect();
                layout.partitions.push(PartitionInfo {
                    index: i as u32 + 1,
                    start: first * block_size as u64,
                    size: (last.saturating_sub(first) + 1) * block_size as u64,
                    type_id: guid_to_string(&e[0..16]),
                    name: Some(String::from_utf16_lossy(&units)).filter(|s| !s.is_empty()),
                    bootable: u64::from_le_bytes(e[48..56].try_into().unwrap()) & 0x4 != 0,
                });
            }
        }
        return layout;
    }
    let mut any = false;
    for i in 0..4 {
        let e = entry(i);
        let ptype = e[4];
        let lba = u32::from_le_bytes(e[8..12].try_into().unwrap()) as u64;
        let count = u32::from_le_bytes(e[12..16].try_into().unwrap()) as u64;
        if ptype == 0 || count == 0 || (e[0] != 0 && e[0] != 0x80) {
            continue;
        }
        any = true;
        layout.partitions.push(PartitionInfo {
            index: i as u32 + 1,
            start: lba * block_size as u64,
            size: count * block_size as u64,
            type_id: format!("0x{ptype:02X}"),
            name: None,
            bootable: e[0] == 0x80,
        });
    }
    if any {
        layout.scheme = Some(Scheme::Mbr);
    }
    layout
}

/// Bytes for the start of the disk and, for GPT, (offset, bytes) of the backup structures.
pub type TableBytes = (Vec<u8>, Option<(u64, Vec<u8>)>);

/// A single-partition layout as used for "ISO mode" media.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SinglePartitionPlan {
    pub scheme: Scheme,
    pub block_size: u32,
    pub disk_size: u64,
    pub start: u64,
    pub len: u64,
}

impl SinglePartitionPlan {
    /// Partition starting at 1 MiB, ending on a 1 MiB boundary before the GPT
    /// backup structures (GPT) or the end of the disk (MBR, capped at 2 TiB).
    pub fn new(scheme: Scheme, disk_size: u64, block_size: u32) -> Result<Self> {
        let bs = block_size as u64;
        if !block_size.is_power_of_two() || !(512..=4096).contains(&block_size) {
            return Err(EngineError::InvalidArgument(format!(
                "unsupported block size {block_size}"
            )));
        }
        let start = MIB;
        let gpt_tail = bs + align_up((GPT_ENTRIES * GPT_ENTRY_SIZE) as u64, bs);
        let end_limit = match scheme {
            Scheme::Gpt => disk_size.saturating_sub(gpt_tail),
            Scheme::Mbr => disk_size.min(start + u32::MAX as u64 * bs),
        };
        let end = align_down(end_limit, MIB);
        if end <= start + 32 * MIB {
            return Err(EngineError::InsufficientSpace {
                needed: start + 33 * MIB + gpt_tail,
                available: disk_size,
            });
        }
        Ok(Self {
            scheme,
            block_size,
            disk_size,
            start,
            len: end - start,
        })
    }

    /// Build the sectors to write at the start of the disk and (GPT) at the end.
    /// Returns (head bytes written at offset 0, optional (offset, tail bytes)).
    pub fn build(&self, mbr_type: u8, gpt_name: &str) -> Result<TableBytes> {
        let bs = self.block_size as usize;
        let total_lbas = self.disk_size / bs as u64;
        let first_lba = self.start / bs as u64;
        let count_lbas = self.len / bs as u64;
        let mut mbr = vec![0u8; 512];
        mbr[440..444].copy_from_slice(&random_bytes::<4>());
        mbr[510] = 0x55;
        mbr[511] = 0xAA;
        match self.scheme {
            Scheme::Mbr => {
                // MBR LBAs are in units of the logical block size.
                let e = &mut mbr[446..462];
                e[0] = 0x80;
                e[1..4].copy_from_slice(&chs(first_lba));
                e[4] = mbr_type;
                e[5..8].copy_from_slice(&chs(first_lba + count_lbas - 1));
                e[8..12].copy_from_slice(&(first_lba as u32).to_le_bytes());
                e[12..16].copy_from_slice(
                    &u32::try_from(count_lbas)
                        .map_err(|_| EngineError::Internal("MBR overflow".into()))?
                        .to_le_bytes(),
                );
                let mut head = vec![0u8; bs];
                head[..512].copy_from_slice(&mbr);
                if bs > 512 {
                    head[bs - 2] = 0x55;
                    head[bs - 1] = 0xAA;
                }
                Ok((head, None))
            }
            Scheme::Gpt => {
                let e = &mut mbr[446..462];
                e[1..4].copy_from_slice(&[0x00, 0x02, 0x00]);
                e[4] = 0xEE;
                e[5..8].copy_from_slice(&[0xFF, 0xFF, 0xFF]);
                e[8..12].copy_from_slice(&1u32.to_le_bytes());
                e[12..16]
                    .copy_from_slice(&((total_lbas - 1).min(u32::MAX as u64) as u32).to_le_bytes());

                let entries_bytes = GPT_ENTRIES * GPT_ENTRY_SIZE;
                let entries_lbas = entries_bytes.div_ceil(bs) as u64;
                let last_lba = total_lbas - 1;
                let first_usable = 2 + entries_lbas;
                let last_usable = last_lba - 1 - entries_lbas;
                if first_lba < first_usable || first_lba + count_lbas - 1 > last_usable {
                    return Err(EngineError::Internal(
                        "partition outside GPT usable area".into(),
                    ));
                }
                let mut entries = vec![0u8; entries_lbas as usize * bs];
                {
                    let p = &mut entries[0..GPT_ENTRY_SIZE];
                    p[0..16].copy_from_slice(&guid_to_bytes(GUID_BASIC_DATA)?);
                    p[16..32].copy_from_slice(&random_guid());
                    p[32..40].copy_from_slice(&first_lba.to_le_bytes());
                    p[40..48].copy_from_slice(&(first_lba + count_lbas - 1).to_le_bytes());
                    for (i, u) in gpt_name.encode_utf16().take(36).enumerate() {
                        p[56 + i * 2..58 + i * 2].copy_from_slice(&u.to_le_bytes());
                    }
                }
                let entries_crc = crc32fast::hash(&entries[..entries_bytes]);
                let disk_guid = random_guid();
                let header = |my: u64, alt: u64, entries_lba: u64| {
                    let mut h = vec![0u8; bs];
                    h[0..8].copy_from_slice(b"EFI PART");
                    h[8..12].copy_from_slice(&0x0001_0000u32.to_le_bytes());
                    h[12..16].copy_from_slice(&92u32.to_le_bytes());
                    h[24..32].copy_from_slice(&my.to_le_bytes());
                    h[32..40].copy_from_slice(&alt.to_le_bytes());
                    h[40..48].copy_from_slice(&first_usable.to_le_bytes());
                    h[48..56].copy_from_slice(&last_usable.to_le_bytes());
                    h[56..72].copy_from_slice(&disk_guid);
                    h[72..80].copy_from_slice(&entries_lba.to_le_bytes());
                    h[80..84].copy_from_slice(&(GPT_ENTRIES as u32).to_le_bytes());
                    h[84..88].copy_from_slice(&(GPT_ENTRY_SIZE as u32).to_le_bytes());
                    h[88..92].copy_from_slice(&entries_crc.to_le_bytes());
                    let crc = crc32fast::hash(&h[..92]);
                    h[16..20].copy_from_slice(&crc.to_le_bytes());
                    h
                };
                let mut head = vec![0u8; bs];
                head[..512].copy_from_slice(&mbr);
                head.extend_from_slice(&header(1, last_lba, 2));
                head.extend_from_slice(&entries);
                let backup_entries_lba = last_lba - entries_lbas;
                let mut tail = entries.clone();
                tail.extend_from_slice(&header(last_lba, 1, backup_entries_lba));
                Ok((head, Some((backup_entries_lba * bs as u64, tail))))
            }
        }
    }
}

fn chs(lba: u64) -> [u8; 3] {
    const HEADS: u64 = 255;
    const SPT: u64 = 63;
    let c = lba / (HEADS * SPT);
    if c > 1023 {
        return [0xFE, 0xFF, 0xFF];
    }
    let h = (lba / SPT) % HEADS;
    let s = lba % SPT + 1;
    [h as u8, (s as u8) | (((c >> 8) as u8) << 6), c as u8]
}

/// Zero `len` bytes at `offset` (block-aligned), in large aligned writes.
pub fn zero_range(dev: &dyn BlockDevice, offset: u64, len: u64) -> Result<()> {
    let chunk = 4 * MIB;
    let buf = AlignedBuf::new(chunk as usize);
    let mut pos = offset;
    while pos < offset + len {
        let n = (offset + len - pos).min(chunk);
        dev.write_at(pos, &buf[..n as usize])
            .ctx("device zeroing")?;
        pos += n;
    }
    Ok(())
}

/// Erase existing partition tables and file-system signatures: first and last MiB.
pub fn wipe_labels(dev: &dyn BlockDevice) -> Result<()> {
    let size = dev.size();
    let head = MIB.min(size);
    zero_range(dev, 0, align_down(head, dev.block_size() as u64))?;
    if size > 2 * MIB {
        let tail_start = align_down(size - MIB, dev.block_size() as u64);
        zero_range(dev, tail_start, size - tail_start)?;
    }
    Ok(())
}

/// Write a single-partition table to the device.
pub fn write_single(
    dev: &dyn BlockDevice,
    plan: &SinglePartitionPlan,
    mbr_type: u8,
    gpt_name: &str,
) -> Result<()> {
    let (head, tail) = plan.build(mbr_type, gpt_name)?;
    let mut h = AlignedBuf::new(head.len());
    h.copy_from_slice(&head);
    dev.write_at(0, &h).ctx("device partition table write")?;
    if let Some((off, t)) = tail {
        let mut b = AlignedBuf::new(t.len());
        b.copy_from_slice(&t);
        dev.write_at(off, &b).ctx("device backup GPT write")?;
    }
    Ok(())
}

/// Verify that both GPT headers and entry arrays have valid CRCs.
pub fn validate_gpt(dev: &dyn BlockDevice) -> Result<()> {
    let bs = dev.block_size() as u64;
    let check = |lba: u64| -> Result<u64> {
        let mut h = AlignedBuf::new(bs as usize);
        dev.read_at(lba * bs, &mut h).ctx("reading GPT header")?;
        if &h[0..8] != b"EFI PART" {
            return Err(EngineError::VerifyFailed(format!(
                "missing GPT header at LBA {lba}"
            )));
        }
        let mut copy = h[..92].to_vec();
        copy[16..20].fill(0);
        let stored = u32::from_le_bytes(h[16..20].try_into().unwrap());
        if crc32fast::hash(&copy) != stored {
            return Err(EngineError::VerifyFailed(format!(
                "bad GPT header CRC at LBA {lba}"
            )));
        }
        let entries_lba = u64::from_le_bytes(h[72..80].try_into().unwrap());
        let n = u32::from_le_bytes(h[80..84].try_into().unwrap()) as u64;
        let es = u32::from_le_bytes(h[84..88].try_into().unwrap()) as u64;
        let bytes = n * es;
        let mut e = AlignedBuf::new(align_up(bytes, bs) as usize);
        dev.read_at(entries_lba * bs, &mut e)
            .ctx("reading GPT entries")?;
        if crc32fast::hash(&e[..bytes as usize])
            != u32::from_le_bytes(h[88..92].try_into().unwrap())
        {
            return Err(EngineError::VerifyFailed(format!(
                "bad GPT entries CRC (header at LBA {lba})"
            )));
        }
        Ok(u64::from_le_bytes(h[32..40].try_into().unwrap()))
    };
    let alt = check(1)?;
    if alt != dev.size() / bs - 1 {
        return Err(EngineError::VerifyFailed(
            "GPT backup header is not at the last LBA".into(),
        ));
    }
    check(alt)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device::FileDevice;

    #[test]
    fn guid_roundtrip() {
        let b = guid_to_bytes(GUID_BASIC_DATA).unwrap();
        assert_eq!(b[0], 0xA2);
        assert_eq!(b[3], 0xEB);
        assert_eq!(guid_to_string(&b), GUID_BASIC_DATA);
    }

    #[test]
    fn gpt_layout_is_valid_and_parseable() {
        for bs in [512u32, 4096] {
            let dir = tempfile::tempdir().unwrap();
            let size = 256 * MIB + 3 * bs as u64;
            let dev = FileDevice::create(&dir.path().join("g.img"), size, bs).unwrap();
            let plan = SinglePartitionPlan::new(Scheme::Gpt, size, bs).unwrap();
            assert_eq!(plan.start, MIB);
            assert_eq!(plan.len % MIB, 0);
            write_single(&dev, &plan, 0x0C, "iRufus").unwrap();
            validate_gpt(&dev).unwrap();
            let mut head = vec![0u8; 64 * 1024];
            dev.read_at(0, &mut head).unwrap();
            let l = parse_layout(&head, bs as usize);
            assert_eq!(l.scheme, Some(Scheme::Gpt));
            assert_eq!(l.partitions.len(), 1);
            assert_eq!(l.partitions[0].start, MIB);
            assert_eq!(l.partitions[0].size, plan.len);
            assert_eq!(l.partitions[0].type_id, GUID_BASIC_DATA);
            assert_eq!(l.partitions[0].name.as_deref(), Some("iRufus"));
        }
    }

    #[test]
    fn gpt_validation_detects_corruption() {
        let dir = tempfile::tempdir().unwrap();
        let size = 64 * MIB;
        let dev = FileDevice::create(&dir.path().join("c.img"), size, 512).unwrap();
        let plan = SinglePartitionPlan::new(Scheme::Gpt, size, 512).unwrap();
        write_single(&dev, &plan, 0x0C, "x").unwrap();
        let mut s = vec![0u8; 512];
        dev.read_at(size - 512, &mut s).unwrap();
        s[50] ^= 0xFF;
        dev.write_at(size - 512, &s).unwrap();
        assert!(matches!(
            validate_gpt(&dev),
            Err(EngineError::VerifyFailed(_))
        ));
    }

    #[test]
    fn mbr_layout_and_limits() {
        let size = 128 * MIB;
        let plan = SinglePartitionPlan::new(Scheme::Mbr, size, 512).unwrap();
        assert_eq!(plan.start + plan.len, size);
        let (head, tail) = plan.build(0x0C, "").unwrap();
        assert!(tail.is_none());
        let l = parse_layout(&head, 512);
        assert_eq!(l.scheme, Some(Scheme::Mbr));
        assert_eq!(l.partitions[0].type_id, "0x0C");
        assert!(l.partitions[0].bootable);
        assert_eq!(l.partitions[0].start, MIB);
        // 3 TiB disk: MBR partition is capped at 2 TiB of sectors.
        let big = SinglePartitionPlan::new(Scheme::Mbr, 3 << 40, 512).unwrap();
        assert!(big.len / 512 <= u32::MAX as u64);
        assert!(SinglePartitionPlan::new(Scheme::Gpt, 20 * MIB, 512).is_err());
    }

    #[test]
    fn chs_encoding() {
        assert_eq!(chs(0), [0, 1, 0]);
        assert_eq!(chs(2048), [32, 33, 0]);
        assert_eq!(chs(100_000_000), [0xFE, 0xFF, 0xFF]);
    }
}
