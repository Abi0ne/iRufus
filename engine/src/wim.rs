//! Windows Imaging (WIM) format: header/XML inspection and splitting into
//! `.swm` parts so that `install.wim` files larger than 4 GiB fit on FAT32.
//!
//! Splitting copies resources verbatim (no recompression), following the
//! layout produced by `wimlib-imagex split` / `DISM /Split-Image`:
//! every part carries a header (same GUID, part number, total parts, SPANNED
//! flag), its blobs, a blob table describing them, and the XML data. All
//! metadata resources go into part 1, in their original order (image N is the
//! N-th metadata entry). Solid (LZMS "ESD") resources are not split.

use std::io::{Read, Seek, SeekFrom, Write};

use serde::Serialize;

use crate::error::{EngineError, IoContext, Result};
use crate::progress::{OpContext, Phase};

pub const HEADER_SIZE: usize = 208;
const MAGIC: &[u8; 8] = b"MSWIM\0\0\0";
const BLOB_ENTRY_SIZE: usize = 50;

const HDR_FLAG_SPANNED: u32 = 0x0000_0008;
const HDR_FLAG_WRITE_IN_PROGRESS: u32 = 0x0000_0040;

const RES_FLAG_METADATA: u8 = 0x02;
const RES_FLAG_COMPRESSED: u8 = 0x04;
const RES_FLAG_SOLID: u8 = 0x10;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ResHdr {
    pub size_in_wim: u64,
    pub flags: u8,
    pub offset: u64,
    pub uncompressed_size: u64,
}

impl ResHdr {
    fn parse(b: &[u8]) -> Self {
        let mut s = [0u8; 8];
        s[..7].copy_from_slice(&b[0..7]);
        Self {
            size_in_wim: u64::from_le_bytes(s),
            flags: b[7],
            offset: u64::from_le_bytes(b[8..16].try_into().unwrap()),
            uncompressed_size: u64::from_le_bytes(b[16..24].try_into().unwrap()),
        }
    }
    fn write(&self, out: &mut [u8]) {
        out[0..7].copy_from_slice(&self.size_in_wim.to_le_bytes()[..7]);
        out[7] = self.flags;
        out[8..16].copy_from_slice(&self.offset.to_le_bytes());
        out[16..24].copy_from_slice(&self.uncompressed_size.to_le_bytes());
    }
}

#[derive(Debug, Clone)]
pub struct WimHeader {
    pub raw: [u8; HEADER_SIZE],
    pub version: u32,
    pub flags: u32,
    pub part_number: u16,
    pub total_parts: u16,
    pub image_count: u32,
    pub blob_table: ResHdr,
    pub xml: ResHdr,
    pub boot_metadata: ResHdr,
    pub boot_index: u32,
    pub integrity: ResHdr,
}

impl WimHeader {
    pub fn read(r: &mut dyn Read) -> Result<Self> {
        let mut raw = [0u8; HEADER_SIZE];
        r.read_exact(&mut raw).ctx("reading WIM header")?;
        if &raw[0..8] != MAGIC {
            return Err(EngineError::UnsupportedImage(
                "not a WIM file (bad magic)".into(),
            ));
        }
        let size = u32::from_le_bytes(raw[8..12].try_into().unwrap());
        if size as usize != HEADER_SIZE {
            return Err(EngineError::UnsupportedImage(format!(
                "unexpected WIM header size {size}"
            )));
        }
        Ok(Self {
            version: u32::from_le_bytes(raw[12..16].try_into().unwrap()),
            flags: u32::from_le_bytes(raw[16..20].try_into().unwrap()),
            part_number: u16::from_le_bytes(raw[40..42].try_into().unwrap()),
            total_parts: u16::from_le_bytes(raw[42..44].try_into().unwrap()),
            image_count: u32::from_le_bytes(raw[44..48].try_into().unwrap()),
            blob_table: ResHdr::parse(&raw[48..72]),
            xml: ResHdr::parse(&raw[72..96]),
            boot_metadata: ResHdr::parse(&raw[96..120]),
            boot_index: u32::from_le_bytes(raw[120..124].try_into().unwrap()),
            integrity: ResHdr::parse(&raw[124..148]),
            raw,
        })
    }

    pub fn is_solid_capable(&self) -> bool {
        self.version == 0xE00
    }
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct WimImageInfo {
    pub index: u32,
    pub name: String,
    pub edition: Option<String>,
    pub arch: Option<String>,
    pub build: Option<u32>,
    pub languages: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WimInfo {
    pub image_count: u32,
    pub images: Vec<WimImageInfo>,
    pub solid: bool,
    pub spanned: bool,
}

/// Read header and XML description of a WIM (or ESD).
pub fn inspect<R: Read + Seek>(r: &mut R) -> Result<WimInfo> {
    r.seek(SeekFrom::Start(0)).ctx("seeking WIM")?;
    let h = WimHeader::read(r)?;
    if h.xml.flags & RES_FLAG_COMPRESSED != 0 {
        return Err(EngineError::UnsupportedImage(
            "compressed WIM XML data".into(),
        ));
    }
    if h.xml.size_in_wim > 64 << 20 {
        return Err(EngineError::CorruptImage(
            "WIM XML data is implausibly large".into(),
        ));
    }
    r.seek(SeekFrom::Start(h.xml.offset))
        .ctx("seeking WIM XML")?;
    let mut xml = vec![0u8; h.xml.size_in_wim as usize];
    r.read_exact(&mut xml).ctx("reading WIM XML")?;
    let text = utf16le_to_string(&xml);
    let images = parse_xml_images(&text);
    let blob_flags_solid = h.is_solid_capable() || {
        // Peek at the blob table for SOLID resources.
        let mut solid = false;
        if h.blob_table.size_in_wim < 256 << 20
            && h.blob_table.flags & RES_FLAG_COMPRESSED == 0
            && r.seek(SeekFrom::Start(h.blob_table.offset)).is_ok()
        {
            let mut t = vec![0u8; h.blob_table.size_in_wim as usize];
            if r.read_exact(&mut t).is_ok() {
                solid = t
                    .as_chunks::<BLOB_ENTRY_SIZE>()
                    .0
                    .iter()
                    .any(|e| e[7] & RES_FLAG_SOLID != 0);
            }
        }
        solid
    };
    Ok(WimInfo {
        image_count: h.image_count,
        images,
        solid: blob_flags_solid,
        spanned: h.flags & HDR_FLAG_SPANNED != 0,
    })
}

fn utf16le_to_string(b: &[u8]) -> String {
    let units: Vec<u16> = b
        .as_chunks::<2>()
        .0
        .iter()
        .map(|c| u16::from_le_bytes([c[0], c[1]]))
        .collect();
    String::from_utf16_lossy(&units)
        .trim_start_matches('\u{feff}')
        .to_string()
}

fn tag_value<'a>(xml: &'a str, tag: &str) -> Option<&'a str> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let s = xml.find(&open)? + open.len();
    let e = xml[s..].find(&close)? + s;
    Some(xml[s..e].trim())
}

fn xml_unescape(s: &str) -> String {
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}

fn parse_xml_images(xml: &str) -> Vec<WimImageInfo> {
    let mut out = Vec::new();
    let mut rest = xml;
    while let Some(start) = rest.find("<IMAGE ") {
        let after = &rest[start..];
        let Some(end) = after.find("</IMAGE>") else {
            break;
        };
        let block = &after[..end];
        let index = block
            .split_once("INDEX=\"")
            .and_then(|(_, r)| r.split_once('"'))
            .and_then(|(n, _)| n.parse().ok())
            .unwrap_or(out.len() as u32 + 1);
        let arch = tag_value(block, "ARCH").map(|a| {
            match a {
                "0" => "x86",
                "5" => "arm",
                "6" => "ia64",
                "9" => "x64",
                "12" => "arm64",
                other => other,
            }
            .to_string()
        });
        let mut languages = Vec::new();
        let mut lrest = block;
        while let Some(p) = lrest.find("<LANGUAGE>") {
            let s = &lrest[p + 10..];
            if let Some(e) = s.find("</LANGUAGE>") {
                languages.push(xml_unescape(s[..e].trim()));
                lrest = &s[e..];
            } else {
                break;
            }
        }
        out.push(WimImageInfo {
            index,
            name: tag_value(block, "DISPLAYNAME")
                .or_else(|| tag_value(block, "NAME"))
                .map(xml_unescape)
                .unwrap_or_default(),
            edition: tag_value(block, "EDITIONID").map(xml_unescape),
            arch,
            build: tag_value(block, "BUILD").and_then(|b| b.parse().ok()),
            languages,
        });
        rest = &after[end..];
    }
    out
}

#[derive(Debug, Clone)]
struct BlobEntry {
    res: ResHdr,
    part: u16,
    refcnt: u32,
    hash: [u8; 20],
}

fn read_blob_table<R: Read + Seek>(r: &mut R, h: &WimHeader) -> Result<Vec<BlobEntry>> {
    if h.blob_table.flags & RES_FLAG_COMPRESSED != 0 {
        return Err(EngineError::UnsupportedImage(
            "compressed WIM blob table".into(),
        ));
    }
    if !h
        .blob_table
        .size_in_wim
        .is_multiple_of(BLOB_ENTRY_SIZE as u64)
        || h.blob_table.size_in_wim > 1 << 30
    {
        return Err(EngineError::CorruptImage(
            "invalid WIM blob table size".into(),
        ));
    }
    r.seek(SeekFrom::Start(h.blob_table.offset))
        .ctx("seeking WIM blob table")?;
    let mut t = vec![0u8; h.blob_table.size_in_wim as usize];
    r.read_exact(&mut t).ctx("reading WIM blob table")?;
    Ok(t.as_chunks::<BLOB_ENTRY_SIZE>()
        .0
        .iter()
        .map(|e| BlobEntry {
            res: ResHdr::parse(&e[0..24]),
            part: u16::from_le_bytes([e[24], e[25]]),
            refcnt: u32::from_le_bytes(e[26..30].try_into().unwrap()),
            hash: e[30..50].try_into().unwrap(),
        })
        .collect())
}

/// Plan for a split: which blobs go into which part.
#[derive(Debug)]
pub struct SplitPlan {
    parts: Vec<Vec<usize>>,
    entries: Vec<BlobEntry>,
    header: WimHeader,
    xml: Vec<u8>,
}

impl SplitPlan {
    pub fn part_count(&self) -> usize {
        self.parts.len()
    }

    /// Size in bytes of each output part.
    pub fn part_sizes(&self) -> Vec<u64> {
        self.parts
            .iter()
            .map(|p| {
                HEADER_SIZE as u64
                    + p.iter()
                        .map(|&i| self.entries[i].res.size_in_wim)
                        .sum::<u64>()
                    + (p.len() * BLOB_ENTRY_SIZE) as u64
                    + self.xml.len() as u64
            })
            .collect()
    }

    pub fn total_bytes(&self) -> u64 {
        self.part_sizes().iter().sum()
    }
}

/// Compute how to split a WIM into parts no larger than `max_part`.
pub fn plan_split<R: Read + Seek>(r: &mut R, max_part: u64) -> Result<SplitPlan> {
    r.seek(SeekFrom::Start(0)).ctx("seeking WIM")?;
    let header = WimHeader::read(r)?;
    if header.flags & HDR_FLAG_SPANNED != 0 || header.total_parts != 1 {
        return Err(EngineError::UnsupportedImage("WIM is already split".into()));
    }
    let entries = read_blob_table(r, &header)?;
    if entries.iter().any(|e| e.part != 1) {
        return Err(EngineError::CorruptImage(
            "WIM blob table references other parts".into(),
        ));
    }
    if entries.iter().any(|e| e.res.flags & RES_FLAG_SOLID != 0) {
        return Err(EngineError::Unsupported(
            "splitting solid-compressed (ESD) WIM files".into(),
        ));
    }
    r.seek(SeekFrom::Start(header.xml.offset))
        .ctx("seeking WIM XML")?;
    let mut xml = vec![0u8; header.xml.size_in_wim as usize];
    r.read_exact(&mut xml).ctx("reading WIM XML")?;

    let overhead = |n_entries: usize| {
        HEADER_SIZE as u64 + (n_entries * BLOB_ENTRY_SIZE) as u64 + xml.len() as u64
    };
    let metadata: Vec<usize> = (0..entries.len())
        .filter(|&i| entries[i].res.flags & RES_FLAG_METADATA != 0)
        .collect();
    if metadata.len() as u32 != header.image_count {
        return Err(EngineError::CorruptImage(format!(
            "WIM declares {} images but has {} metadata resources",
            header.image_count,
            metadata.len()
        )));
    }
    let mut parts: Vec<Vec<usize>> = vec![metadata.clone()];
    let mut cur_size = overhead(metadata.len())
        + metadata
            .iter()
            .map(|&i| entries[i].res.size_in_wim)
            .sum::<u64>();
    if cur_size > max_part {
        return Err(EngineError::Unsupported(
            "WIM metadata alone exceeds the part size".into(),
        ));
    }
    // Blobs in on-disk order, so that each part is read sequentially.
    let mut blobs: Vec<usize> = (0..entries.len())
        .filter(|&i| entries[i].res.flags & RES_FLAG_METADATA == 0)
        .collect();
    blobs.sort_by_key(|&i| entries[i].res.offset);
    for i in blobs {
        let sz = entries[i].res.size_in_wim;
        if overhead(1) + sz > max_part {
            return Err(EngineError::Unsupported(format!(
                "a single WIM resource of {sz} bytes exceeds the part size"
            )));
        }
        if cur_size + sz + BLOB_ENTRY_SIZE as u64 > max_part {
            parts.push(Vec::new());
            cur_size = overhead(0);
        }
        parts.last_mut().unwrap().push(i);
        cur_size += sz + BLOB_ENTRY_SIZE as u64;
    }
    if parts.len() > u16::MAX as usize {
        return Err(EngineError::Unsupported("too many WIM parts".into()));
    }
    Ok(SplitPlan {
        parts,
        entries,
        header,
        xml,
    })
}

/// `install.wim` → `install.swm`, `install2.swm`, `install3.swm`, ...
pub fn part_name(base: &str, part: usize) -> String {
    if part == 1 {
        format!("{base}.swm")
    } else {
        format!("{base}{part}.swm")
    }
}

/// Write part `part` (1-based) of the plan to `out`, copying resources from
/// `src`. The header is computed up front, so `out` can be a plain stream
/// (e.g. a file being created on the FAT volume). Returns the bytes written.
pub fn write_part<R: Read + Seek, W: Write>(
    plan: &SplitPlan,
    part: usize,
    src: &mut R,
    out: &mut W,
    ctx: &OpContext,
    on_bytes: &mut dyn FnMut(u64),
) -> Result<u64> {
    let header = build_header(plan, part)?;
    let idx = &plan.parts[part - 1];
    out.write_all(&header).ctx("writing WIM part header")?;
    let mut pos = HEADER_SIZE as u64;
    let mut table = Vec::with_capacity(idx.len() * BLOB_ENTRY_SIZE);
    let mut buf = vec![0u8; 4 << 20];
    for &i in idx {
        ctx.check()?;
        let e = &plan.entries[i];
        src.seek(SeekFrom::Start(e.res.offset))
            .ctx("seeking WIM resource")?;
        let mut remaining = e.res.size_in_wim;
        while remaining > 0 {
            ctx.check()?;
            let n = remaining.min(buf.len() as u64) as usize;
            src.read_exact(&mut buf[..n]).ctx("reading WIM resource")?;
            out.write_all(&buf[..n]).ctx("writing WIM part")?;
            remaining -= n as u64;
            on_bytes(n as u64);
        }
        let mut res = e.res;
        res.offset = pos;
        pos += e.res.size_in_wim;
        let mut entry = [0u8; BLOB_ENTRY_SIZE];
        res.write(&mut entry[0..24]);
        entry[24..26].copy_from_slice(&(part as u16).to_le_bytes());
        entry[26..30].copy_from_slice(&e.refcnt.to_le_bytes());
        entry[30..50].copy_from_slice(&e.hash);
        table.extend_from_slice(&entry);
    }
    out.write_all(&table).ctx("writing WIM blob table")?;
    out.write_all(&plan.xml).ctx("writing WIM XML")?;
    let written = pos + table.len() as u64 + plan.xml.len() as u64;
    on_bytes((table.len() + plan.xml.len() + HEADER_SIZE) as u64);
    Ok(written)
}

/// Compute the final header of a part without writing any data.
fn build_header(plan: &SplitPlan, part: usize) -> Result<[u8; HEADER_SIZE]> {
    let idx = plan
        .parts
        .get(part - 1)
        .ok_or_else(|| EngineError::InvalidArgument("part out of range".into()))?;
    let mut pos = HEADER_SIZE as u64;
    let mut boot_metadata = ResHdr::default();
    let mut metadata_seen = 0u32;
    for &i in idx {
        let e = &plan.entries[i];
        let mut res = e.res;
        res.offset = pos;
        pos += e.res.size_in_wim;
        if e.res.flags & RES_FLAG_METADATA != 0 {
            metadata_seen += 1;
            if metadata_seen == plan.header.boot_index {
                boot_metadata = res;
            }
        }
    }
    let table_len = (idx.len() * BLOB_ENTRY_SIZE) as u64;
    let table_res = ResHdr {
        size_in_wim: table_len,
        flags: 0,
        offset: pos,
        uncompressed_size: table_len,
    };
    pos += table_len;
    let xml_res = ResHdr {
        size_in_wim: plan.xml.len() as u64,
        flags: 0,
        offset: pos,
        uncompressed_size: plan.xml.len() as u64,
    };
    let mut h = plan.header.raw;
    let flags = (plan.header.flags | HDR_FLAG_SPANNED) & !HDR_FLAG_WRITE_IN_PROGRESS;
    h[16..20].copy_from_slice(&flags.to_le_bytes());
    h[40..42].copy_from_slice(&(part as u16).to_le_bytes());
    h[42..44].copy_from_slice(&(plan.parts.len() as u16).to_le_bytes());
    table_res.write(&mut h[48..72]);
    xml_res.write(&mut h[72..96]);
    if part == 1 {
        boot_metadata
    } else {
        ResHdr::default()
    }
    .write(&mut h[96..120]);
    ResHdr::default().write(&mut h[124..148]);
    Ok(h)
}

/// Split into files on a regular file system (used by tests and by the
/// "split to folder" path). Returns the written part paths.
pub fn split_to_dir<R: Read + Seek>(
    src: &mut R,
    dir: &std::path::Path,
    base: &str,
    max_part: u64,
    ctx: &OpContext,
) -> Result<Vec<std::path::PathBuf>> {
    let plan = plan_split(src, max_part)?;
    let mut tracker = ctx.phase(Phase::SplittingWim, plan.total_bytes());
    let mut paths = Vec::new();
    for part in 1..=plan.part_count() {
        let path = dir.join(part_name(base, part));
        let mut f = std::fs::File::create(&path).ctx(format!("creating {}", path.display()))?;
        write_part(&plan, part, src, &mut f, ctx, &mut |n| tracker.advance(n))?;
        f.sync_all().ctx("syncing WIM part")?;
        paths.push(path);
    }
    tracker.finish();
    Ok(paths)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::progress::{CancelToken, NullSink};
    use std::io::Cursor;

    /// Build a synthetic, structurally valid WIM: 2 images, 5 blobs.
    pub(crate) fn synthetic_wim() -> Vec<u8> {
        let mut data = vec![0u8; HEADER_SIZE];
        let mut entries = Vec::new();
        let mut add = |data: &mut Vec<u8>, len: usize, fill: u8, flags: u8| {
            let off = data.len() as u64;
            data.extend(std::iter::repeat_n(fill, len));
            let mut e = [0u8; BLOB_ENTRY_SIZE];
            ResHdr {
                size_in_wim: len as u64,
                flags,
                offset: off,
                uncompressed_size: len as u64,
            }
            .write(&mut e[0..24]);
            e[24..26].copy_from_slice(&1u16.to_le_bytes());
            e[26..30].copy_from_slice(&1u32.to_le_bytes());
            e[30] = fill;
            entries.push(e);
        };
        add(&mut data, 3000, 0xA1, 0);
        add(&mut data, 500, 0xD1, RES_FLAG_METADATA);
        add(&mut data, 7000, 0xA2, RES_FLAG_COMPRESSED);
        add(&mut data, 600, 0xD2, RES_FLAG_METADATA);
        add(&mut data, 2500, 0xA3, 0);
        add(&mut data, 4000, 0xA4, 0);
        let table_off = data.len() as u64;
        for e in &entries {
            data.extend_from_slice(e);
        }
        let table_len = data.len() as u64 - table_off;
        let xml_text = "\u{feff}<WIM><IMAGE INDEX=\"1\"><NAME>Windows 11 Home</NAME><WINDOWS><ARCH>9</ARCH><LANGUAGES><LANGUAGE>it-IT</LANGUAGE></LANGUAGES><VERSION><BUILD>26100</BUILD></VERSION><EDITIONID>Core</EDITIONID></WINDOWS></IMAGE><IMAGE INDEX=\"2\"><DISPLAYNAME>Windows 11 Pro &amp; More</DISPLAYNAME><WINDOWS><ARCH>12</ARCH></WINDOWS></IMAGE></WIM>";
        let xml: Vec<u8> = xml_text
            .encode_utf16()
            .flat_map(|u| u.to_le_bytes())
            .collect();
        let xml_off = data.len() as u64;
        data.extend_from_slice(&xml);
        let h = &mut data[..HEADER_SIZE];
        h[0..8].copy_from_slice(MAGIC);
        h[8..12].copy_from_slice(&(HEADER_SIZE as u32).to_le_bytes());
        h[12..16].copy_from_slice(&0x10d00u32.to_le_bytes());
        h[16..20].copy_from_slice(&0x0004_0002u32.to_le_bytes());
        h[20..24].copy_from_slice(&32768u32.to_le_bytes());
        h[24..40].copy_from_slice(&[7u8; 16]);
        h[40..42].copy_from_slice(&1u16.to_le_bytes());
        h[42..44].copy_from_slice(&1u16.to_le_bytes());
        h[44..48].copy_from_slice(&2u32.to_le_bytes());
        ResHdr {
            size_in_wim: table_len,
            flags: 0,
            offset: table_off,
            uncompressed_size: table_len,
        }
        .write(&mut h[48..72]);
        ResHdr {
            size_in_wim: xml.len() as u64,
            flags: 0,
            offset: xml_off,
            uncompressed_size: xml.len() as u64,
        }
        .write(&mut h[72..96]);
        h[120..124].copy_from_slice(&1u32.to_le_bytes());
        data
    }

    #[test]
    fn inspect_reads_xml_images() {
        let wim = synthetic_wim();
        let info = inspect(&mut Cursor::new(&wim)).unwrap();
        assert_eq!(info.image_count, 2);
        assert_eq!(info.images[0].name, "Windows 11 Home");
        assert_eq!(info.images[0].arch.as_deref(), Some("x64"));
        assert_eq!(info.images[0].build, Some(26100));
        assert_eq!(info.images[0].languages, vec!["it-IT"]);
        assert_eq!(info.images[1].name, "Windows 11 Pro & More");
        assert_eq!(info.images[1].arch.as_deref(), Some("arm64"));
        assert!(!info.solid);
    }

    #[test]
    fn split_preserves_every_resource_and_metadata_order() {
        let wim = synthetic_wim();
        let ctx = OpContext::new(&NullSink, CancelToken::new());
        let mut src = Cursor::new(&wim);
        let plan = plan_split(&mut src, 9000).unwrap();
        assert!(plan.part_count() >= 3);
        assert!(plan.part_sizes().iter().all(|&s| s <= 9000));
        let mut parts = Vec::new();
        for p in 1..=plan.part_count() {
            let mut out = Cursor::new(Vec::new());
            write_part(&plan, p, &mut src, &mut out, &ctx, &mut |_| {}).unwrap();
            assert_eq!(out.get_ref().len() as u64, plan.part_sizes()[p - 1]);
            parts.push(out.into_inner());
        }
        let mut seen = Vec::new();
        for (pi, part) in parts.iter().enumerate() {
            let h = WimHeader::read(&mut &part[..]).unwrap();
            assert_eq!(h.part_number as usize, pi + 1);
            assert_eq!(h.total_parts as usize, parts.len());
            assert_eq!(h.flags & HDR_FLAG_SPANNED, HDR_FLAG_SPANNED);
            assert_eq!(&h.raw[24..40], &[7u8; 16], "GUID preserved");
            assert_eq!(h.image_count, 2);
            let table = read_blob_table(&mut Cursor::new(part), &h).unwrap();
            for e in table {
                assert_eq!(e.part as usize, pi + 1);
                let data =
                    &part[e.res.offset as usize..(e.res.offset + e.res.size_in_wim) as usize];
                assert!(
                    data.iter().all(|&b| b == e.hash[0]),
                    "resource content copied verbatim"
                );
                seen.push((e.hash[0], e.res.flags, pi + 1));
            }
            if pi == 0 {
                let bm = h.boot_metadata;
                assert_eq!(bm.flags & RES_FLAG_METADATA, RES_FLAG_METADATA);
                assert_eq!(
                    part[bm.offset as usize], 0xD1,
                    "boot index 1 → first metadata resource"
                );
            }
            let info = inspect(&mut Cursor::new(part)).unwrap();
            assert_eq!(info.images.len(), 2);
        }
        let metas: Vec<_> = seen
            .iter()
            .filter(|s| s.1 & RES_FLAG_METADATA != 0)
            .collect();
        assert_eq!(
            metas.iter().map(|m| m.0).collect::<Vec<_>>(),
            vec![0xD1, 0xD2]
        );
        assert!(metas.iter().all(|m| m.2 == 1));
        let mut ids: Vec<u8> = seen.iter().map(|s| s.0).collect();
        ids.sort();
        assert_eq!(ids, vec![0xA1, 0xA2, 0xA3, 0xA4, 0xD1, 0xD2]);
    }

    #[test]
    fn split_refuses_oversized_resource_and_solid() {
        let wim = synthetic_wim();
        assert!(matches!(
            plan_split(&mut Cursor::new(&wim), 5000),
            Err(EngineError::Unsupported(_))
        ));
        let mut solid = wim.clone();
        let h = WimHeader::read(&mut &solid[..]).unwrap();
        solid[h.blob_table.offset as usize + 7] |= RES_FLAG_SOLID;
        assert!(matches!(
            plan_split(&mut Cursor::new(&solid), 1 << 30),
            Err(EngineError::Unsupported(_))
        ));
    }

    #[test]
    fn part_names() {
        assert_eq!(part_name("install", 1), "install.swm");
        assert_eq!(part_name("install", 2), "install2.swm");
    }
}
