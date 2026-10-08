//! Save a whole device to a raw (.img) or fixed VHD (.vhd) image file.

use std::fs::File;
use std::io::Write;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::device::{AlignedBuf, BlockDevice};
use crate::error::{IoContext, Result};
use crate::hash::hex;
use crate::partition::random_bytes;
use crate::progress::{OpContext, Phase};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SaveFormat {
    Raw,
    VhdFixed,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SaveSummary {
    pub bytes_read: u64,
    pub sha256: String,
    pub file_size: u64,
}

/// VHD footer for a fixed disk (Microsoft "Virtual Hard Disk Image Format Specification").
pub fn vhd_footer(size: u64) -> [u8; 512] {
    let mut f = [0u8; 512];
    f[0..8].copy_from_slice(b"conectix");
    f[8..12].copy_from_slice(&2u32.to_be_bytes());
    f[12..16].copy_from_slice(&0x0001_0000u32.to_be_bytes());
    f[16..24].copy_from_slice(&u64::MAX.to_be_bytes());
    let vhd_epoch = 946_684_800u64; // 2000-01-01T00:00:00Z
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(vhd_epoch);
    f[24..28].copy_from_slice(&((now.saturating_sub(vhd_epoch)) as u32).to_be_bytes());
    f[28..32].copy_from_slice(b"irfs");
    f[32..36].copy_from_slice(&0x0001_0000u32.to_be_bytes());
    f[36..40].copy_from_slice(b"Mac ");
    f[40..48].copy_from_slice(&size.to_be_bytes());
    f[48..56].copy_from_slice(&size.to_be_bytes());
    let (c, h, s) = vhd_chs(size / 512);
    f[56..58].copy_from_slice(&c.to_be_bytes());
    f[58] = h;
    f[59] = s;
    f[60..64].copy_from_slice(&2u32.to_be_bytes());
    f[68..84].copy_from_slice(&random_bytes::<16>());
    let sum: u32 = f.iter().fold(0u32, |a, &b| a.wrapping_add(b as u32));
    f[64..68].copy_from_slice(&(!sum).to_be_bytes());
    f
}

/// CHS geometry algorithm from the VHD specification (appendix).
fn vhd_chs(total_sectors: u64) -> (u16, u8, u8) {
    let total = total_sectors.min(65535 * 16 * 255);
    let (spt, heads, cyl_times_heads);
    if total >= 65535 * 16 * 63 {
        spt = 255;
        heads = 16;
        cyl_times_heads = total / spt;
    } else {
        let mut s = 17;
        let mut cth = total / s;
        let mut h = cth.div_ceil(1024).max(4);
        if cth >= h * 1024 || h > 16 {
            s = 31;
            h = 16;
            cth = total / s;
        }
        if cth >= h * 1024 {
            s = 63;
            h = 16;
            cth = total / s;
        }
        spt = s;
        heads = h;
        cyl_times_heads = cth;
    }
    ((cyl_times_heads / heads) as u16, heads as u8, spt as u8)
}

pub fn save_device(
    dev: &dyn BlockDevice,
    out_path: &Path,
    format: SaveFormat,
    ctx: &OpContext,
) -> Result<SaveSummary> {
    let mut out = File::create(out_path).ctx(format!("creating {}", out_path.display()))?;
    let size = dev.size();
    let chunk = 4usize << 20;
    let mut buf = AlignedBuf::new(chunk);
    let mut hasher = Sha256::new();
    let mut pos = 0u64;
    let mut tracker = ctx.phase(Phase::Reading, size);
    let result = (|| -> Result<()> {
        while pos < size {
            ctx.check()?;
            let n = (size - pos).min(chunk as u64) as usize;
            dev.read_at(pos, &mut buf[..n]).ctx("device read")?;
            hasher.update(&buf[..n]);
            out.write_all(&buf[..n]).ctx("writing image file")?;
            pos += n as u64;
            tracker.advance(n as u64);
        }
        if format == SaveFormat::VhdFixed {
            out.write_all(&vhd_footer(size)).ctx("writing VHD footer")?;
        }
        out.sync_all().ctx("syncing image file")?;
        Ok(())
    })();
    if let Err(e) = result {
        drop(out);
        let _ = std::fs::remove_file(out_path);
        return Err(e);
    }
    tracker.finish();
    let file_size = out.metadata().ctx("reading image size")?.len();
    let sha256 = hex(&hasher.finalize());
    ctx.log(format!(
        "Saved {size} bytes to {} (SHA-256 of disk data {sha256})",
        out_path.display()
    ));
    Ok(SaveSummary {
        bytes_read: size,
        sha256,
        file_size,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device::FileDevice;
    use crate::image::source::{self, Container};
    use crate::progress::{CancelToken, NullSink};

    #[test]
    fn saved_vhd_is_recognised_and_roundtrips() {
        let dir = tempfile::tempdir().unwrap();
        let dev = FileDevice::create(&dir.path().join("d"), 3 << 20, 512).unwrap();
        let data: Vec<u8> = (0..3u32 << 20).map(|i| (i % 249) as u8).collect();
        dev.write_at(0, &data).unwrap();
        let ctx = OpContext::new(&NullSink, CancelToken::new());
        let out = dir.path().join("save.vhd");
        let s = save_device(&dev, &out, SaveFormat::VhdFixed, &ctx).unwrap();
        assert_eq!(s.file_size, (3 << 20) + 512);
        let info = source::probe(&out).unwrap();
        assert_eq!(info.container, Container::VhdFixed);
        assert_eq!(info.data_size, Some(3 << 20));
        let footer = vhd_footer(3 << 20);
        let mut check = footer;
        check[64..68].fill(0);
        let sum: u32 = check.iter().fold(0u32, |a, &b| a.wrapping_add(b as u32));
        assert_eq!(u32::from_be_bytes(footer[64..68].try_into().unwrap()), !sum);
        assert_eq!(s.sha256, crate::hash::sha256_of(&data));
    }

    #[test]
    fn cancelled_save_removes_partial_file() {
        let dir = tempfile::tempdir().unwrap();
        let dev = FileDevice::create(&dir.path().join("d"), 1 << 20, 512).unwrap();
        let ctx = OpContext::new(&NullSink, CancelToken::new());
        ctx.cancel.cancel();
        let out = dir.path().join("x.img");
        assert!(save_device(&dev, &out, SaveFormat::Raw, &ctx).is_err());
        assert!(!out.exists());
    }

    #[test]
    fn chs_for_known_sizes() {
        assert_eq!(vhd_chs(2048 * 1024 * 2), (4161, 16, 63));
        let (c, h, s) = vhd_chs(10000);
        assert!(c as u64 * h as u64 * s as u64 <= 10000);
    }
}
