//! iRufus engine: image analysis, partitioning, FAT32 creation, raw writing,
//! verification and related storage operations. The Swift GUI drives it
//! through the C ABI in `ffi.rs` (header: `include/irufus.h`).

pub mod device;
pub mod error;
pub mod fat32;
pub mod ffi;
pub mod hash;
pub mod image;
pub mod ops;
pub mod partition;
pub mod progress;
pub mod regionio;
pub mod wim;
pub mod wue;
