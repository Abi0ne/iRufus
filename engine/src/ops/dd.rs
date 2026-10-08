//! Raw (DD) image writing with read-back verification, and device zeroing.

use std::io::Read;
use std::path::Path;

use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::device::{AlignedBuf, BlockDevice, align_down, align_up};
use crate::error::{EngineError, IoContext, Result};
use crate::hash::hex;
use crate::image::source::{self, SourceInfo};
use crate::partition::{MIB, zero_range};
use crate::progress::{OpContext, Phase};

const CHUNK: usize = 4 << 20;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DdSummary {
    pub bytes_written: u64,
    pub sha256: String,
    pub verified: bool,
}

/// Fill `buf` from `r` until full or EOF. Returns the number of bytes read.
fn fill(r: &mut dyn Read, buf: &mut [u8]) -> Result<usize> {
    let mut n = 0;
    while n < buf.len() {
        match r.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => {
                return Err(match e.kind() {
                    std::io::ErrorKind::InvalidData
                    | std::io::ErrorKind::InvalidInput
                    | std::io::ErrorKind::UnexpectedEof => {
                        EngineError::CorruptImage(format!("image data could not be decoded: {e}"))
                    }
                    _ => EngineError::io("reading image", e),
                });
            }
        }
    }
    Ok(n)
}

pub fn write_dd(
    path: &Path,
    info: &SourceInfo,
    dev: &dyn BlockDevice,
    verify: bool,
    ctx: &OpContext,
) -> Result<DdSummary> {
    let bs = dev.block_size() as u64;
    let exact = info.data_size.filter(|_| info.size_is_exact);
    if let Some(sz) = exact
        && align_up(sz, bs) > dev.size()
    {
        return Err(EngineError::InsufficientSpace {
            needed: sz,
            available: dev.size(),
        });
    }
    let total_hint = exact.or(info.data_size).unwrap_or(info.file_size);
    ctx.log(format!(
        "DD write: {} → device of {} bytes (block {})",
        path.display(),
        dev.size(),
        bs
    ));

    // Clear stale partition structures at the end of the disk (backup GPT),
    // unless the image itself will cover that area.
    let tail = align_down(dev.size().saturating_sub(MIB), bs);
    if exact.is_none_or(|sz| sz < tail) {
        ctx.check()?;
        zero_range(dev, tail, dev.size() - tail)?;
    }

    let mut src = source::open_stream(path, info)?;
    let mut buf = AlignedBuf::new(CHUNK);
    let mut hasher = Sha256::new();
    let mut pos = 0u64;
    let mut tracker = ctx.phase(Phase::Writing, total_hint);
    loop {
        ctx.check()?;
        let n = fill(src.as_mut(), &mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        let padded = align_up(n as u64, bs) as usize;
        if pos + padded as u64 > dev.size() {
            return Err(EngineError::InsufficientSpace {
                needed: pos + n as u64,
                available: dev.size(),
            });
        }
        buf[n..padded].fill(0);
        dev.write_at(pos, &buf[..padded]).ctx("device write")?;
        pos += n as u64;
        tracker.advance(n as u64);
        if n < CHUNK {
            // Short read means EOF; confirm.
            let mut probe = [0u8; 1];
            if fill(src.as_mut(), &mut probe)? != 0 {
                return Err(EngineError::Internal(
                    "short read before end of stream".into(),
                ));
            }
            break;
        }
    }
    tracker.set_total(pos);
    tracker.finish();
    if pos == 0 {
        return Err(EngineError::CorruptImage("the image is empty".into()));
    }
    if let Some(sz) = exact
        && pos != sz
    {
        return Err(EngineError::CorruptImage(format!(
            "expected {sz} bytes of image data, got {pos}"
        )));
    }
    let sha256 = hex(&hasher.finalize());
    sync(dev, ctx)?;
    ctx.log(format!("Wrote {pos} bytes, SHA-256 {sha256}"));

    let verified = if verify {
        let readback = hash_device_prefix(dev, pos, ctx)?;
        if readback != sha256 {
            return Err(EngineError::VerifyFailed(format!(
                "data read back from the device differs (SHA-256 {readback})"
            )));
        }
        ctx.log("Read-back verification passed");
        true
    } else {
        false
    };
    Ok(DdSummary {
        bytes_written: pos,
        sha256,
        verified,
    })
}

pub fn sync(dev: &dyn BlockDevice, ctx: &OpContext) -> Result<()> {
    let t = ctx.phase(Phase::Syncing, 0);
    dev.sync().ctx("device sync")?;
    t.finish();
    Ok(())
}

/// SHA-256 of the first `len` bytes of the device.
pub fn hash_device_prefix(dev: &dyn BlockDevice, len: u64, ctx: &OpContext) -> Result<String> {
    let bs = dev.block_size() as u64;
    let mut buf = AlignedBuf::new(CHUNK);
    let mut hasher = Sha256::new();
    let mut pos = 0u64;
    let mut tracker = ctx.phase(Phase::Verifying, len);
    while pos < len {
        ctx.check()?;
        let want = (len - pos).min(CHUNK as u64);
        let padded = align_up(want, bs) as usize;
        dev.read_at(pos, &mut buf[..padded])
            .ctx("device read-back")?;
        hasher.update(&buf[..want as usize]);
        pos += want;
        tracker.advance(want);
    }
    tracker.finish();
    Ok(hex(&hasher.finalize()))
}

/// Overwrite the whole device with zeros, optionally verifying.
pub fn zero_device(dev: &dyn BlockDevice, verify: bool, ctx: &OpContext) -> Result<()> {
    let buf = AlignedBuf::new(CHUNK);
    let mut pos = 0u64;
    let mut tracker = ctx.phase(Phase::Zeroing, dev.size());
    while pos < dev.size() {
        ctx.check()?;
        let n = (dev.size() - pos).min(CHUNK as u64) as usize;
        dev.write_at(pos, &buf[..n]).ctx("device write")?;
        pos += n as u64;
        tracker.advance(n as u64);
    }
    tracker.finish();
    sync(dev, ctx)?;
    if verify {
        let mut rb = AlignedBuf::new(CHUNK);
        let mut pos = 0u64;
        let mut tracker = ctx.phase(Phase::Verifying, dev.size());
        while pos < dev.size() {
            ctx.check()?;
            let n = (dev.size() - pos).min(CHUNK as u64) as usize;
            dev.read_at(pos, &mut rb[..n]).ctx("device read-back")?;
            if rb[..n].iter().any(|&b| b != 0) {
                return Err(EngineError::VerifyFailed(format!(
                    "non-zero data read back near offset {pos}"
                )));
            }
            pos += n as u64;
            tracker.advance(n as u64);
        }
        tracker.finish();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device::FileDevice;
    use crate::progress::{CancelToken, NullSink};
    use std::io::Write;

    fn ctx() -> OpContext<'static> {
        OpContext::new(&NullSink, CancelToken::new())
    }

    #[test]
    fn dd_writes_and_verifies_unaligned_image() {
        let dir = tempfile::tempdir().unwrap();
        let img = dir.path().join("x.img");
        let data: Vec<u8> = (0..(9 * MIB as usize + 777))
            .map(|i| (i * 31 % 255) as u8)
            .collect();
        std::fs::write(&img, &data).unwrap();
        let dev = FileDevice::create(&dir.path().join("dev"), 32 * MIB, 512).unwrap();
        dev.write_at(31 * MIB, &vec![0xEE; MIB as usize]).unwrap();
        let info = source::probe(&img).unwrap();
        let s = write_dd(&img, &info, &dev, true, &ctx()).unwrap();
        assert_eq!(s.bytes_written, data.len() as u64);
        assert!(s.verified);
        let mut back = vec![0u8; data.len() + 512 - data.len() % 512];
        dev.read_at(0, &mut back).unwrap();
        assert_eq!(&back[..data.len()], &data[..]);
        assert!(back[data.len()..].iter().all(|&b| b == 0));
        let mut tail = vec![0u8; MIB as usize];
        dev.read_at(31 * MIB, &mut tail).unwrap();
        assert!(
            tail.iter().all(|&b| b == 0),
            "stale backup GPT area cleared"
        );
    }

    #[test]
    fn dd_rejects_image_larger_than_device() {
        let dir = tempfile::tempdir().unwrap();
        let img = dir.path().join("big.img");
        std::fs::write(&img, vec![1u8; 3 * MIB as usize]).unwrap();
        let dev = FileDevice::create(&dir.path().join("dev"), 2 * MIB, 512).unwrap();
        let info = source::probe(&img).unwrap();
        assert!(matches!(
            write_dd(&img, &info, &dev, false, &ctx()),
            Err(EngineError::InsufficientSpace { .. })
        ));
    }

    #[test]
    fn dd_detects_overflow_for_unknown_size_streams() {
        let dir = tempfile::tempdir().unwrap();
        let img = dir.path().join("big.img.bz2");
        let mut e = bzip2::write::BzEncoder::new(Vec::new(), bzip2::Compression::fast());
        e.write_all(&vec![7u8; 6 * MIB as usize]).unwrap();
        std::fs::write(&img, e.finish().unwrap()).unwrap();
        let dev = FileDevice::create(&dir.path().join("dev"), 4 * MIB, 512).unwrap();
        let info = source::probe(&img).unwrap();
        assert!(matches!(
            write_dd(&img, &info, &dev, false, &ctx()),
            Err(EngineError::InsufficientSpace { .. })
        ));
    }

    #[test]
    fn dd_reports_corrupt_compressed_data() {
        let dir = tempfile::tempdir().unwrap();
        let img = dir.path().join("c.img.gz");
        let mut e = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        let data: Vec<u8> = (0..2_000_000u32)
            .map(|i| (i.wrapping_mul(2654435761) >> 13) as u8)
            .collect();
        e.write_all(&data).unwrap();
        let mut bytes = e.finish().unwrap();
        let mid = bytes.len() / 2;
        for b in &mut bytes[mid..mid + 64] {
            *b ^= 0x5A;
        }
        std::fs::write(&img, bytes).unwrap();
        let dev = FileDevice::create(&dir.path().join("dev"), 8 * MIB, 512).unwrap();
        let info = source::probe(&img).unwrap();
        assert!(matches!(
            write_dd(&img, &info, &dev, false, &ctx()),
            Err(EngineError::CorruptImage(_))
        ));
    }

    #[test]
    fn dd_cancellation_stops_promptly() {
        let dir = tempfile::tempdir().unwrap();
        let img = dir.path().join("x.img");
        std::fs::write(&img, vec![3u8; 8 * MIB as usize]).unwrap();
        let dev = FileDevice::create(&dir.path().join("dev"), 16 * MIB, 512).unwrap();
        let c = OpContext::new(&NullSink, CancelToken::new());
        c.cancel.cancel();
        let info = source::probe(&img).unwrap();
        assert!(matches!(
            write_dd(&img, &info, &dev, true, &c),
            Err(EngineError::Cancelled)
        ));
    }

    /// Device whose content is corrupted after writing (simulated bad flash).
    struct LossyDevice(FileDevice);
    impl BlockDevice for LossyDevice {
        fn size(&self) -> u64 {
            self.0.size()
        }
        fn block_size(&self) -> u32 {
            self.0.block_size()
        }
        fn read_at(&self, offset: u64, buf: &mut [u8]) -> std::io::Result<()> {
            self.0.read_at(offset, buf)?;
            if offset == 0 {
                buf[100] ^= 1;
            }
            Ok(())
        }
        fn write_at(&self, offset: u64, buf: &[u8]) -> std::io::Result<()> {
            self.0.write_at(offset, buf)
        }
        fn sync(&self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn verification_catches_corruption() {
        let dir = tempfile::tempdir().unwrap();
        let img = dir.path().join("x.img");
        std::fs::write(&img, vec![9u8; MIB as usize]).unwrap();
        let dev = LossyDevice(FileDevice::create(&dir.path().join("dev"), 8 * MIB, 512).unwrap());
        let info = source::probe(&img).unwrap();
        assert!(matches!(
            write_dd(&img, &info, &dev, true, &ctx()),
            Err(EngineError::VerifyFailed(_))
        ));
    }

    #[test]
    fn zeroing_clears_everything() {
        let dir = tempfile::tempdir().unwrap();
        let dev = FileDevice::create(&dir.path().join("dev"), 5 * MIB + 512, 512).unwrap();
        dev.write_at(0, &vec![0xFF; (5 * MIB + 512) as usize])
            .unwrap();
        zero_device(&dev, true, &ctx()).unwrap();
    }
}
