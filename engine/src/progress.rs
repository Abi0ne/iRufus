//! Progress reporting and cooperative cancellation.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use crate::error::{EngineError, Result};

/// Phases reported to the UI. Values are part of the FFI contract.
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub enum Phase {
    Preparing = 0,
    Hashing = 1,
    Partitioning = 2,
    Formatting = 3,
    Writing = 4,
    CopyingFiles = 5,
    SplittingWim = 6,
    Syncing = 7,
    Verifying = 8,
    BadBlocks = 9,
    Reading = 10,
    Zeroing = 11,
    Finalizing = 12,
}

#[derive(Debug, Clone, Copy)]
pub struct ProgressUpdate {
    pub phase: Phase,
    pub done: u64,
    pub total: u64,
    /// Bytes per second averaged over the current phase.
    pub bytes_per_sec: f64,
}

pub trait ProgressSink: Send + Sync {
    fn update(&self, update: ProgressUpdate);
    fn log(&self, message: &str);
}

/// Sink that discards everything (tests, analysis).
pub struct NullSink;
impl ProgressSink for NullSink {
    fn update(&self, _: ProgressUpdate) {}
    fn log(&self, _: &str) {}
}

#[derive(Clone, Default)]
pub struct CancelToken(Arc<AtomicBool>);

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
    pub fn check(&self) -> Result<()> {
        if self.is_cancelled() {
            Err(EngineError::Cancelled)
        } else {
            Ok(())
        }
    }
}

/// Tracks one phase, throttles updates to ~10 per second.
pub struct PhaseTracker<'a> {
    sink: &'a dyn ProgressSink,
    phase: Phase,
    total: u64,
    done: u64,
    start: Instant,
    last_emit: Instant,
}

impl<'a> PhaseTracker<'a> {
    pub fn new(sink: &'a dyn ProgressSink, phase: Phase, total: u64) -> Self {
        let now = Instant::now();
        let t = Self {
            sink,
            phase,
            total,
            done: 0,
            start: now,
            last_emit: now,
        };
        t.emit();
        t
    }

    pub fn advance(&mut self, n: u64) {
        self.done = self.done.saturating_add(n);
        if self.last_emit.elapsed().as_millis() >= 100 {
            self.last_emit = Instant::now();
            self.emit();
        }
    }

    pub fn set_total(&mut self, total: u64) {
        self.total = total;
    }

    pub fn done(&self) -> u64 {
        self.done
    }

    pub fn finish(mut self) {
        if self.total == 0 {
            self.total = self.done;
        }
        self.done = self.done.max(self.total);
        self.emit();
    }

    fn emit(&self) {
        let secs = self.start.elapsed().as_secs_f64();
        let rate = if secs > 0.2 {
            self.done as f64 / secs
        } else {
            0.0
        };
        self.sink.update(ProgressUpdate {
            phase: self.phase,
            done: self.done,
            total: self.total,
            bytes_per_sec: rate,
        });
    }
}

/// Context passed to every long-running operation.
pub struct OpContext<'a> {
    pub sink: &'a dyn ProgressSink,
    pub cancel: CancelToken,
}

impl<'a> OpContext<'a> {
    pub fn new(sink: &'a dyn ProgressSink, cancel: CancelToken) -> Self {
        Self { sink, cancel }
    }
    pub fn log(&self, msg: impl AsRef<str>) {
        self.sink.log(msg.as_ref());
    }
    pub fn check(&self) -> Result<()> {
        self.cancel.check()
    }
    pub fn phase(&self, phase: Phase, total: u64) -> PhaseTracker<'a> {
        PhaseTracker::new(self.sink, phase, total)
    }
}

#[cfg(test)]
pub mod testing {
    use super::*;
    use std::sync::Mutex;

    #[derive(Default)]
    pub struct RecordingSink {
        pub logs: Mutex<Vec<String>>,
        pub updates: Mutex<Vec<(Phase, u64, u64)>>,
    }
    impl ProgressSink for RecordingSink {
        fn update(&self, u: ProgressUpdate) {
            self.updates
                .lock()
                .unwrap()
                .push((u.phase, u.done, u.total));
        }
        fn log(&self, message: &str) {
            self.logs.lock().unwrap().push(message.to_string());
        }
    }
}
