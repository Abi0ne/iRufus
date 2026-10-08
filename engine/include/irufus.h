/*
 * iRufus engine C ABI — contract between the Swift app and the Rust engine.
 * Keep in sync with engine/src/ffi.rs. ABI version: 1.
 *
 * - Strings are UTF-8 and NUL-terminated. Strings returned by the engine are
 *   owned by the caller and must be released with irufus_string_free().
 * - Structured results are JSON documents (see docs/FFI.md for schemas).
 * - On failure functions return NULL and fill *err (if non-NULL) with a stable
 *   code (IRUFUS_ERR_*) and an English diagnostic message to free with
 *   irufus_string_free().
 * - Long operations call the progress/log callbacks synchronously from the
 *   calling thread; they can be cancelled from any thread via IrufusCancel.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#ifndef IRUFUS_H
#define IRUFUS_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define IRUFUS_ABI_VERSION 1

enum {
    IRUFUS_ERR_OK = 0,
    IRUFUS_ERR_IO = 1,
    IRUFUS_ERR_CANCELLED = 2,
    IRUFUS_ERR_INVALID_ARGUMENT = 3,
    IRUFUS_ERR_UNSUPPORTED_IMAGE = 4,
    IRUFUS_ERR_CORRUPT_IMAGE = 5,
    IRUFUS_ERR_INSUFFICIENT_SPACE = 6,
    IRUFUS_ERR_DEVICE_MISMATCH = 7,
    IRUFUS_ERR_DEVICE_GONE = 8,
    IRUFUS_ERR_VERIFY_FAILED = 9,
    IRUFUS_ERR_FILE_TOO_LARGE = 10,
    IRUFUS_ERR_UNSUPPORTED = 11,
    IRUFUS_ERR_BAD_BLOCKS_FOUND = 12,
    IRUFUS_ERR_INTERNAL = 99,
};

/* Progress phases (IrufusCallbacks.progress `phase`). */
enum {
    IRUFUS_PHASE_PREPARING = 0,
    IRUFUS_PHASE_HASHING = 1,
    IRUFUS_PHASE_PARTITIONING = 2,
    IRUFUS_PHASE_FORMATTING = 3,
    IRUFUS_PHASE_WRITING = 4,
    IRUFUS_PHASE_COPYING_FILES = 5,
    IRUFUS_PHASE_SPLITTING_WIM = 6,
    IRUFUS_PHASE_SYNCING = 7,
    IRUFUS_PHASE_VERIFYING = 8,
    IRUFUS_PHASE_BAD_BLOCKS = 9,
    IRUFUS_PHASE_READING = 10,
    IRUFUS_PHASE_ZEROING = 11,
    IRUFUS_PHASE_FINALIZING = 12,
};

typedef struct IrufusError {
    uint32_t code;
    char *message;
} IrufusError;

typedef void (*IrufusProgressFn)(void *ctx, uint32_t phase, uint64_t done, uint64_t total, double bytes_per_sec);
typedef void (*IrufusLogFn)(void *ctx, const char *message);

typedef struct IrufusCallbacks {
    void *ctx;
    IrufusProgressFn progress; /* may be NULL */
    IrufusLogFn log;           /* may be NULL */
} IrufusCallbacks;

typedef struct IrufusCancel IrufusCancel;
typedef struct IrufusDevice IrufusDevice;

uint32_t irufus_abi_version(void);
char *irufus_engine_version(void);
void irufus_string_free(char *s);

IrufusCancel *irufus_cancel_new(void);
void irufus_cancel_trigger(const IrufusCancel *c);
void irufus_cancel_free(IrufusCancel *c);

/* Image analysis → ImageReport JSON. */
char *irufus_analyze(const char *path, IrufusError *err);

/* Checksums of the image file. mask: 1=MD5 2=SHA-1 4=SHA-256 8=SHA-512 (0=SHA-256). → HashResult JSON */
char *irufus_hash_file(const char *path, uint32_t mask, IrufusCallbacks cb, const IrufusCancel *cancel, IrufusError *err);
/* Extract a digest from user input → {"digest","algorithm"} JSON. */
char *irufus_parse_checksum(const char *input, IrufusError *err);

/* Devices. The engine takes ownership of `fd` (closed on error or close). */
IrufusDevice *irufus_device_from_fd(int32_t fd, uint64_t expected_size, uint32_t expected_block_size, IrufusError *err);
void irufus_device_close(IrufusDevice *d);

/* Operations (destructive except save). */
char *irufus_write_image(IrufusDevice *d, const char *image_path, const char *request_json, IrufusCallbacks cb,
                         const IrufusCancel *cancel, IrufusError *err);
char *irufus_zero_device(IrufusDevice *d, bool verify, IrufusCallbacks cb, const IrufusCancel *cancel, IrufusError *err);
char *irufus_bad_blocks(IrufusDevice *d, uint32_t passes, IrufusCallbacks cb, const IrufusCancel *cancel, IrufusError *err);
char *irufus_save_device(IrufusDevice *d, const char *out_path, uint32_t format /* 0 raw, 1 VHD */, IrufusCallbacks cb,
                         const IrufusCancel *cancel, IrufusError *err);

/* Helpers. scheme: 0 = MBR, 1 = GPT. */
char *irufus_fat32_options(uint64_t device_bytes, uint32_t block_size, uint32_t scheme, IrufusError *err);
char *irufus_wue_preview(const char *options_json, IrufusError *err);
char *irufus_sanitize_account_name(const char *name, IrufusError *err);

#ifdef __cplusplus
}
#endif

#endif /* IRUFUS_H */
