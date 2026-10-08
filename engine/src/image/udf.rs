//! Minimal UDF (ECMA-167 / OSTA UDF 1.02–2.01) reader, sufficient for the
//! UDF bridge file systems used by Windows installation ISOs, whose ISO 9660
//! view cannot describe files larger than 4 GiB.
//!
//! Supported: one type-1 partition map, short/long/embedded allocation
//! descriptors, extended file entries. Metadata partitions (UDF 2.50+) and
//! virtual/sparable partitions are reported as unsupported.

use std::collections::HashSet;
use std::fs::File;
use std::os::unix::fs::FileExt;

use super::fstree::{Entry, FsTree, MAX_DEPTH, MAX_DIR_BYTES, MAX_ENTRIES, Timestamp, TreeSource};
use crate::error::{EngineError, IoContext, Result};

const TAG_AVDP: u16 = 2;
const TAG_PD: u16 = 5;
const TAG_LVD: u16 = 6;
const TAG_TD: u16 = 8;
const TAG_FSD: u16 = 256;
const TAG_FID: u16 = 257;
const TAG_AED: u16 = 258;
const TAG_FE: u16 = 261;
const TAG_EFE: u16 = 266;

fn le16(b: &[u8], o: usize) -> u16 {
    u16::from_le_bytes(b[o..o + 2].try_into().unwrap())
}
fn le32(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes(b[o..o + 4].try_into().unwrap())
}
fn le64(b: &[u8], o: usize) -> u64 {
    u64::from_le_bytes(b[o..o + 8].try_into().unwrap())
}

pub struct UdfVolume {
    block: u64,
    partition_start: u64,
    partition_len: u64,
    root_icb: u32,
}

fn tag_id(b: &[u8]) -> Option<u16> {
    if b.len() < 16 {
        return None;
    }
    // Tag checksum: sum of bytes 0..16 except byte 4.
    let sum = b[..16]
        .iter()
        .enumerate()
        .filter(|(i, _)| *i != 4)
        .fold(0u8, |a, (_, &x)| a.wrapping_add(x));
    if sum != b[4] {
        return None;
    }
    Some(le16(b, 0))
}

impl UdfVolume {
    pub fn open(file: &File) -> Result<Self> {
        let block = 2048u64;
        let mut avdp = vec![0u8; block as usize];
        file.read_exact_at(&mut avdp, 256 * block)
            .ctx("reading UDF anchor")?;
        if tag_id(&avdp) != Some(TAG_AVDP) {
            return Err(EngineError::UnsupportedImage(
                "UDF anchor volume descriptor not found at sector 256".into(),
            ));
        }
        let vds_len = le32(&avdp, 16) as u64;
        let vds_loc = le32(&avdp, 20) as u64;
        let mut partition: Option<(u16, u64, u64)> = None;
        let mut fsd_lbn: Option<u32> = None;
        let mut lvd_block: u64 = block;
        for i in 0..(vds_len / block).min(64) {
            let mut d = vec![0u8; block as usize];
            file.read_exact_at(&mut d, (vds_loc + i) * block)
                .ctx("reading UDF volume descriptors")?;
            match tag_id(&d) {
                Some(TAG_PD) => {
                    partition = Some((le16(&d, 22), le32(&d, 188) as u64, le32(&d, 192) as u64))
                }
                Some(TAG_LVD) => {
                    lvd_block = le32(&d, 212) as u64;
                    let map_count = le32(&d, 268);
                    let map_type = d[440];
                    if map_count != 1 || map_type != 1 {
                        return Err(EngineError::UnsupportedImage(
                            "UDF volume uses a partition map type that is not supported".into(),
                        ));
                    }
                    fsd_lbn = Some(le32(&d, 252));
                }
                Some(TAG_TD) => break,
                _ => {}
            }
        }
        let (_, start, len) = partition
            .ok_or_else(|| EngineError::CorruptImage("UDF partition descriptor missing".into()))?;
        if lvd_block != block {
            return Err(EngineError::UnsupportedImage(format!(
                "UDF logical block size {lvd_block} not supported"
            )));
        }
        let fsd_lbn = fsd_lbn.ok_or_else(|| {
            EngineError::CorruptImage("UDF logical volume descriptor missing".into())
        })?;
        let mut fsd = vec![0u8; block as usize];
        file.read_exact_at(&mut fsd, (start + fsd_lbn as u64) * block)
            .ctx("reading UDF file set descriptor")?;
        if tag_id(&fsd) != Some(TAG_FSD) {
            return Err(EngineError::CorruptImage(
                "UDF file set descriptor not found".into(),
            ));
        }
        Ok(Self {
            block,
            partition_start: start,
            partition_len: len,
            root_icb: le32(&fsd, 404),
        })
    }

    fn read_block(&self, file: &File, lbn: u32) -> Result<Vec<u8>> {
        if lbn as u64 >= self.partition_len {
            return Err(EngineError::CorruptImage(format!(
                "UDF block {lbn} outside partition"
            )));
        }
        let mut b = vec![0u8; self.block as usize];
        file.read_exact_at(&mut b, (self.partition_start + lbn as u64) * self.block)
            .ctx("reading UDF block")?;
        Ok(b)
    }

    /// Parse a (extended) file entry: returns (is_dir, size, extents, embedded data, mtime).
    #[allow(clippy::type_complexity)]
    fn file_entry(
        &self,
        file: &File,
        lbn: u32,
    ) -> Result<(
        bool,
        u64,
        Vec<(u64, u64)>,
        Option<Vec<u8>>,
        Option<Timestamp>,
    )> {
        let b = self.read_block(file, lbn)?;
        let (info_len, l_ea, l_ad, ad_start, mtime_off) = match tag_id(&b) {
            Some(TAG_FE) => (
                le64(&b, 56),
                le32(&b, 168) as usize,
                le32(&b, 172) as usize,
                176,
                84,
            ),
            Some(TAG_EFE) => (
                le64(&b, 56),
                le32(&b, 208) as usize,
                le32(&b, 212) as usize,
                216,
                92,
            ),
            _ => {
                return Err(EngineError::CorruptImage(format!(
                    "expected UDF file entry at block {lbn}"
                )));
            }
        };
        let file_type = b[16 + 11];
        let is_dir = file_type == 4;
        let ad_type = le16(&b, 16 + 18) & 0x7;
        let start = ad_start + l_ea;
        if start + l_ad > b.len() {
            return Err(EngineError::CorruptImage(
                "UDF allocation descriptors overflow the file entry".into(),
            ));
        }
        let mtime = udf_time(&b[mtime_off..mtime_off + 12]);
        if ad_type == 3 {
            return Ok((
                is_dir,
                info_len,
                vec![],
                Some(b[start..start + l_ad].to_vec()),
                mtime,
            ));
        }
        let mut extents = Vec::new();
        let mut ads = b[start..start + l_ad].to_vec();
        let mut hops = 0;
        loop {
            let step = match ad_type {
                0 => 8,
                1 => 16,
                _ => {
                    return Err(EngineError::UnsupportedImage(
                        "UDF extended allocation descriptors".into(),
                    ));
                }
            };
            let mut next: Option<u32> = None;
            for ad in ads.chunks_exact(step) {
                let raw_len = le32(ad, 0);
                let len = (raw_len & 0x3FFF_FFFF) as u64;
                let kind = raw_len >> 30;
                let pos = le32(ad, 4);
                if len == 0 {
                    break;
                }
                match kind {
                    0 => {
                        if pos as u64 + len.div_ceil(self.block) > self.partition_len {
                            return Err(EngineError::CorruptImage(
                                "UDF extent outside partition".into(),
                            ));
                        }
                        extents.push(((self.partition_start + pos as u64) * self.block, len));
                    }
                    // Allocated-but-unrecorded / unallocated extents read as zeros:
                    // not expected on pressed media, refuse rather than produce wrong data.
                    1 | 2 => return Err(EngineError::UnsupportedImage("sparse UDF file".into())),
                    _ => next = Some(pos),
                }
            }
            let Some(next_lbn) = next else { break };
            hops += 1;
            if hops > 1024 {
                return Err(EngineError::CorruptImage(
                    "UDF allocation chain too long".into(),
                ));
            }
            let aed = self.read_block(file, next_lbn)?;
            if tag_id(&aed) != Some(TAG_AED) {
                return Err(EngineError::CorruptImage(
                    "bad UDF allocation extent descriptor".into(),
                ));
            }
            let l = le32(&aed, 20) as usize;
            ads = aed[24..(24 + l).min(aed.len())].to_vec();
        }
        Ok((is_dir, info_len, extents, None, mtime))
    }

    pub fn tree(&self, file: &File) -> Result<FsTree> {
        let mut entries = Vec::new();
        let mut visited = HashSet::new();
        self.walk(file, self.root_icb, "", 0, &mut entries, &mut visited)?;
        Ok(FsTree {
            source: TreeSource::Udf,
            entries,
        })
    }

    fn walk(
        &self,
        file: &File,
        icb: u32,
        prefix: &str,
        depth: usize,
        out: &mut Vec<Entry>,
        visited: &mut HashSet<u32>,
    ) -> Result<()> {
        if depth > MAX_DEPTH {
            return Err(EngineError::CorruptImage(
                "UDF directory nesting too deep".into(),
            ));
        }
        if !visited.insert(icb) {
            return Err(EngineError::CorruptImage("UDF directory loop".into()));
        }
        let (_, size, extents, embedded, _) = self.file_entry(file, icb)?;
        if size > MAX_DIR_BYTES {
            return Err(EngineError::CorruptImage("UDF directory too large".into()));
        }
        let data = match embedded {
            Some(d) => d,
            None => {
                let mut d = Vec::with_capacity(size as usize);
                for (off, len) in extents {
                    let mut chunk = vec![0u8; len as usize];
                    file.read_exact_at(&mut chunk, off)
                        .ctx("reading UDF directory")?;
                    d.extend_from_slice(&chunk);
                }
                d.truncate(size as usize);
                d
            }
        };
        let mut pos = 0usize;
        while pos + 38 <= data.len() {
            let fid = &data[pos..];
            if tag_id(fid) != Some(TAG_FID) {
                return Err(EngineError::CorruptImage(
                    "bad UDF file identifier descriptor".into(),
                ));
            }
            let chars = fid[18];
            let l_fi = fid[19] as usize;
            let child_lbn = le32(fid, 24);
            let l_iu = le16(fid, 36) as usize;
            let name_start = 38 + l_iu;
            let total = (38 + l_iu + l_fi + 3) & !3;
            if pos + total > data.len() || name_start + l_fi > fid.len() {
                return Err(EngineError::CorruptImage(
                    "truncated UDF file identifier".into(),
                ));
            }
            pos += total;
            let is_parent = chars & 0x08 != 0;
            let is_deleted = chars & 0x04 != 0;
            if is_parent || is_deleted || l_fi == 0 {
                continue;
            }
            let name = decode_dstring(&fid[name_start..name_start + l_fi]);
            if name.is_empty() || name.contains('/') || name == "." || name == ".." {
                return Err(EngineError::CorruptImage("invalid UDF file name".into()));
            }
            let path = format!("{prefix}/{name}");
            let (is_dir, size, extents, embedded, mtime) = self.file_entry(file, child_lbn)?;
            if out.len() >= MAX_ENTRIES {
                return Err(EngineError::CorruptImage("too many entries".into()));
            }
            if is_dir {
                out.push(Entry {
                    path: path.clone(),
                    is_dir: true,
                    size: 0,
                    extents: vec![],
                    mtime,
                    symlink: None,
                });
                self.walk(file, child_lbn, &path, depth + 1, out, visited)?;
            } else {
                if embedded.is_some() && size > 0 {
                    // Data embedded in the ICB: point at it inside the file entry block.
                    let (_, l_ea, ad_start) = {
                        let b = self.read_block(file, child_lbn)?;
                        match tag_id(&b) {
                            Some(TAG_FE) => (0, le32(&b, 168) as u64, 176u64),
                            _ => (0, le32(&b, 208) as u64, 216u64),
                        }
                    };
                    let off =
                        (self.partition_start + child_lbn as u64) * self.block + ad_start + l_ea;
                    out.push(Entry {
                        path,
                        is_dir: false,
                        size,
                        extents: vec![(off, size)],
                        mtime,
                        symlink: None,
                    });
                    continue;
                }
                let recorded: u64 = extents.iter().map(|e| e.1).sum();
                if recorded < size {
                    return Err(EngineError::CorruptImage(format!(
                        "UDF file '{path}' has fewer recorded bytes than its size"
                    )));
                }
                out.push(Entry {
                    path,
                    is_dir: false,
                    size,
                    extents,
                    mtime,
                    symlink: None,
                });
            }
        }
        Ok(())
    }
}

fn decode_dstring(b: &[u8]) -> String {
    match b.first() {
        Some(8) => b[1..].iter().map(|&c| c as char).collect(),
        Some(16) => {
            let units: Vec<u16> = b[1..]
                .as_chunks::<2>()
                .0
                .iter()
                .map(|c| u16::from_be_bytes([c[0], c[1]]))
                .collect();
            String::from_utf16_lossy(&units)
        }
        _ => String::new(),
    }
}

fn udf_time(b: &[u8]) -> Option<Timestamp> {
    let year = le16(b, 2);
    let (month, day) = (b[4], b[5]);
    if year == 0 || month == 0 || month > 12 || day == 0 || day > 31 {
        return None;
    }
    Some(Timestamp {
        year,
        month,
        day,
        hour: b[6],
        minute: b[7],
        second: b[8],
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dstring_decoding() {
        assert_eq!(decode_dstring(&[8, b'a', b'b']), "ab");
        let mut v = vec![16u8];
        v.extend("ñ€".encode_utf16().flat_map(|u| u.to_be_bytes()));
        assert_eq!(decode_dstring(&v), "ñ€");
        assert_eq!(decode_dstring(&[]), "");
    }

    #[test]
    fn tag_checksum_is_enforced() {
        let mut t = [0u8; 16];
        t[0] = 2;
        t[4] = 2;
        assert_eq!(tag_id(&t), Some(2));
        t[4] = 3;
        assert_eq!(tag_id(&t), None);
    }
}
