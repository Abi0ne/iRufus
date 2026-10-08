//! Image containers: raw files, compressed streams (gzip, xz, zstd, bzip2),
//! ZIP archives (incl. ZIP64) holding a single disk image, and fixed VHDs.

use std::fs::File;
use std::io::{self, BufReader, Read, Seek, SeekFrom};
use std::os::unix::fs::FileExt;
use std::path::Path;

use serde::Serialize;

use crate::error::{EngineError, IoContext, Result};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Container {
    Raw,
    Gzip,
    Xz,
    Zstd,
    Bzip2,
    Zip { entry: String, method: String },
    VhdFixed,
}

impl Container {
    pub fn is_compressed(&self) -> bool {
        !matches!(self, Container::Raw | Container::VhdFixed)
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceInfo {
    pub container: Container,
    pub file_size: u64,
    /// Size of the contained image, when known.
    pub data_size: Option<u64>,
    /// False when `data_size` is only an estimate (e.g. gzip ISIZE modulo 4 GiB).
    pub size_is_exact: bool,
    #[serde(skip)]
    zip_data: Option<(u64, u64, u16)>,
}

const GZ: &[u8] = &[0x1F, 0x8B];
const XZ: &[u8] = &[0xFD, b'7', b'z', b'X', b'Z', 0x00];
const ZSTD: &[u8] = &[0x28, 0xB5, 0x2F, 0xFD];
const BZ2: &[u8] = b"BZh";
const ZIP: &[u8] = b"PK\x03\x04";

pub fn probe(path: &Path) -> Result<SourceInfo> {
    let file = File::open(path).ctx(format!("opening {}", path.display()))?;
    let file_size = file.metadata().ctx("reading image metadata")?.len();
    let mut magic = [0u8; 8];
    let n = file.read_at(&mut magic, 0).ctx("reading image header")?;
    let magic = &magic[..n];
    let info = |container, data_size, size_is_exact| SourceInfo {
        container,
        file_size,
        data_size,
        size_is_exact,
        zip_data: None,
    };
    if magic.starts_with(XZ) {
        let size = xz_uncompressed_size(&file, file_size);
        return Ok(info(Container::Xz, size, size.is_some()));
    }
    if magic.starts_with(ZSTD) {
        let mut head = vec![0u8; 18.min(file_size as usize)];
        file.read_exact_at(&mut head, 0)
            .ctx("reading zstd header")?;
        let size = zstd::zstd_safe::get_frame_content_size(&head)
            .ok()
            .flatten();
        // Only exact if the file holds a single frame; we cannot cheaply know, so mark as estimate.
        return Ok(info(Container::Zstd, size, false));
    }
    if magic.starts_with(GZ) {
        let mut tail = [0u8; 4];
        let est = if file_size >= 18 {
            file.read_exact_at(&mut tail, file_size - 4)
                .ctx("reading gzip trailer")?;
            Some(u32::from_le_bytes(tail) as u64)
        } else {
            None
        };
        return Ok(info(Container::Gzip, est, false));
    }
    if magic.starts_with(BZ2) && magic.len() > 3 && (b'1'..=b'9').contains(&magic[3]) {
        return Ok(info(Container::Bzip2, None, false));
    }
    if magic.starts_with(ZIP) {
        return probe_zip(file, file_size);
    }
    if file_size >= 512 + 512 {
        let mut footer = [0u8; 512];
        file.read_exact_at(&mut footer, file_size - 512)
            .ctx("reading VHD footer")?;
        if &footer[0..8] == b"conectix" {
            let disk_type = u32::from_be_bytes(footer[60..64].try_into().unwrap());
            let current = u64::from_be_bytes(footer[48..56].try_into().unwrap());
            if disk_type == 2 {
                return Ok(info(
                    Container::VhdFixed,
                    Some(current.min(file_size - 512)),
                    true,
                ));
            }
            return Err(EngineError::UnsupportedImage("dynamic or differencing VHD images are not supported; convert to a fixed VHD or raw image".into()));
        }
    }
    if file_size >= 8 {
        let mut vhdx = [0u8; 8];
        file.read_exact_at(&mut vhdx, 0)
            .ctx("reading image header")?;
        if &vhdx == b"vhdxfile" {
            return Err(EngineError::UnsupportedImage(
                "VHDX images are not supported in this version".into(),
            ));
        }
    }
    Ok(info(Container::Raw, Some(file_size), true))
}

fn probe_zip(file: File, file_size: u64) -> Result<SourceInfo> {
    let mut archive = zip::ZipArchive::new(BufReader::new(file))
        .map_err(|e| EngineError::CorruptImage(format!("ZIP: {e}")))?;
    let mut best: Option<(usize, u64)> = None;
    let mut candidates = 0;
    for i in 0..archive.len() {
        let f = archive
            .by_index_raw(i)
            .map_err(|e| EngineError::CorruptImage(format!("ZIP: {e}")))?;
        if f.is_dir() {
            continue;
        }
        let lower = f.name().to_ascii_lowercase();
        let is_image = [".img", ".iso", ".raw", ".bin", ".dd"]
            .iter()
            .any(|ext| lower.ends_with(ext));
        if is_image {
            candidates += 1;
            if best.is_none_or(|(_, s)| f.size() > s) {
                best = Some((i, f.size()));
            }
        }
    }
    if candidates > 1 {
        return Err(EngineError::UnsupportedImage(
            "the ZIP archive contains more than one disk image".into(),
        ));
    }
    let (idx, size) = best.ok_or_else(|| {
        EngineError::UnsupportedImage(
            "the ZIP archive contains no disk image (.img/.iso/.raw/.bin)".into(),
        )
    })?;
    let f = archive
        .by_index(idx)
        .map_err(|e| EngineError::CorruptImage(format!("ZIP: {e}")))?;
    if f.encrypted() {
        return Err(EngineError::UnsupportedImage(
            "encrypted ZIP archives are not supported".into(),
        ));
    }
    let method = f.compression();
    let method_id: u16 = match method {
        zip::CompressionMethod::Stored => 0,
        zip::CompressionMethod::Deflated => 8,
        zip::CompressionMethod::Bzip2 => 12,
        zip::CompressionMethod::Zstd => 93,
        other => {
            return Err(EngineError::UnsupportedImage(format!(
                "ZIP compression method {other:?} is not supported"
            )));
        }
    };
    let start = f
        .data_start()
        .ok_or_else(|| EngineError::CorruptImage("ZIP entry without data offset".into()))?;
    let name = f.name().to_string();
    let compressed = f.compressed_size();
    Ok(SourceInfo {
        container: Container::Zip {
            entry: name,
            method: format!("{method:?}"),
        },
        file_size,
        data_size: Some(size),
        size_is_exact: true,
        zip_data: Some((start, compressed, method_id)),
    })
}

/// Parse the xz index to get the total uncompressed size (single or concatenated streams).
fn xz_uncompressed_size(file: &File, file_size: u64) -> Option<u64> {
    let mut end = file_size;
    let mut total = 0u64;
    for _ in 0..64 {
        // Skip stream padding (multiples of 4 zero bytes).
        loop {
            if end < 4 {
                return None;
            }
            let mut p = [0u8; 4];
            file.read_exact_at(&mut p, end - 4).ok()?;
            if p == [0; 4] { end -= 4 } else { break }
        }
        if end < 12 + 12 {
            return None;
        }
        let mut footer = [0u8; 12];
        file.read_exact_at(&mut footer, end - 12).ok()?;
        if &footer[10..12] != b"YZ" {
            return None;
        }
        let backward = (u32::from_le_bytes(footer[4..8].try_into().unwrap()) as u64 + 1) * 4;
        let index_start = end.checked_sub(12 + backward)?;
        let mut index = vec![0u8; backward as usize];
        file.read_exact_at(&mut index, index_start).ok()?;
        if index[0] != 0 {
            return None;
        }
        let mut pos = 1;
        let count = varint(&index, &mut pos)?;
        let mut unpadded_sum = 0u64;
        for _ in 0..count {
            let unpadded = varint(&index, &mut pos)?;
            let uncompressed = varint(&index, &mut pos)?;
            unpadded_sum += unpadded.div_ceil(4) * 4;
            total = total.checked_add(uncompressed)?;
        }
        let stream_start = index_start.checked_sub(12 + unpadded_sum)?;
        if stream_start == 0 {
            return Some(total);
        }
        end = stream_start;
    }
    None
}

fn varint(b: &[u8], pos: &mut usize) -> Option<u64> {
    let mut v = 0u64;
    for i in 0..9 {
        let byte = *b.get(*pos)?;
        *pos += 1;
        v |= ((byte & 0x7F) as u64) << (7 * i);
        if byte & 0x80 == 0 {
            return Some(v);
        }
    }
    None
}

/// Open the contained image as a sequential stream of its raw bytes.
pub fn open_stream(path: &Path, info: &SourceInfo) -> Result<Box<dyn Read + Send>> {
    let file = File::open(path).ctx(format!("opening {}", path.display()))?;
    let buffered = BufReader::with_capacity(1 << 20, file);
    Ok(match &info.container {
        Container::Raw => Box::new(buffered),
        Container::VhdFixed => Box::new(buffered.take(info.data_size.unwrap_or(0))),
        Container::Gzip => Box::new(flate2::read::MultiGzDecoder::new(buffered)),
        Container::Xz => Box::new(xz2::read::XzDecoder::new_multi_decoder(buffered)),
        Container::Zstd => {
            Box::new(zstd::stream::read::Decoder::with_buffer(buffered).ctx("initialising zstd")?)
        }
        Container::Bzip2 => Box::new(bzip2::read::MultiBzDecoder::new(buffered)),
        Container::Zip { .. } => {
            let (start, compressed, method) = info
                .zip_data
                .ok_or_else(|| EngineError::Internal("ZIP data offset missing".into()))?;
            let mut file = File::open(path).ctx(format!("opening {}", path.display()))?;
            file.seek(SeekFrom::Start(start)).ctx("seeking ZIP entry")?;
            let raw = BufReader::with_capacity(1 << 20, file).take(compressed);
            match method {
                0 => Box::new(raw),
                8 => Box::new(flate2::read::DeflateDecoder::new(raw)),
                12 => Box::new(bzip2::read::BzDecoder::new(raw)),
                93 => Box::new(
                    zstd::stream::read::Decoder::with_buffer(raw).ctx("initialising zstd")?,
                ),
                _ => return Err(EngineError::Internal("unexpected ZIP method".into())),
            }
        }
    })
}

/// Read up to `n` bytes from the start of the contained image.
pub fn read_head(path: &Path, info: &SourceInfo, n: usize) -> Result<Vec<u8>> {
    let mut s = open_stream(path, info)?;
    let mut buf = Vec::with_capacity(n);
    s.by_ref()
        .take(n as u64)
        .read_to_end(&mut buf)
        .map_err(|e| match e.kind() {
            io::ErrorKind::InvalidData
            | io::ErrorKind::InvalidInput
            | io::ErrorKind::UnexpectedEof => {
                EngineError::CorruptImage(format!("decompression failed: {e}"))
            }
            _ => EngineError::io("reading image", e),
        })?;
    Ok(buf)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn sample() -> Vec<u8> {
        (0..1_000_000u32)
            .map(|i| (i.wrapping_mul(2654435761) >> 24) as u8)
            .collect()
    }

    fn roundtrip(path: &Path, expected: &[u8]) -> SourceInfo {
        let info = probe(path).unwrap();
        let mut out = Vec::new();
        open_stream(path, &info)
            .unwrap()
            .read_to_end(&mut out)
            .unwrap();
        assert_eq!(out, expected, "{:?}", info.container);
        info
    }

    #[test]
    fn all_containers_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let data = sample();

        let p = dir.path().join("a.img");
        std::fs::write(&p, &data).unwrap();
        assert_eq!(roundtrip(&p, &data).container, Container::Raw);

        let p = dir.path().join("a.img.gz");
        let mut e = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        e.write_all(&data).unwrap();
        std::fs::write(&p, e.finish().unwrap()).unwrap();
        let i = roundtrip(&p, &data);
        assert_eq!(i.container, Container::Gzip);
        assert_eq!(i.data_size, Some(data.len() as u64));

        let p = dir.path().join("a.img.xz");
        let mut e = xz2::write::XzEncoder::new(Vec::new(), 1);
        e.write_all(&data).unwrap();
        std::fs::write(&p, e.finish().unwrap()).unwrap();
        let i = roundtrip(&p, &data);
        assert_eq!(i.container, Container::Xz);
        assert_eq!(i.data_size, Some(data.len() as u64));
        assert!(i.size_is_exact);

        let p = dir.path().join("a.img.zst");
        std::fs::write(&p, zstd::encode_all(&data[..], 3).unwrap()).unwrap();
        let i = roundtrip(&p, &data);
        assert_eq!(i.container, Container::Zstd);
        // Streaming encoders may omit the frame content size; never exact.
        assert!(i.data_size.is_none_or(|s| s == data.len() as u64));
        assert!(!i.size_is_exact);

        let p = dir.path().join("a.img.bz2");
        let mut e = bzip2::write::BzEncoder::new(Vec::new(), bzip2::Compression::fast());
        e.write_all(&data).unwrap();
        std::fs::write(&p, e.finish().unwrap()).unwrap();
        assert_eq!(roundtrip(&p, &data).container, Container::Bzip2);

        for method in [
            zip::CompressionMethod::Stored,
            zip::CompressionMethod::Deflated,
        ] {
            let p = dir.path().join(format!("a-{method:?}.zip"));
            let mut z = zip::ZipWriter::new(File::create(&p).unwrap());
            z.add_directory("docs/", zip::write::SimpleFileOptions::default())
                .unwrap();
            z.start_file("docs/readme.txt", zip::write::SimpleFileOptions::default())
                .unwrap();
            z.write_all(b"hello").unwrap();
            z.start_file(
                "disk.img",
                zip::write::SimpleFileOptions::default().compression_method(method),
            )
            .unwrap();
            z.write_all(&data).unwrap();
            z.finish().unwrap();
            let i = roundtrip(&p, &data);
            assert!(matches!(i.container, Container::Zip { ref entry, .. } if entry == "disk.img"));
        }
    }

    #[test]
    fn fixed_vhd_is_unwrapped_and_dynamic_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let data = vec![0x5Au8; 4096];
        let mut footer = [0u8; 512];
        footer[0..8].copy_from_slice(b"conectix");
        footer[48..56].copy_from_slice(&(data.len() as u64).to_be_bytes());
        footer[60..64].copy_from_slice(&2u32.to_be_bytes());
        let p = dir.path().join("d.vhd");
        std::fs::write(&p, [&data[..], &footer[..]].concat()).unwrap();
        assert_eq!(roundtrip(&p, &data).container, Container::VhdFixed);
        footer[60..64].copy_from_slice(&3u32.to_be_bytes());
        std::fs::write(&p, [&data[..], &footer[..]].concat()).unwrap();
        assert!(matches!(probe(&p), Err(EngineError::UnsupportedImage(_))));
    }

    #[test]
    fn corrupt_compressed_stream_is_reported() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("bad.xz");
        let mut e = xz2::write::XzEncoder::new(Vec::new(), 1);
        e.write_all(&sample()).unwrap();
        let mut bytes = e.finish().unwrap();
        let mid = bytes.len() / 2;
        bytes[mid] ^= 0xFF;
        bytes[mid + 1] ^= 0xFF;
        std::fs::write(&p, bytes).unwrap();
        let info = probe(&p).unwrap();
        let mut out = Vec::new();
        assert!(
            open_stream(&p, &info)
                .unwrap()
                .read_to_end(&mut out)
                .is_err()
        );
    }

    #[test]
    fn zip_with_two_images_is_ambiguous() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("two.zip");
        let mut z = zip::ZipWriter::new(File::create(&p).unwrap());
        for n in ["a.img", "b.iso"] {
            z.start_file(n, zip::write::SimpleFileOptions::default())
                .unwrap();
            z.write_all(b"x").unwrap();
        }
        z.finish().unwrap();
        assert!(matches!(probe(&p), Err(EngineError::UnsupportedImage(_))));
    }
}
