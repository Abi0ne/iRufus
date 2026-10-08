//! ISO 9660 (ECMA-119) reader with Joliet, Rock Ridge (SUSP/RRIP) and
//! multi-extent support, plus El Torito boot catalog parsing.

use std::collections::HashSet;
use std::fs::File;
use std::os::unix::fs::FileExt;

use super::fstree::{Entry, FsTree, MAX_DEPTH, MAX_DIR_BYTES, MAX_ENTRIES, Timestamp, TreeSource};
use crate::error::{EngineError, IoContext, Result};

pub const SECTOR: u64 = 2048;

#[derive(Debug, Clone, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ElTorito {
    pub bios_bootable: bool,
    pub efi_bootable: bool,
    /// (LBA, sector count in 512-byte units as recorded) of EFI boot images.
    pub efi_images: Vec<(u32, u16)>,
}

#[derive(Debug, Clone)]
pub struct IsoVolume {
    pub label: String,
    pub volume_blocks: u32,
    pub root: DirRecord,
    pub joliet_root: Option<DirRecord>,
    pub boot_catalog: Option<u32>,
    pub has_udf: bool,
    pub has_rock_ridge: bool,
    rr_skip: usize,
}

#[derive(Debug, Clone)]
pub struct DirRecord {
    pub lba: u32,
    pub size: u32,
    pub flags: u8,
    pub name: Vec<u8>,
    pub date: [u8; 7],
    pub system_use: Vec<u8>,
}

fn read_sectors(file: &File, lba: u64, count: u64) -> Result<Vec<u8>> {
    let mut buf = vec![0u8; (count * SECTOR) as usize];
    file.read_exact_at(&mut buf, lba * SECTOR)
        .ctx("reading ISO sectors")?;
    Ok(buf)
}

fn le32(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes(b[o..o + 4].try_into().unwrap())
}
fn le16(b: &[u8], o: usize) -> u16 {
    u16::from_le_bytes(b[o..o + 2].try_into().unwrap())
}

fn parse_record(b: &[u8]) -> Option<DirRecord> {
    let len = *b.first()? as usize;
    if len < 34 || len > b.len() {
        return None;
    }
    let name_len = b[32] as usize;
    if 33 + name_len > len {
        return None;
    }
    let su_start = 33 + name_len + if name_len.is_multiple_of(2) { 1 } else { 0 };
    Some(DirRecord {
        lba: le32(b, 2),
        size: le32(b, 10),
        flags: b[25],
        name: b[33..33 + name_len].to_vec(),
        date: b[18..25].try_into().unwrap(),
        system_use: if su_start < len {
            b[su_start..len].to_vec()
        } else {
            Vec::new()
        },
    })
}

/// Returns true if the file looks like an ISO 9660 image.
pub fn probe(file: &File) -> bool {
    let mut b = [0u8; 6];
    file.read_exact_at(&mut b, 16 * SECTOR).is_ok() && &b[1..6] == b"CD001"
}

impl IsoVolume {
    pub fn open(file: &File) -> Result<Self> {
        let mut pvd: Option<Vec<u8>> = None;
        let mut joliet: Option<DirRecord> = None;
        let mut boot_catalog = None;
        let mut lba = 16u64;
        let mut terminated = false;
        while lba < 16 + 64 {
            let s = read_sectors(file, lba, 1)?;
            if &s[1..6] != b"CD001" {
                break;
            }
            match s[0] {
                0 if s[7..30].starts_with(b"EL TORITO SPECIFICATION") => {
                    boot_catalog = Some(le32(&s, 71))
                }
                1 if pvd.is_none() => pvd = Some(s),
                2 => {
                    let esc = &s[88..120];
                    let is_joliet = esc
                        .windows(3)
                        .any(|w| w == b"%/@" || w == b"%/C" || w == b"%/E");
                    if is_joliet {
                        joliet = parse_record(&s[156..190]);
                    }
                }
                255 => {
                    terminated = true;
                    lba += 1;
                    break;
                }
                _ => {}
            }
            lba += 1;
        }
        let pvd = pvd.ok_or_else(|| {
            EngineError::UnsupportedImage("no ISO 9660 primary volume descriptor".into())
        })?;
        if !terminated {
            return Err(EngineError::CorruptImage(
                "ISO volume descriptor set is not terminated".into(),
            ));
        }
        let block_size = le16(&pvd, 128);
        if block_size as u64 != SECTOR {
            return Err(EngineError::UnsupportedImage(format!(
                "ISO logical block size {block_size} is not supported"
            )));
        }
        // UDF volume recognition sequence follows the ISO descriptors.
        let mut has_udf = false;
        for l in lba..lba + 16 {
            let Ok(s) = read_sectors(file, l, 1) else {
                break;
            };
            let id = &s[1..6];
            if id == b"NSR02" || id == b"NSR03" {
                has_udf = true;
                break;
            }
            if id != b"BEA01"
                && id != b"TEA01"
                && id != b"CD001"
                && id != b"BOOT2"
                && id != b"CDW02"
            {
                break;
            }
        }
        let root = parse_record(&pvd[156..190])
            .ok_or_else(|| EngineError::CorruptImage("bad root directory record".into()))?;
        let label = String::from_utf8_lossy(&pvd[40..72])
            .trim_end_matches([' ', '\0'])
            .to_string();
        let mut vol = IsoVolume {
            label,
            volume_blocks: le32(&pvd, 80),
            root,
            joliet_root: joliet,
            boot_catalog,
            has_udf,
            has_rock_ridge: false,
            rr_skip: 0,
        };
        // Rock Ridge is announced by an SUSP "SP" entry in the root's "." record.
        let root_dir = read_sectors(file, vol.root.lba as u64, 1)?;
        if let Some(dot) = parse_record(&root_dir) {
            let su = &dot.system_use;
            if su.len() >= 7 && &su[0..2] == b"SP" && su[4] == 0xBE && su[5] == 0xEF {
                vol.rr_skip = su[6] as usize;
                let mut found = false;
                // Only an RRIP extension reference or actual RRIP entries count:
                // other SUSP users (e.g. Apple's "AA"/"BA" extensions) also emit "SP".
                walk_susp(file, su, &mut |sig, d| match sig {
                    b"ER" if d.len() >= 4 => {
                        let id_len = d[0] as usize;
                        let id = &d[4..(4 + id_len).min(d.len())];
                        if id.starts_with(b"RRIP")
                            || id.starts_with(b"IEEE_P1282")
                            || id.starts_with(b"IEEE_1282")
                        {
                            found = true;
                        }
                    }
                    b"RR" | b"PX" | b"NM" => found = true,
                    _ => {}
                });
                vol.has_rock_ridge = found && vol.root_uses_rr_names(file)?;
            }
        }
        Ok(vol)
    }

    /// Some authoring tools declare RRIP but never emit "NM" names; in that case
    /// Joliet carries the real names and must be preferred.
    fn root_uses_rr_names(&self, file: &File) -> Result<bool> {
        let size = (self.root.size as u64).min(MAX_DIR_BYTES);
        let data = read_sectors(file, self.root.lba as u64, size.div_ceil(SECTOR))?;
        let mut pos = 0usize;
        let mut children = 0;
        while pos < size as usize {
            let len = data[pos] as usize;
            if len == 0 {
                pos = (pos / SECTOR as usize + 1) * SECTOR as usize;
                continue;
            }
            let Some(rec) = parse_record(&data[pos..]) else {
                break;
            };
            pos += len;
            if rec.name == [0] || rec.name == [1] {
                continue;
            }
            children += 1;
            if rec.system_use.len() > self.rr_skip {
                let mut nm = false;
                walk_susp(file, &rec.system_use[self.rr_skip..], &mut |sig, _| {
                    nm |= sig == b"NM"
                });
                if nm {
                    return Ok(true);
                }
            }
        }
        Ok(children == 0)
    }

    pub fn el_torito(&self, file: &File) -> Result<ElTorito> {
        let mut et = ElTorito::default();
        let Some(lba) = self.boot_catalog else {
            return Ok(et);
        };
        let cat = read_sectors(file, lba as u64, 1)?;
        if cat[0] != 1 || cat[30] != 0x55 || cat[31] != 0xAA {
            return Ok(et);
        }
        let mut platform = cat[1];
        let mut add = |platform: u8, e: &[u8]| {
            if e[0] != 0x88 {
                return;
            }
            if platform == 0xEF {
                et.efi_bootable = true;
                et.efi_images.push((le32(e, 8), le16(e, 6)));
            } else if platform == 0 {
                et.bios_bootable = true;
            }
        };
        add(platform, &cat[32..64]);
        let mut off = 64;
        while off + 32 <= cat.len() {
            let hdr = cat[off];
            if hdr != 0x90 && hdr != 0x91 {
                break;
            }
            platform = cat[off + 1];
            let count = le16(&cat, off + 2) as usize;
            off += 32;
            for _ in 0..count {
                if off + 32 > cat.len() {
                    break;
                }
                // Skip section entry extensions (0x44).
                while off + 32 <= cat.len() && cat[off] == 0x44 {
                    off += 32;
                }
                if off + 32 > cat.len() {
                    break;
                }
                add(platform, &cat[off..off + 32]);
                off += 32;
            }
            if hdr == 0x91 {
                break;
            }
        }
        Ok(et)
    }

    /// Build the file tree, preferring Rock Ridge, then Joliet, then plain ISO 9660.
    pub fn tree(&self, file: &File) -> Result<FsTree> {
        let (source, root) = if self.has_rock_ridge {
            (TreeSource::RockRidge, &self.root)
        } else if let Some(j) = &self.joliet_root {
            (TreeSource::Joliet, j)
        } else {
            (TreeSource::Iso9660, &self.root)
        };
        let mut entries = Vec::new();
        let mut visited = HashSet::new();
        self.walk(
            file,
            source,
            root.lba,
            root.size,
            "",
            0,
            &mut entries,
            &mut visited,
        )?;
        Ok(FsTree { source, entries })
    }

    #[allow(clippy::too_many_arguments)]
    fn walk(
        &self,
        file: &File,
        source: TreeSource,
        lba: u32,
        size: u32,
        prefix: &str,
        depth: usize,
        out: &mut Vec<Entry>,
        visited: &mut HashSet<u32>,
    ) -> Result<()> {
        if depth > MAX_DEPTH {
            return Err(EngineError::CorruptImage(
                "directory nesting too deep".into(),
            ));
        }
        if !visited.insert(lba) {
            return Err(EngineError::CorruptImage("directory loop detected".into()));
        }
        if size as u64 > MAX_DIR_BYTES {
            return Err(EngineError::CorruptImage("directory too large".into()));
        }
        let data = read_sectors(file, lba as u64, (size as u64).div_ceil(SECTOR))?;
        let mut pos = 0usize;
        let mut pending: Option<Entry> = None;
        while pos < size as usize {
            let len = data[pos] as usize;
            if len == 0 {
                pos = (pos / SECTOR as usize + 1) * SECTOR as usize;
                continue;
            }
            let rec = parse_record(&data[pos..])
                .ok_or_else(|| EngineError::CorruptImage("bad directory record".into()))?;
            pos += len;
            if rec.name == [0] || rec.name == [1] {
                continue;
            }
            let mut name = match source {
                TreeSource::Joliet => decode_ucs2(&rec.name),
                _ => iso_name(&rec.name),
            };
            let mut is_dir = rec.flags & 0x02 != 0;
            let mut dir_lba = rec.lba;
            let mut symlink = None;
            let mut relocated = false;
            if source == TreeSource::RockRidge && rec.system_use.len() > self.rr_skip {
                let mut nm = String::new();
                let mut have_nm = false;
                let mut sl = Vec::<String>::new();
                let mut have_sl = false;
                let mut sl_continue = false;
                walk_susp(
                    file,
                    &rec.system_use[self.rr_skip..],
                    &mut |sig, d| match sig {
                        b"NM" if !d.is_empty() => {
                            if d[0] & 0x06 == 0 {
                                nm.push_str(&String::from_utf8_lossy(&d[1..]));
                                have_nm = true;
                            }
                        }
                        b"SL" if !d.is_empty() => {
                            have_sl = true;
                            let mut i = 1;
                            while i + 2 <= d.len() {
                                let (cf, cl) = (d[i], d[i + 1] as usize);
                                let comp = &d[(i + 2).min(d.len())..(i + 2 + cl).min(d.len())];
                                let text = if cf & 0x02 != 0 {
                                    ".".to_string()
                                } else if cf & 0x04 != 0 {
                                    "..".to_string()
                                } else if cf & 0x08 != 0 {
                                    String::new()
                                } else {
                                    String::from_utf8_lossy(comp).to_string()
                                };
                                if sl_continue {
                                    if let Some(last) = sl.last_mut() {
                                        last.push_str(&text);
                                    }
                                } else {
                                    sl.push(text);
                                }
                                sl_continue = cf & 0x01 != 0;
                                i += 2 + cl;
                            }
                        }
                        b"CL" if d.len() >= 4 => {
                            is_dir = true;
                            dir_lba = u32::from_le_bytes(d[0..4].try_into().unwrap());
                        }
                        b"RE" => relocated = true,
                        _ => {}
                    },
                );
                if have_nm && !nm.is_empty() {
                    name = nm;
                }
                if have_sl {
                    let joined = sl.join("/");
                    symlink = Some(if joined.is_empty() {
                        "/".into()
                    } else {
                        joined
                    });
                }
            }
            if relocated {
                continue;
            }
            if name.is_empty() || name.contains('/') || name == "." || name == ".." {
                return Err(EngineError::CorruptImage(format!(
                    "invalid file name in directory at LBA {lba}"
                )));
            }
            let path = format!("{prefix}/{name}");
            if is_dir && symlink.is_none() {
                if out.len() >= MAX_ENTRIES {
                    return Err(EngineError::CorruptImage("too many entries".into()));
                }
                out.push(Entry {
                    path: path.clone(),
                    is_dir: true,
                    size: 0,
                    extents: vec![],
                    mtime: iso_date(&rec.date),
                    symlink: None,
                });
                let dir_size = if dir_lba != rec.lba {
                    // Child link: size comes from the relocated directory's "." record.
                    let s = read_sectors(file, dir_lba as u64, 1)?;
                    parse_record(&s).map(|r| r.size).unwrap_or(SECTOR as u32)
                } else {
                    rec.size
                };
                self.walk(
                    file,
                    source,
                    dir_lba,
                    dir_size,
                    &path,
                    depth + 1,
                    out,
                    visited,
                )?;
                continue;
            }
            let extent = (rec.lba as u64 * SECTOR, rec.size as u64);
            match pending.as_mut() {
                Some(p) if p.path == path => {
                    p.extents.push(extent);
                    p.size += rec.size as u64;
                }
                _ => {
                    if let Some(p) = pending.take() {
                        out.push(p);
                    }
                    pending = Some(Entry {
                        path,
                        is_dir: false,
                        size: if symlink.is_some() {
                            0
                        } else {
                            rec.size as u64
                        },
                        extents: if symlink.is_some() || rec.size == 0 {
                            vec![]
                        } else {
                            vec![extent]
                        },
                        mtime: iso_date(&rec.date),
                        symlink,
                    });
                }
            }
            // Flag 0x80: the file continues in the next record (multi-extent).
            if rec.flags & 0x80 == 0
                && let Some(p) = pending.take()
            {
                out.push(p);
            }
            if out.len() >= MAX_ENTRIES {
                return Err(EngineError::CorruptImage("too many entries".into()));
            }
        }
        if let Some(p) = pending.take() {
            out.push(p);
        }
        Ok(())
    }
}

/// Iterate SUSP entries, following "CE" continuation areas (bounded).
fn walk_susp(file: &File, area: &[u8], f: &mut dyn FnMut(&[u8], &[u8])) {
    let mut current = area.to_vec();
    for _ in 0..16 {
        let mut next: Option<(u32, u32, u32)> = None;
        let mut i = 0;
        while i + 4 <= current.len() {
            let sig = &current[i..i + 2];
            let len = current[i + 2] as usize;
            if len < 4 || i + len > current.len() {
                break;
            }
            let data = &current[i + 4..i + len];
            if sig == b"ST" {
                break;
            }
            if sig == b"CE" && data.len() >= 24 {
                next = Some((le32(data, 0), le32(data, 8), le32(data, 16)));
            } else {
                f(sig, data);
            }
            i += len;
        }
        let Some((block, offset, length)) = next else {
            return;
        };
        if length == 0 || length > 64 * 1024 {
            return;
        }
        let mut buf = vec![0u8; length as usize];
        if file
            .read_exact_at(&mut buf, block as u64 * SECTOR + offset as u64)
            .is_err()
        {
            return;
        }
        current = buf;
    }
}

fn iso_name(raw: &[u8]) -> String {
    let s = String::from_utf8_lossy(raw);
    let s = s.split(';').next().unwrap_or("");
    s.strip_suffix('.').unwrap_or(s).to_string()
}

fn decode_ucs2(raw: &[u8]) -> String {
    let units: Vec<u16> = raw
        .as_chunks::<2>()
        .0
        .iter()
        .map(|c| u16::from_be_bytes([c[0], c[1]]))
        .collect();
    let s = String::from_utf16_lossy(&units);
    let s = s.split(';').next().unwrap_or("").to_string();
    s.strip_suffix('.').map(str::to_string).unwrap_or(s)
}

fn iso_date(d: &[u8; 7]) -> Option<Timestamp> {
    if d[1] == 0 || d[1] > 12 || d[2] == 0 || d[2] > 31 {
        return None;
    }
    Some(Timestamp {
        year: 1900 + d[0] as u16,
        month: d[1],
        day: d[2],
        hour: d[3],
        minute: d[4],
        second: d[5],
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn name_decoding() {
        assert_eq!(iso_name(b"README.TXT;1"), "README.TXT");
        assert_eq!(iso_name(b"BOOT."), "BOOT");
        let j: Vec<u8> = "Fichier très long.txt;1"
            .encode_utf16()
            .flat_map(|u| u.to_be_bytes())
            .collect();
        assert_eq!(decode_ucs2(&j), "Fichier très long.txt");
    }

    #[test]
    fn record_parsing_rejects_truncation() {
        let mut r = vec![0u8; 40];
        r[0] = 40;
        r[32] = 3;
        r[33..36].copy_from_slice(b"ABC");
        assert!(parse_record(&r).is_some());
        r[32] = 30;
        assert!(parse_record(&r).is_none());
        r[0] = 200;
        assert!(parse_record(&r).is_none());
    }
}
