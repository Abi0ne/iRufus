//! C ABI used by the Swift application. The contract is documented in
//! `include/irufus.h`; keep both in sync and bump `IRUFUS_ABI_VERSION` on any
//! incompatible change.
//!
//! Conventions:
//! - strings are UTF-8, NUL-terminated; strings returned by the engine must be
//!   released with `irufus_string_free`;
//! - structured data crosses the boundary as versioned JSON (`schemaVersion`);
//! - every fallible call takes an `IrufusError*` filled on failure, with a
//!   stable numeric `code` (`ErrorCode`) and an English diagnostic message;
//! - panics never unwind into Swift: they are reported as `IRUFUS_ERR_INTERNAL`.

use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;

use serde::Deserialize;

use crate::device::{BlockDevice, FdDevice};
use crate::error::{EngineError, ErrorCode, Result};
use crate::hash;
use crate::image::{self, WriteMode, source};
use crate::ops::{badblocks, dd, extract, save};
use crate::partition::Scheme;
use crate::progress::{CancelToken, OpContext, ProgressSink, ProgressUpdate};
use crate::wue::{self, WueOptions};

pub const IRUFUS_ABI_VERSION: u32 = 1;

#[repr(C)]
pub struct IrufusError {
    pub code: u32,
    pub message: *mut c_char,
}

pub type ProgressFn = Option<
    unsafe extern "C" fn(ctx: *mut c_void, phase: u32, done: u64, total: u64, bytes_per_sec: f64),
>;
pub type LogFn = Option<unsafe extern "C" fn(ctx: *mut c_void, message: *const c_char)>;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct IrufusCallbacks {
    pub ctx: *mut c_void,
    pub progress: ProgressFn,
    pub log: LogFn,
}

pub struct IrufusCancel(CancelToken);
pub struct IrufusDevice(Box<dyn BlockDevice>);

struct CallbackSink(IrufusCallbacks);
// The Swift side guarantees its context is usable from the calling thread.
unsafe impl Send for CallbackSink {}
unsafe impl Sync for CallbackSink {}

impl ProgressSink for CallbackSink {
    fn update(&self, u: ProgressUpdate) {
        if let Some(f) = self.0.progress {
            unsafe { f(self.0.ctx, u.phase as u32, u.done, u.total, u.bytes_per_sec) };
        }
    }
    fn log(&self, message: &str) {
        if let Some(f) = self.0.log {
            let c = CString::new(message.replace('\0', " ")).unwrap_or_default();
            unsafe { f(self.0.ctx, c.as_ptr()) };
        }
    }
}

fn to_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', " "))
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

unsafe fn set_error(err: *mut IrufusError, code: ErrorCode, message: String) {
    if !err.is_null() {
        unsafe {
            (*err).code = code as u32;
            (*err).message = to_c(message);
        }
    }
}

unsafe fn str_arg<'a>(p: *const c_char, what: &str) -> Result<&'a str> {
    if p.is_null() {
        return Err(EngineError::InvalidArgument(format!("{what} is NULL")));
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map_err(|_| EngineError::InvalidArgument(format!("{what} is not UTF-8")))
}

/// Run `f`, converting errors and panics into an `IrufusError` and a NULL result.
unsafe fn guard(err: *mut IrufusError, f: impl FnOnce() -> Result<String>) -> *mut c_char {
    if !err.is_null() {
        unsafe {
            (*err).code = 0;
            (*err).message = std::ptr::null_mut();
        }
    }
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(s)) => to_c(s),
        Ok(Err(e)) => {
            unsafe { set_error(err, e.code(), e.to_string()) };
            std::ptr::null_mut()
        }
        Err(panic) => {
            let msg = panic
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| panic.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "panic".into());
            unsafe { set_error(err, ErrorCode::Internal, format!("internal error: {msg}")) };
            std::ptr::null_mut()
        }
    }
}

fn json<T: serde::Serialize>(v: &T) -> Result<String> {
    serde_json::to_string(v).map_err(|e| EngineError::Internal(format!("JSON encoding: {e}")))
}

fn cancel_of(c: *const IrufusCancel) -> CancelToken {
    if c.is_null() {
        CancelToken::new()
    } else {
        unsafe { (*c).0.clone() }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn irufus_abi_version() -> u32 {
    IRUFUS_ABI_VERSION
}

#[unsafe(no_mangle)]
pub extern "C" fn irufus_engine_version() -> *mut c_char {
    to_c(env!("CARGO_PKG_VERSION").to_string())
}

/// # Safety
/// `s` must be NULL or a string previously returned by this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn irufus_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn irufus_cancel_new() -> *mut IrufusCancel {
    Box::into_raw(Box::new(IrufusCancel(CancelToken::new())))
}

/// # Safety
/// `c` must be a live pointer from `irufus_cancel_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn irufus_cancel_trigger(c: *const IrufusCancel) {
    if !c.is_null() {
        unsafe { (*c).0.cancel() };
    }
}

/// # Safety
/// `c` must be NULL or a pointer from `irufus_cancel_new`, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn irufus_cancel_free(c: *mut IrufusCancel) {
    if !c.is_null() {
        drop(unsafe { Box::from_raw(c) });
    }
}

/// Analyse an image. Returns `ImageReport` JSON.
///
/// # Safety
/// Pointers must be valid; `err` may be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn irufus_analyze(path: *const c_char, err: *mut IrufusError) -> *mut c_char {
    unsafe {
        guard(err, || {
            let p = str_arg(path, "path")?;
            json(&image::analyze(&PathBuf::from(p))?)
        })
    }
}

/// Hash the image file itself (as downloaded). `mask` is a bitwise OR of
/// 1 = MD5, 2 = SHA-1, 4 = SHA-256, 8 = SHA-512 (0 = SHA-256). Returns `HashResult` JSON.
///
/// # Safety
/// Pointers must be valid; `cancel` and `err` may be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn irufus_hash_file(
    path: *const c_char,
    mask: u32,
    cb: IrufusCallbacks,
    cancel: *const IrufusCancel,
    err: *mut IrufusError,
) -> *mut c_char {
    unsafe {
        guard(err, || {
            let p = PathBuf::from(str_arg(path, "path")?);
            let sink = CallbackSink(cb);
            let ctx = OpContext::new(&sink, cancel_of(cancel));
            let mut f = std::fs::File::open(&p)
                .map_err(|e| EngineError::io(format!("opening {}", p.display()), e))?;
            let total = f.metadata().map(|m| m.len()).unwrap_or(0);
            let (r, _) = hash::hash_reader(&mut f, mask, total, &ctx)?;
            json(&r)
        })
    }
}

/// Parse a checksum typed or pasted by the user. Returns `{"digest":..,"algorithm":..}` JSON.
///
/// # Safety
/// Pointers must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn irufus_parse_checksum(
    input: *const c_char,
    err: *mut IrufusError,
) -> *mut c_char {
    unsafe {
        guard(err, || {
            let s = str_arg(input, "input")?;
            let (digest, algo) = hash::parse_expected(s).ok_or_else(|| {
                EngineError::InvalidArgument("no MD5/SHA-1/SHA-256/SHA-512 digest found".into())
            })?;
            json(&serde_json::json!({ "digest": digest, "algorithm": algo }))
        })
    }
}

/// Take ownership of a raw-disk descriptor obtained by the privileged broker.
/// Geometry must match `expected_size`/`expected_block_size` exactly.
///
/// # Safety
/// `fd` must be an open descriptor that the caller relinquishes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn irufus_device_from_fd(
    fd: i32,
    expected_size: u64,
    expected_block_size: u32,
    err: *mut IrufusError,
) -> *mut IrufusDevice {
    if !err.is_null() {
        unsafe {
            (*err).code = 0;
            (*err).message = std::ptr::null_mut();
        }
    }
    if expected_size == 0 || expected_block_size == 0 {
        unsafe {
            if fd >= 0 {
                libc::close(fd);
            }
            set_error(
                err,
                ErrorCode::InvalidArgument,
                "expected geometry is required".into(),
            );
        }
        return std::ptr::null_mut();
    }
    match catch_unwind(|| unsafe { FdDevice::from_raw_fd(fd, expected_size, expected_block_size) })
    {
        Ok(Ok(d)) => Box::into_raw(Box::new(IrufusDevice(Box::new(d)))),
        Ok(Err(e)) => {
            unsafe { set_error(err, e.code(), e.to_string()) };
            std::ptr::null_mut()
        }
        Err(_) => {
            unsafe {
                set_error(
                    err,
                    ErrorCode::Internal,
                    "internal error opening device".into(),
                )
            };
            std::ptr::null_mut()
        }
    }
}

/// # Safety
/// `d` must be NULL or a pointer returned by `irufus_device_from_fd`, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn irufus_device_close(d: *mut IrufusDevice) {
    if !d.is_null() {
        drop(unsafe { Box::from_raw(d) });
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WriteRequest {
    mode: WriteMode,
    #[serde(default = "default_true")]
    verify: bool,
    #[serde(default)]
    scheme: Option<Scheme>,
    #[serde(default)]
    cluster_size: Option<u32>,
    #[serde(default)]
    label: Option<String>,
    #[serde(default)]
    wue: Option<WueOptions>,
}

fn default_true() -> bool {
    true
}

fn device<'a>(d: *mut IrufusDevice) -> Result<&'a dyn BlockDevice> {
    if d.is_null() {
        return Err(EngineError::InvalidArgument("device is NULL".into()));
    }
    Ok(unsafe { &*(*d).0 })
}

/// Write an image to the device. `request_json` is a `WriteRequest`.
/// Returns `DdSummary` or `ExtractSummary` JSON.
///
/// # Safety
/// Pointers must be valid; `cancel` and `err` may be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn irufus_write_image(
    dev: *mut IrufusDevice,
    image_path: *const c_char,
    request_json: *const c_char,
    cb: IrufusCallbacks,
    cancel: *const IrufusCancel,
    err: *mut IrufusError,
) -> *mut c_char {
    unsafe {
        guard(err, || {
            let d = device(dev)?;
            let path = PathBuf::from(str_arg(image_path, "image path")?);
            let req: WriteRequest = serde_json::from_str(str_arg(request_json, "request")?)
                .map_err(|e| EngineError::InvalidArgument(format!("write request: {e}")))?;
            let sink = CallbackSink(cb);
            let ctx = OpContext::new(&sink, cancel_of(cancel));
            match req.mode {
                WriteMode::Dd => {
                    let info = source::probe(&path)?;
                    json(&dd::write_dd(&path, &info, d, req.verify, &ctx)?)
                }
                WriteMode::IsoExtract => {
                    let opts = extract::ExtractOptions {
                        scheme: req.scheme.ok_or_else(|| {
                            EngineError::InvalidArgument("partition scheme is required".into())
                        })?,
                        cluster_size: req.cluster_size,
                        label: req.label,
                        wue: req.wue,
                        verify: req.verify,
                    };
                    json(&extract::write_iso_extract(&path, d, &opts, &ctx)?)
                }
            }
        })
    }
}

/// Overwrite the whole device with zeros. Returns `{}`.
///
/// # Safety
/// Pointers must be valid; `cancel` and `err` may be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn irufus_zero_device(
    dev: *mut IrufusDevice,
    verify: bool,
    cb: IrufusCallbacks,
    cancel: *const IrufusCancel,
    err: *mut IrufusError,
) -> *mut c_char {
    unsafe {
        guard(err, || {
            let sink = CallbackSink(cb);
            let ctx = OpContext::new(&sink, cancel_of(cancel));
            dd::zero_device(device(dev)?, verify, &ctx)?;
            Ok("{}".into())
        })
    }
}

/// Destructive bad-block test (1–4 passes). Returns `BadBlocksReport` JSON.
///
/// # Safety
/// Pointers must be valid; `cancel` and `err` may be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn irufus_bad_blocks(
    dev: *mut IrufusDevice,
    passes: u32,
    cb: IrufusCallbacks,
    cancel: *const IrufusCancel,
    err: *mut IrufusError,
) -> *mut c_char {
    unsafe {
        guard(err, || {
            let sink = CallbackSink(cb);
            let ctx = OpContext::new(&sink, cancel_of(cancel));
            json(&badblocks::run(device(dev)?, passes, &ctx)?)
        })
    }
}

/// Save the device to `out_path`. `format`: 0 = raw, 1 = fixed VHD. Returns `SaveSummary` JSON.
///
/// # Safety
/// Pointers must be valid; `cancel` and `err` may be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn irufus_save_device(
    dev: *mut IrufusDevice,
    out_path: *const c_char,
    format: u32,
    cb: IrufusCallbacks,
    cancel: *const IrufusCancel,
    err: *mut IrufusError,
) -> *mut c_char {
    unsafe {
        guard(err, || {
            let fmt = match format {
                0 => save::SaveFormat::Raw,
                1 => save::SaveFormat::VhdFixed,
                _ => return Err(EngineError::InvalidArgument("unknown image format".into())),
            };
            let sink = CallbackSink(cb);
            let ctx = OpContext::new(&sink, cancel_of(cancel));
            json(&save::save_device(
                device(dev)?,
                &PathBuf::from(str_arg(out_path, "output path")?),
                fmt,
                &ctx,
            )?)
        })
    }
}

/// FAT32 cluster sizes valid for a device (ISO mode, single partition).
/// Returns `{"default": n, "valid": [..], "partitionBytes": n}` JSON.
///
/// # Safety
/// `err` may be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn irufus_fat32_options(
    device_bytes: u64,
    block_size: u32,
    scheme: u32,
    err: *mut IrufusError,
) -> *mut c_char {
    unsafe {
        guard(err, || {
            let scheme = if scheme == 0 {
                Scheme::Mbr
            } else {
                Scheme::Gpt
            };
            let plan =
                crate::partition::SinglePartitionPlan::new(scheme, device_bytes, block_size)?;
            let valid = crate::fat32::valid_cluster_sizes(plan.len, block_size);
            let default = crate::fat32::default_cluster_size(plan.len).max(block_size);
            json(
                &serde_json::json!({ "default": default, "valid": valid, "partitionBytes": plan.len }),
            )
        })
    }
}

/// Validate Windows options and return the answer file that would be written,
/// plus its path on the media: `{"path": .., "xml": ..}` (or `{}` if empty).
///
/// # Safety
/// Pointers must be valid; `err` may be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn irufus_wue_preview(
    options_json: *const c_char,
    err: *mut IrufusError,
) -> *mut c_char {
    unsafe {
        guard(err, || {
            let opts: WueOptions = serde_json::from_str(str_arg(options_json, "options")?)
                .map_err(|e| EngineError::InvalidArgument(format!("WUE options: {e}")))?;
            match wue::build_unattend(&opts)? {
                Some(xml) => json(&serde_json::json!({ "path": opts.target_path(), "xml": xml })),
                None => Ok("{}".into()),
            }
        })
    }
}

/// Sanitise a local account name; error if reserved/empty.
///
/// # Safety
/// Pointers must be valid; `err` may be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn irufus_sanitize_account_name(
    name: *const c_char,
    err: *mut IrufusError,
) -> *mut c_char {
    unsafe { guard(err, || wue::sanitize_account_name(str_arg(name, "name")?)) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(
        f: impl FnOnce(*mut IrufusError) -> *mut c_char,
    ) -> std::result::Result<String, (u32, String)> {
        let mut e = IrufusError {
            code: 0,
            message: std::ptr::null_mut(),
        };
        let r = f(&mut e);
        if r.is_null() {
            let msg = unsafe { CStr::from_ptr(e.message) }
                .to_string_lossy()
                .to_string();
            unsafe { irufus_string_free(e.message) };
            return Err((e.code, msg));
        }
        let s = unsafe { CStr::from_ptr(r) }.to_string_lossy().to_string();
        unsafe { irufus_string_free(r) };
        Ok(s)
    }

    #[test]
    fn analyze_errors_are_typed() {
        let p = CString::new("/nonexistent/x.iso").unwrap();
        let (code, _) = call(|e| unsafe { irufus_analyze(p.as_ptr(), e) }).unwrap_err();
        assert_eq!(code, ErrorCode::Io as u32);
        let (code, _) = call(|e| unsafe { irufus_analyze(std::ptr::null(), e) }).unwrap_err();
        assert_eq!(code, ErrorCode::InvalidArgument as u32);
    }

    #[test]
    fn analyze_returns_versioned_json() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("a.img");
        let mut d = vec![0u8; 4096];
        d[510] = 0x55;
        d[511] = 0xAA;
        std::fs::write(&p, d).unwrap();
        let cp = CString::new(p.to_str().unwrap()).unwrap();
        let s = call(|e| unsafe { irufus_analyze(cp.as_ptr(), e) }).unwrap();
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["schemaVersion"], 1);
        assert_eq!(v["kind"], "diskImage");
        assert_eq!(v["modes"][0], "dd");
        assert_eq!(v["source"]["container"]["kind"], "raw");
    }

    #[test]
    fn device_from_bad_fd_reports_error_and_closes() {
        let (code, _) = {
            let mut e = IrufusError {
                code: 0,
                message: std::ptr::null_mut(),
            };
            let d = unsafe { irufus_device_from_fd(-1, 512, 512, &mut e) };
            assert!(d.is_null());
            let msg = unsafe { CStr::from_ptr(e.message) }
                .to_string_lossy()
                .to_string();
            unsafe { irufus_string_free(e.message) };
            (e.code, msg)
        };
        assert_eq!(code, ErrorCode::InvalidArgument as u32);
    }

    #[test]
    fn write_through_ffi_with_callbacks_and_cancel() {
        use std::sync::atomic::{AtomicU64, Ordering};
        let dir = tempfile::tempdir().unwrap();
        let img = dir.path().join("i.img");
        std::fs::write(&img, vec![0xA5u8; 3 << 20]).unwrap();
        let devp = dir.path().join("dev.img");
        crate::device::FileDevice::create(&devp, 8 << 20, 512).unwrap();
        let fd = std::os::fd::IntoRawFd::into_raw_fd(
            std::fs::File::options()
                .read(true)
                .write(true)
                .open(&devp)
                .unwrap(),
        );
        let mut e = IrufusError {
            code: 0,
            message: std::ptr::null_mut(),
        };
        let dev = unsafe { irufus_device_from_fd(fd, 8 << 20, 512, &mut e) };
        assert!(!dev.is_null());

        static PROGRESS: AtomicU64 = AtomicU64::new(0);
        unsafe extern "C" fn on_progress(_: *mut c_void, _: u32, done: u64, _: u64, _: f64) {
            PROGRESS.fetch_max(done, Ordering::SeqCst);
        }
        let cb = IrufusCallbacks {
            ctx: std::ptr::null_mut(),
            progress: Some(on_progress),
            log: None,
        };
        let ip = CString::new(img.to_str().unwrap()).unwrap();
        let req = CString::new(r#"{"mode":"dd","verify":true}"#).unwrap();
        let s = call(|e| unsafe {
            irufus_write_image(dev, ip.as_ptr(), req.as_ptr(), cb, std::ptr::null(), e)
        })
        .unwrap();
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["bytesWritten"], 3 << 20);
        assert_eq!(v["verified"], true);
        assert_eq!(PROGRESS.load(Ordering::SeqCst), 3 << 20);

        let c = irufus_cancel_new();
        unsafe { irufus_cancel_trigger(c) };
        let (code, _) =
            call(|e| unsafe { irufus_write_image(dev, ip.as_ptr(), req.as_ptr(), cb, c, e) })
                .unwrap_err();
        assert_eq!(code, ErrorCode::Cancelled as u32);
        let bad = CString::new(r#"{"mode":"isoExtract"}"#).unwrap();
        let (code, _) = call(|e| unsafe {
            irufus_write_image(dev, ip.as_ptr(), bad.as_ptr(), cb, std::ptr::null(), e)
        })
        .unwrap_err();
        assert_eq!(code, ErrorCode::InvalidArgument as u32);
        unsafe {
            irufus_cancel_free(c);
            irufus_device_close(dev);
        }
    }

    #[test]
    fn wue_preview_and_checksum_parsing() {
        let o = CString::new(r#"{"arch":"amd64","noOnlineAccount":true}"#).unwrap();
        let s = call(|e| unsafe { irufus_wue_preview(o.as_ptr(), e) }).unwrap();
        assert!(s.contains("BypassNRO") && s.contains("$OEM$"));
        let c =
            CString::new("sha256:E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855")
                .unwrap();
        let s = call(|e| unsafe { irufus_parse_checksum(c.as_ptr(), e) }).unwrap();
        assert!(s.contains("\"algorithm\":\"sha256\""), "{s}");
        let n = CString::new("guest").unwrap();
        assert!(call(|e| unsafe { irufus_sanitize_account_name(n.as_ptr(), e) }).is_err());
    }
}
