//! Block devices: raw disks opened through a privileged file descriptor, and
//! regular files used as disk images (tests, "save to image", virtual disks).
//!
//! All I/O goes through `read_at`/`write_at` with offsets and lengths that are
//! multiples of the device block size: macOS raw devices (`/dev/rdiskN`) reject
//! anything else with `EINVAL`.

use std::alloc::{Layout, alloc_zeroed, dealloc};
use std::fs::File;
use std::io;
use std::ops::{Deref, DerefMut};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::FileExt;
use std::path::Path;

use crate::error::{EngineError, IoContext, Result};

pub trait BlockDevice: Send {
    /// Total size in bytes (always a multiple of `block_size`).
    fn size(&self) -> u64;
    /// Logical block size in bytes (512 or 4096 in practice).
    fn block_size(&self) -> u32;
    fn read_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()>;
    fn write_at(&self, offset: u64, buf: &[u8]) -> io::Result<()>;
    /// Flush device caches to stable storage.
    fn sync(&self) -> io::Result<()>;
}

fn check_aligned(dev: &dyn BlockDevice, offset: u64, len: usize) -> io::Result<()> {
    let bs = dev.block_size() as u64;
    if !offset.is_multiple_of(bs) || !(len as u64).is_multiple_of(bs) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("unaligned device I/O: offset {offset}, length {len}, block size {bs}"),
        ));
    }
    let end = offset
        .checked_add(len as u64)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "offset overflow"))?;
    if end > dev.size() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("I/O past end of device: {end} > {}", dev.size()),
        ));
    }
    Ok(())
}

/// A regular file treated as a disk. The size is fixed at creation.
pub struct FileDevice {
    file: File,
    size: u64,
    block_size: u32,
}

impl FileDevice {
    /// Open an existing image file. Its size is rounded down to the block size.
    pub fn open(path: &Path, writable: bool, block_size: u32) -> Result<Self> {
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(writable)
            .open(path)
            .ctx(format!("opening {}", path.display()))?;
        let len = file.metadata().ctx("reading image size")?.len();
        Ok(Self {
            file,
            size: len - len % block_size as u64,
            block_size,
        })
    }

    /// Create (or truncate) a sparse image file of exactly `size` bytes.
    pub fn create(path: &Path, size: u64, block_size: u32) -> Result<Self> {
        if !size.is_multiple_of(block_size as u64) {
            return Err(EngineError::InvalidArgument(
                "image size must be a multiple of the block size".into(),
            ));
        }
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)
            .ctx(format!("creating {}", path.display()))?;
        file.set_len(size).ctx("sizing image")?;
        Ok(Self {
            file,
            size,
            block_size,
        })
    }
}

impl BlockDevice for FileDevice {
    fn size(&self) -> u64 {
        self.size
    }
    fn block_size(&self) -> u32 {
        self.block_size
    }
    fn read_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()> {
        check_aligned(self, offset, buf.len())?;
        self.file.read_exact_at(buf, offset)
    }
    fn write_at(&self, offset: u64, buf: &[u8]) -> io::Result<()> {
        check_aligned(self, offset, buf.len())?;
        self.file.write_all_at(buf, offset)
    }
    fn sync(&self) -> io::Result<()> {
        self.file.sync_all()
    }
}

// <sys/disk.h> ioctls: _IOR('d', 24, uint32_t), _IOR('d', 25, uint64_t), _IO('d', 22)
const DKIOCGETBLOCKSIZE: libc::c_ulong = 0x4004_6418;
const DKIOCGETBLOCKCOUNT: libc::c_ulong = 0x4008_6419;
const DKIOCSYNCHRONIZECACHE: libc::c_ulong = 0x2000_6416;

/// A raw disk device, opened by the privileged broker and handed to the engine
/// as a file descriptor. The engine takes ownership of the descriptor.
pub struct FdDevice {
    fd: OwnedFd,
    size: u64,
    block_size: u32,
    is_char_device: bool,
}

impl FdDevice {
    /// Take ownership of `fd` and query geometry. When `expected_size` /
    /// `expected_block_size` are non-zero they must match exactly, so that a
    /// descriptor for a different disk can never be written to.
    ///
    /// # Safety
    /// `fd` must be an open descriptor owned by the caller and not used afterwards.
    pub unsafe fn from_raw_fd(
        fd: RawFd,
        expected_size: u64,
        expected_block_size: u32,
    ) -> Result<Self> {
        if fd < 0 {
            return Err(EngineError::InvalidArgument(format!(
                "invalid file descriptor {fd}"
            )));
        }
        let fd = unsafe { OwnedFd::from_raw_fd(fd) };
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstat(fd.as_raw_fd(), &mut st) } != 0 {
            return Err(EngineError::io("device fstat", io::Error::last_os_error()));
        }
        let fmt = st.st_mode & libc::S_IFMT;
        let is_char_device = fmt == libc::S_IFCHR;
        let (size, block_size) = if is_char_device || fmt == libc::S_IFBLK {
            let mut bs: u32 = 0;
            let mut count: u64 = 0;
            unsafe {
                if libc::ioctl(fd.as_raw_fd(), DKIOCGETBLOCKSIZE, &mut bs) != 0 {
                    return Err(EngineError::io(
                        "device block size query",
                        io::Error::last_os_error(),
                    ));
                }
                if libc::ioctl(fd.as_raw_fd(), DKIOCGETBLOCKCOUNT, &mut count) != 0 {
                    return Err(EngineError::io(
                        "device block count query",
                        io::Error::last_os_error(),
                    ));
                }
            }
            let size = count
                .checked_mul(bs as u64)
                .ok_or_else(|| EngineError::Internal("device size overflow".into()))?;
            (size, bs)
        } else if fmt == libc::S_IFREG {
            let bs = if expected_block_size != 0 {
                expected_block_size
            } else {
                512
            };
            (st.st_size as u64 - st.st_size as u64 % bs as u64, bs)
        } else {
            return Err(EngineError::DeviceMismatch(
                "descriptor is not a disk device".into(),
            ));
        };
        if block_size == 0 || !block_size.is_power_of_two() || size == 0 {
            return Err(EngineError::DeviceMismatch(format!(
                "implausible geometry: {size} bytes, block {block_size}"
            )));
        }
        if expected_size != 0 && expected_size != size {
            return Err(EngineError::DeviceMismatch(format!(
                "size is {size} bytes, expected {expected_size}"
            )));
        }
        if expected_block_size != 0 && expected_block_size != block_size {
            return Err(EngineError::DeviceMismatch(format!(
                "block size is {block_size}, expected {expected_block_size}"
            )));
        }
        Ok(Self {
            fd,
            size,
            block_size,
            is_char_device,
        })
    }

    /// `st_rdev` of the descriptor, used by callers to confirm device identity.
    pub fn rdev(&self) -> Option<u64> {
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstat(self.fd.as_raw_fd(), &mut st) } != 0 {
            return None;
        }
        Some(st.st_rdev as u64)
    }
}

impl BlockDevice for FdDevice {
    fn size(&self) -> u64 {
        self.size
    }
    fn block_size(&self) -> u32 {
        self.block_size
    }
    fn read_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()> {
        check_aligned(self, offset, buf.len())?;
        let mut done = 0usize;
        while done < buf.len() {
            let n = unsafe {
                libc::pread(
                    self.fd.as_raw_fd(),
                    buf[done..].as_mut_ptr().cast(),
                    buf.len() - done,
                    (offset + done as u64) as libc::off_t,
                )
            };
            if n < 0 {
                let err = io::Error::last_os_error();
                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(err);
            }
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "short read from device",
                ));
            }
            done += n as usize;
        }
        Ok(())
    }
    fn write_at(&self, offset: u64, buf: &[u8]) -> io::Result<()> {
        check_aligned(self, offset, buf.len())?;
        let mut done = 0usize;
        while done < buf.len() {
            let n = unsafe {
                libc::pwrite(
                    self.fd.as_raw_fd(),
                    buf[done..].as_ptr().cast(),
                    buf.len() - done,
                    (offset + done as u64) as libc::off_t,
                )
            };
            if n < 0 {
                let err = io::Error::last_os_error();
                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(err);
            }
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "device accepted no data",
                ));
            }
            done += n as usize;
        }
        Ok(())
    }
    fn sync(&self) -> io::Result<()> {
        if self.is_char_device {
            if unsafe { libc::ioctl(self.fd.as_raw_fd(), DKIOCSYNCHRONIZECACHE) } != 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        } else if unsafe { libc::fcntl(self.fd.as_raw_fd(), libc::F_FULLFSYNC) } != 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }
}

/// Page-aligned, zero-initialised heap buffer. Raw device I/O is fastest (and on
/// some drivers only possible) with page-aligned buffers.
pub struct AlignedBuf {
    ptr: *mut u8,
    len: usize,
    layout: Layout,
}

unsafe impl Send for AlignedBuf {}

impl AlignedBuf {
    pub const ALIGN: usize = 4096;

    pub fn new(len: usize) -> Self {
        let layout = Layout::from_size_align(len.max(1), Self::ALIGN).expect("valid layout");
        let ptr = unsafe { alloc_zeroed(layout) };
        if ptr.is_null() {
            std::alloc::handle_alloc_error(layout);
        }
        Self { ptr, len, layout }
    }
}

impl Deref for AlignedBuf {
    type Target = [u8];
    fn deref(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }
}

impl DerefMut for AlignedBuf {
    fn deref_mut(&mut self) -> &mut [u8] {
        unsafe { std::slice::from_raw_parts_mut(self.ptr, self.len) }
    }
}

impl Drop for AlignedBuf {
    fn drop(&mut self) {
        unsafe { dealloc(self.ptr, self.layout) }
    }
}

/// Round `v` up to a multiple of `align` (a power of two or any non-zero value).
pub fn align_up(v: u64, align: u64) -> u64 {
    v.div_ceil(align) * align
}

pub fn align_down(v: u64, align: u64) -> u64 {
    v - v % align
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_device_rejects_unaligned_and_out_of_range_io() {
        let dir = tempfile::tempdir().unwrap();
        let dev = FileDevice::create(&dir.path().join("d.img"), 8192, 512).unwrap();
        let mut buf = vec![0u8; 512];
        assert!(dev.read_at(1, &mut buf).is_err());
        assert!(dev.read_at(0, &mut buf[..100]).is_err());
        assert!(dev.read_at(8192, &mut buf).is_err());
        assert!(dev.write_at(u64::MAX - 511, &buf).is_err());
        dev.write_at(7680, &[0xAB; 512]).unwrap();
        dev.read_at(7680, &mut buf).unwrap();
        assert!(buf.iter().all(|&b| b == 0xAB));
    }

    #[test]
    fn fd_device_checks_expected_geometry() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("d.img");
        FileDevice::create(&path, 1 << 20, 512).unwrap();
        let f = File::options().read(true).write(true).open(&path).unwrap();
        let fd = std::os::fd::IntoRawFd::into_raw_fd(f);
        let err = unsafe { FdDevice::from_raw_fd(fd, 999 * 512, 512) }
            .err()
            .unwrap();
        assert!(matches!(err, EngineError::DeviceMismatch(_)));
        let f = File::options().read(true).write(true).open(&path).unwrap();
        let fd = std::os::fd::IntoRawFd::into_raw_fd(f);
        let dev = unsafe { FdDevice::from_raw_fd(fd, 1 << 20, 512) }.unwrap();
        assert_eq!(dev.size(), 1 << 20);
    }

    #[test]
    fn aligned_buf_is_page_aligned() {
        let b = AlignedBuf::new(10000);
        assert_eq!(b.as_ptr() as usize % AlignedBuf::ALIGN, 0);
        assert_eq!(b.len(), 10000);
    }
}
