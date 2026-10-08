//! Typed errors shared by every engine module and exported through the FFI.

use std::io;

/// Stable numeric error codes. These values are part of the FFI contract
/// (`IRUFUS_ERR_*` in `include/irufus.h`) and must never be renumbered.
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub enum ErrorCode {
    Ok = 0,
    Io = 1,
    Cancelled = 2,
    InvalidArgument = 3,
    UnsupportedImage = 4,
    CorruptImage = 5,
    InsufficientSpace = 6,
    DeviceMismatch = 7,
    DeviceGone = 8,
    VerifyFailed = 9,
    FileTooLarge = 10,
    Unsupported = 11,
    BadBlocksFound = 12,
    Internal = 99,
}

#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("I/O error during {context}: {source}")]
    Io {
        context: String,
        #[source]
        source: io::Error,
    },
    #[error("operation cancelled by the user")]
    Cancelled,
    #[error("invalid argument: {0}")]
    InvalidArgument(String),
    #[error("unsupported image: {0}")]
    UnsupportedImage(String),
    #[error("corrupt or truncated image: {0}")]
    CorruptImage(String),
    #[error("insufficient space: need {needed} bytes, device has {available} bytes")]
    InsufficientSpace { needed: u64, available: u64 },
    #[error("device does not match the selected disk: {0}")]
    DeviceMismatch(String),
    #[error("the device was disconnected or stopped responding: {0}")]
    DeviceGone(String),
    #[error("verification failed: {0}")]
    VerifyFailed(String),
    #[error("file '{path}' is {size} bytes, larger than the FAT32 limit of 4 GiB - 1")]
    FileTooLarge { path: String, size: u64 },
    #[error("not supported: {0}")]
    Unsupported(String),
    #[error("{0} bad block(s) found")]
    BadBlocksFound(u64),
    #[error("internal error: {0}")]
    Internal(String),
}

impl EngineError {
    pub fn code(&self) -> ErrorCode {
        match self {
            EngineError::Io { .. } => ErrorCode::Io,
            EngineError::Cancelled => ErrorCode::Cancelled,
            EngineError::InvalidArgument(_) => ErrorCode::InvalidArgument,
            EngineError::UnsupportedImage(_) => ErrorCode::UnsupportedImage,
            EngineError::CorruptImage(_) => ErrorCode::CorruptImage,
            EngineError::InsufficientSpace { .. } => ErrorCode::InsufficientSpace,
            EngineError::DeviceMismatch(_) => ErrorCode::DeviceMismatch,
            EngineError::DeviceGone(_) => ErrorCode::DeviceGone,
            EngineError::VerifyFailed(_) => ErrorCode::VerifyFailed,
            EngineError::FileTooLarge { .. } => ErrorCode::FileTooLarge,
            EngineError::Unsupported(_) => ErrorCode::Unsupported,
            EngineError::BadBlocksFound(_) => ErrorCode::BadBlocksFound,
            EngineError::Internal(_) => ErrorCode::Internal,
        }
    }

    /// Wrap an `io::Error`, mapping errno values that mean "the device went away"
    /// (ENXIO, ENODEV, EIO on a removed USB stick) to `DeviceGone`.
    pub fn io(context: impl Into<String>, source: io::Error) -> Self {
        let context = context.into();
        if let Some(errno) = source.raw_os_error()
            && (errno == libc::ENXIO || errno == libc::ENODEV)
        {
            return EngineError::DeviceGone(format!("{context}: {source}"));
        }
        if source
            .get_ref()
            .is_some_and(|inner| inner.is::<CancelledIo>())
        {
            return EngineError::Cancelled;
        }
        EngineError::Io { context, source }
    }
}

/// Marker carried inside an `io::Error` when a cancellation is detected below an
/// `io::Read`/`io::Write` boundary (e.g. inside the FAT driver).
#[derive(Debug)]
pub struct CancelledIo;

impl std::fmt::Display for CancelledIo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("cancelled")
    }
}
impl std::error::Error for CancelledIo {}

impl CancelledIo {
    pub fn io_error() -> io::Error {
        io::Error::new(io::ErrorKind::Interrupted, CancelledIo)
    }
}

pub type Result<T> = std::result::Result<T, EngineError>;

/// Helper to attach a context string to `io::Result`s.
pub trait IoContext<T> {
    fn ctx(self, context: impl Into<String>) -> Result<T>;
}

impl<T> IoContext<T> for io::Result<T> {
    fn ctx(self, context: impl Into<String>) -> Result<T> {
        self.map_err(|e| EngineError::io(context, e))
    }
}
