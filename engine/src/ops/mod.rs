//! Long-running operations on a device. Each takes an `OpContext` for progress,
//! logging and cancellation, and never touches a device it was not given.

pub mod badblocks;
pub mod dd;
pub mod extract;
pub mod save;
