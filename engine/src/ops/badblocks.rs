//! Destructive bad-block test, modelled on e2fsprogs `badblocks -w` as used by
//! Rufus: each pass writes a pattern over the whole device, then reads it all
//! back. Every 512-byte sector also carries its own absolute sector number, so
//! that "fake" drives which wrap addresses around (reporting more capacity than
//! they have) are detected: the read-back finds another sector's number.
//!
//! THIS DESTROYS ALL DATA ON THE DEVICE. The UI requires explicit confirmation.

use serde::Serialize;

use crate::device::{AlignedBuf, BlockDevice};
use crate::error::{EngineError, Result};
use crate::progress::{OpContext, Phase};

pub const PATTERNS: [u8; 4] = [0xAA, 0x55, 0xFF, 0x00];
const CHUNK: usize = 1 << 20;
const RETRY_UNIT: usize = 64 * 1024;
const MAX_REPORTED_RANGES: usize = 256;

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct BadBlocksReport {
    pub passes: u32,
    pub bytes_tested: u64,
    pub bad_sectors: u64,
    pub read_errors: u64,
    pub write_errors: u64,
    pub corruption_errors: u64,
    /// (offset, length) of bad areas, merged, capped in count.
    pub bad_ranges: Vec<(u64, u64)>,
    /// Sectors whose content was another sector's: typical of fake capacity.
    pub address_mismatches: u64,
    pub fake_capacity_suspected: bool,
    /// Offset of the first failing sector, if any (likely real capacity of a fake drive).
    pub first_bad_offset: Option<u64>,
}

impl BadBlocksReport {
    fn add_bad(&mut self, offset: u64, len: u64) {
        self.bad_sectors += len.div_ceil(512);
        self.first_bad_offset = Some(self.first_bad_offset.map_or(offset, |f| f.min(offset)));
        if let Some(last) = self.bad_ranges.last_mut()
            && last.0 + last.1 == offset
        {
            last.1 += len;
            return;
        }
        if self.bad_ranges.len() < MAX_REPORTED_RANGES {
            self.bad_ranges.push((offset, len));
        }
    }
}

fn fill_pattern(buf: &mut [u8], base_offset: u64, pattern: u8) {
    buf.fill(pattern);
    for (i, sector) in buf.as_chunks_mut::<512>().0.iter_mut().enumerate() {
        let lba = base_offset / 512 + i as u64;
        let tag = lba ^ (u64::from(pattern) * 0x0101_0101_0101_0101);
        sector[0..8].copy_from_slice(&tag.to_le_bytes());
    }
}

/// Run `passes` (1–4) patterns. Returns the report; the caller decides whether
/// bad sectors make the operation fail.
pub fn run(dev: &dyn BlockDevice, passes: u32, ctx: &OpContext) -> Result<BadBlocksReport> {
    if !(1..=4).contains(&passes) {
        return Err(EngineError::InvalidArgument(
            "bad blocks passes must be between 1 and 4".into(),
        ));
    }
    let size = dev.size();
    let mut report = BadBlocksReport {
        passes,
        ..Default::default()
    };
    let mut buf = AlignedBuf::new(CHUNK);
    let mut expect = AlignedBuf::new(CHUNK);
    let total = size * 2 * passes as u64;
    let mut tracker = ctx.phase(Phase::BadBlocks, total);
    for &pattern in PATTERNS.iter().take(passes as usize) {
        ctx.log(format!("Bad blocks: writing pattern 0x{pattern:02X}"));
        let mut pos = 0u64;
        while pos < size {
            ctx.check()?;
            let n = (size - pos).min(CHUNK as u64) as usize;
            fill_pattern(&mut buf[..n], pos, pattern);
            if dev.write_at(pos, &buf[..n]).is_err() {
                // Isolate failing areas in smaller units.
                let mut sub = 0;
                while sub < n {
                    let m = (n - sub).min(RETRY_UNIT);
                    if dev.write_at(pos + sub as u64, &buf[sub..sub + m]).is_err() {
                        report.write_errors += 1;
                        report.add_bad(pos + sub as u64, m as u64);
                    }
                    sub += m;
                }
            }
            pos += n as u64;
            tracker.advance(n as u64);
        }
        if dev.sync().is_err() {
            ctx.log("WARNING: device cache flush failed");
        }
        ctx.log(format!("Bad blocks: reading back pattern 0x{pattern:02X}"));
        let mut pos = 0u64;
        while pos < size {
            ctx.check()?;
            let n = (size - pos).min(CHUNK as u64) as usize;
            fill_pattern(&mut expect[..n], pos, pattern);
            match dev.read_at(pos, &mut buf[..n]) {
                Ok(()) => compare(&buf[..n], &expect[..n], pos, pattern, &mut report),
                Err(e)
                    if e.raw_os_error() == Some(libc::ENXIO)
                        || e.raw_os_error() == Some(libc::ENODEV) =>
                {
                    return Err(EngineError::DeviceGone(e.to_string()));
                }
                Err(_) => {
                    let mut sub = 0;
                    while sub < n {
                        let m = (n - sub).min(RETRY_UNIT);
                        match dev.read_at(pos + sub as u64, &mut buf[sub..sub + m]) {
                            Ok(()) => compare(
                                &buf[sub..sub + m],
                                &expect[sub..sub + m],
                                pos + sub as u64,
                                pattern,
                                &mut report,
                            ),
                            Err(_) => {
                                report.read_errors += 1;
                                report.add_bad(pos + sub as u64, m as u64);
                            }
                        }
                        sub += m;
                    }
                }
            }
            pos += n as u64;
            tracker.advance(n as u64);
        }
        report.bytes_tested += size;
    }
    tracker.finish();
    // Fake drives: address mismatches, or every sector bad from some point to the end.
    let tail_bad = report.bad_ranges.last().is_some_and(|r| r.0 + r.1 == size)
        && report.bad_ranges.len() < MAX_REPORTED_RANGES;
    report.fake_capacity_suspected = report.address_mismatches > 0
        || (tail_bad
            && report
                .first_bad_offset
                .is_some_and(|f| f > 0 && size - f > size / 8));
    ctx.log(format!(
        "Bad blocks: {} bad sector(s), {} read / {} write / {} corruption error(s){}",
        report.bad_sectors,
        report.read_errors,
        report.write_errors,
        report.corruption_errors,
        if report.fake_capacity_suspected {
            " — FAKE CAPACITY SUSPECTED"
        } else {
            ""
        }
    ));
    Ok(report)
}

fn compare(got: &[u8], want: &[u8], base: u64, pattern: u8, report: &mut BadBlocksReport) {
    if got == want {
        return;
    }
    for (i, (g, w)) in got
        .as_chunks::<512>()
        .0
        .iter()
        .zip(want.as_chunks::<512>().0.iter())
        .enumerate()
    {
        if g == w {
            continue;
        }
        report.corruption_errors += 1;
        let tag = u64::from_le_bytes(g[0..8].try_into().unwrap())
            ^ (u64::from(pattern) * 0x0101_0101_0101_0101);
        let own = base / 512 + i as u64;
        if tag != own && g[8..] == w[8..] {
            report.address_mismatches += 1;
        }
        report.add_bad(base + (i * 512) as u64, 512);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device::FileDevice;
    use crate::progress::{CancelToken, NullSink};
    use std::io;

    fn ctx() -> OpContext<'static> {
        OpContext::new(&NullSink, CancelToken::new())
    }

    #[test]
    fn healthy_device_passes() {
        let dir = tempfile::tempdir().unwrap();
        let dev = FileDevice::create(&dir.path().join("d"), 3 << 20, 512).unwrap();
        let r = run(&dev, 2, &ctx()).unwrap();
        assert_eq!(r.bad_sectors, 0);
        assert!(!r.fake_capacity_suspected);
        assert_eq!(r.bytes_tested, 2 * (3 << 20));
    }

    /// Simulates a fake 8 MiB drive with only 2 MiB of real flash (addresses wrap).
    struct FakeDrive(FileDevice);
    impl BlockDevice for FakeDrive {
        fn size(&self) -> u64 {
            8 << 20
        }
        fn block_size(&self) -> u32 {
            512
        }
        fn read_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()> {
            for (i, c) in buf.chunks_mut(512).enumerate() {
                self.0.read_at((offset + i as u64 * 512) % (2 << 20), c)?;
            }
            Ok(())
        }
        fn write_at(&self, offset: u64, buf: &[u8]) -> io::Result<()> {
            for (i, c) in buf.chunks(512).enumerate() {
                self.0.write_at((offset + i as u64 * 512) % (2 << 20), c)?;
            }
            Ok(())
        }
        fn sync(&self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn wrapping_fake_drive_is_detected() {
        let dir = tempfile::tempdir().unwrap();
        let dev = FakeDrive(FileDevice::create(&dir.path().join("d"), 2 << 20, 512).unwrap());
        let r = run(&dev, 1, &ctx()).unwrap();
        assert!(r.fake_capacity_suspected);
        assert!(r.address_mismatches > 0);
        assert!(r.bad_sectors >= (6 << 20) / 512);
    }

    /// Device with an unreadable area.
    struct Faulty(FileDevice);
    impl BlockDevice for Faulty {
        fn size(&self) -> u64 {
            self.0.size()
        }
        fn block_size(&self) -> u32 {
            512
        }
        fn read_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()> {
            let bad = 1_048_576u64..1_048_576 + 65_536;
            if offset < bad.end && offset + buf.len() as u64 > bad.start {
                return Err(io::Error::from_raw_os_error(libc::EIO));
            }
            self.0.read_at(offset, buf)
        }
        fn write_at(&self, offset: u64, buf: &[u8]) -> io::Result<()> {
            self.0.write_at(offset, buf)
        }
        fn sync(&self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn read_errors_are_isolated() {
        let dir = tempfile::tempdir().unwrap();
        let dev = Faulty(FileDevice::create(&dir.path().join("d"), 4 << 20, 512).unwrap());
        let r = run(&dev, 1, &ctx()).unwrap();
        assert_eq!(r.read_errors, 1);
        assert_eq!(r.bad_sectors, 128);
        assert_eq!(r.bad_ranges, vec![(1 << 20, 65536)]);
        assert!(!r.fake_capacity_suspected);
    }

    #[test]
    fn invalid_pass_count() {
        let dir = tempfile::tempdir().unwrap();
        let dev = FileDevice::create(&dir.path().join("d"), 1 << 20, 512).unwrap();
        assert!(run(&dev, 0, &ctx()).is_err());
        assert!(run(&dev, 5, &ctx()).is_err());
    }
}
