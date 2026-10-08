//! Byte-addressable `Read + Write + Seek` view of a region of a block device,
//! with a small write-back cache. File-system code (the FAT driver) issues many
//! small unaligned accesses; this adapter turns them into aligned, coalesced
//! device I/O and performs read-modify-write only on partially written blocks.

use std::io::{self, Read, Seek, SeekFrom, Write};

use crate::device::{AlignedBuf, BlockDevice};
use crate::error::CancelledIo;
use crate::progress::CancelToken;

const DEFAULT_CHUNK: u64 = 1 << 20;
const DEFAULT_CHUNKS: usize = 32;

struct Chunk {
    index: u64,
    data: AlignedBuf,
    len: usize,
    present: Vec<bool>,
    dirty: Vec<bool>,
    last_use: u64,
}

pub struct RegionIo<'d> {
    dev: &'d dyn BlockDevice,
    start: u64,
    len: u64,
    pos: u64,
    chunk_size: u64,
    block: u64,
    max_chunks: usize,
    chunks: Vec<Chunk>,
    tick: u64,
    cancel: Option<CancelToken>,
}

impl<'d> RegionIo<'d> {
    /// `start` and `len` must be multiples of the device block size.
    pub fn new(dev: &'d dyn BlockDevice, start: u64, len: u64) -> io::Result<Self> {
        let block = dev.block_size() as u64;
        if !start.is_multiple_of(block)
            || !len.is_multiple_of(block)
            || start.checked_add(len).is_none_or(|end| end > dev.size())
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "region not aligned to device blocks or out of range",
            ));
        }
        let chunk_size = DEFAULT_CHUNK.max(block) / block * block;
        Ok(Self {
            dev,
            start,
            len,
            pos: 0,
            chunk_size,
            block,
            max_chunks: DEFAULT_CHUNKS,
            chunks: Vec::new(),
            tick: 0,
            cancel: None,
        })
    }

    pub fn with_cancel(mut self, cancel: CancelToken) -> Self {
        self.cancel = Some(cancel);
        self
    }

    pub fn len(&self) -> u64 {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    fn check_cancel(&self) -> io::Result<()> {
        match &self.cancel {
            Some(c) if c.is_cancelled() => Err(CancelledIo::io_error()),
            _ => Ok(()),
        }
    }

    fn chunk_slot(&mut self, index: u64) -> io::Result<usize> {
        self.tick += 1;
        if let Some(i) = self.chunks.iter().position(|c| c.index == index) {
            self.chunks[i].last_use = self.tick;
            return Ok(i);
        }
        if self.chunks.len() >= self.max_chunks {
            let victim = self
                .chunks
                .iter()
                .enumerate()
                .min_by_key(|(_, c)| c.last_use)
                .map(|(i, _)| i)
                .expect("cache not empty");
            self.flush_chunk(victim)?;
            self.chunks.swap_remove(victim);
        }
        let chunk_start = index * self.chunk_size;
        let len = (self.len - chunk_start).min(self.chunk_size) as usize;
        let blocks = len / self.block as usize;
        self.chunks.push(Chunk {
            index,
            data: AlignedBuf::new(len),
            len,
            present: vec![false; blocks],
            dirty: vec![false; blocks],
            last_use: self.tick,
        });
        Ok(self.chunks.len() - 1)
    }

    /// Make blocks [first, last] of a chunk present, reading contiguous runs.
    fn fill(&mut self, slot: usize, first: usize, last: usize) -> io::Result<()> {
        let block = self.block as usize;
        let base = self.start + self.chunks[slot].index * self.chunk_size;
        let mut b = first;
        while b <= last {
            if self.chunks[slot].present[b] {
                b += 1;
                continue;
            }
            let run_start = b;
            while b <= last && !self.chunks[slot].present[b] {
                b += 1;
            }
            let c = &mut self.chunks[slot];
            self.dev.read_at(
                base + (run_start * block) as u64,
                &mut c.data[run_start * block..b * block],
            )?;
            c.present[run_start..b].iter_mut().for_each(|p| *p = true);
        }
        Ok(())
    }

    fn flush_chunk(&mut self, slot: usize) -> io::Result<()> {
        let block = self.block as usize;
        let base = self.start + self.chunks[slot].index * self.chunk_size;
        let c = &mut self.chunks[slot];
        let blocks = c.dirty.len();
        let mut b = 0;
        while b < blocks {
            if !c.dirty[b] {
                b += 1;
                continue;
            }
            let run_start = b;
            while b < blocks && c.dirty[b] {
                b += 1;
            }
            self.dev.write_at(
                base + (run_start * block) as u64,
                &c.data[run_start * block..b * block],
            )?;
            c.dirty[run_start..b].iter_mut().for_each(|d| *d = false);
        }
        Ok(())
    }

    /// Write every dirty block to the device (does not issue a cache sync).
    pub fn flush_all(&mut self) -> io::Result<()> {
        let mut order: Vec<usize> = (0..self.chunks.len()).collect();
        order.sort_by_key(|&i| self.chunks[i].index);
        for i in order {
            self.flush_chunk(i)?;
        }
        Ok(())
    }

    /// Drop all cached data (after flushing) so later reads hit the device.
    pub fn invalidate(&mut self) -> io::Result<()> {
        self.flush_all()?;
        self.chunks.clear();
        Ok(())
    }
}

impl Read for RegionIo<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.pos >= self.len || buf.is_empty() {
            return Ok(0);
        }
        let index = self.pos / self.chunk_size;
        let off = (self.pos % self.chunk_size) as usize;
        let slot = self.chunk_slot(index)?;
        let avail = self.chunks[slot].len - off;
        let n = avail.min(buf.len());
        let block = self.block as usize;
        self.fill(slot, off / block, (off + n - 1) / block)?;
        buf[..n].copy_from_slice(&self.chunks[slot].data[off..off + n]);
        self.pos += n as u64;
        Ok(n)
    }
}

impl Write for RegionIo<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.check_cancel()?;
        if buf.is_empty() {
            return Ok(0);
        }
        if self.pos >= self.len {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "write past end of region",
            ));
        }
        let index = self.pos / self.chunk_size;
        let off = (self.pos % self.chunk_size) as usize;
        let slot = self.chunk_slot(index)?;
        let n = (self.chunks[slot].len - off).min(buf.len());
        let block = self.block as usize;
        let first = off / block;
        let last = (off + n - 1) / block;
        // Only blocks that are partially overwritten need their old content.
        if !off.is_multiple_of(block) {
            self.fill(slot, first, first)?;
        }
        if !(off + n).is_multiple_of(block) {
            self.fill(slot, last, last)?;
        }
        let c = &mut self.chunks[slot];
        c.data[off..off + n].copy_from_slice(&buf[..n]);
        for b in first..=last {
            c.present[b] = true;
            c.dirty[b] = true;
        }
        self.pos += n as u64;
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.flush_all()
    }
}

impl Seek for RegionIo<'_> {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let new = match pos {
            SeekFrom::Start(p) => Some(p),
            SeekFrom::End(d) => self.len.checked_add_signed(d),
            SeekFrom::Current(d) => self.pos.checked_add_signed(d),
        };
        match new {
            Some(p) if p <= self.len => {
                self.pos = p;
                Ok(p)
            }
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "seek out of region",
            )),
        }
    }
}

impl Drop for RegionIo<'_> {
    fn drop(&mut self) {
        // Best effort: callers are expected to flush explicitly and handle errors.
        let _ = self.flush_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device::FileDevice;

    #[test]
    fn unaligned_writes_preserve_neighbouring_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let dev = FileDevice::create(&dir.path().join("r.img"), 4 << 20, 512).unwrap();
        dev.write_at(0, &vec![0x11; 4 << 20]).unwrap();
        {
            let mut io = RegionIo::new(&dev, 1 << 20, 2 << 20).unwrap();
            io.seek(SeekFrom::Start(1000)).unwrap();
            io.write_all(&[0x22; 3000]).unwrap();
            // Cross a chunk boundary.
            io.seek(SeekFrom::Start((1 << 20) - 10)).unwrap();
            io.write_all(&[0x33; 20]).unwrap();
            io.flush().unwrap();
        }
        let mut all = vec![0u8; 4 << 20];
        dev.read_at(0, &mut all).unwrap();
        let base = 1 << 20;
        assert!(all[..base + 1000].iter().all(|&b| b == 0x11));
        assert!(all[base + 1000..base + 4000].iter().all(|&b| b == 0x22));
        assert!(
            all[base + 4000..base + (1 << 20) - 10]
                .iter()
                .all(|&b| b == 0x11)
        );
        assert!(
            all[base + (1 << 20) - 10..base + (1 << 20) + 10]
                .iter()
                .all(|&b| b == 0x33)
        );
        assert!(all[base + (1 << 20) + 10..].iter().all(|&b| b == 0x11));
    }

    #[test]
    fn eviction_flushes_dirty_chunks() {
        let dir = tempfile::tempdir().unwrap();
        let dev = FileDevice::create(&dir.path().join("e.img"), 64 << 20, 4096).unwrap();
        let mut io = RegionIo::new(&dev, 0, 64 << 20).unwrap();
        for i in 0..64u64 {
            io.seek(SeekFrom::Start(i << 20)).unwrap();
            io.write_all(&[i as u8 + 1; 7]).unwrap();
        }
        io.invalidate().unwrap();
        let mut b = [0u8; 4096];
        for i in 0..64u64 {
            dev.read_at(i << 20, &mut b).unwrap();
            assert_eq!(&b[..7], &[i as u8 + 1; 7]);
            assert_eq!(b[7], 0);
        }
    }

    #[test]
    fn cancelled_write_reports_cancelled_io() {
        let dir = tempfile::tempdir().unwrap();
        let dev = FileDevice::create(&dir.path().join("c.img"), 1 << 20, 512).unwrap();
        let tok = CancelToken::new();
        let mut io = RegionIo::new(&dev, 0, 1 << 20)
            .unwrap()
            .with_cancel(tok.clone());
        tok.cancel();
        let err = io.write(&[1, 2, 3]).unwrap_err();
        assert!(matches!(
            crate::error::EngineError::io("x", err),
            crate::error::EngineError::Cancelled
        ));
    }
}
