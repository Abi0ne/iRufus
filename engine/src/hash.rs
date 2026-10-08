//! MD5 / SHA-1 / SHA-256 / SHA-512 computed in a single pass.

use std::io::Read;

use md5::Md5;
use serde::Serialize;
use sha1::Sha1;
use sha2::{Digest, Sha256, Sha512};

use crate::error::{IoContext, Result};
use crate::progress::{OpContext, Phase};

#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum HashAlgo {
    Md5 = 1,
    Sha1 = 2,
    Sha256 = 4,
    Sha512 = 8,
}

impl HashAlgo {
    pub const ALL: [HashAlgo; 4] = [
        HashAlgo::Md5,
        HashAlgo::Sha1,
        HashAlgo::Sha256,
        HashAlgo::Sha512,
    ];

    pub fn hex_len(self) -> usize {
        match self {
            HashAlgo::Md5 => 32,
            HashAlgo::Sha1 => 40,
            HashAlgo::Sha256 => 64,
            HashAlgo::Sha512 => 128,
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            HashAlgo::Md5 => "MD5",
            HashAlgo::Sha1 => "SHA-1",
            HashAlgo::Sha256 => "SHA-256",
            HashAlgo::Sha512 => "SHA-512",
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, PartialEq, Eq)]
pub struct HashResult {
    pub md5: Option<String>,
    pub sha1: Option<String>,
    pub sha256: Option<String>,
    pub sha512: Option<String>,
}

impl HashResult {
    pub fn get(&self, algo: HashAlgo) -> Option<&str> {
        match algo {
            HashAlgo::Md5 => self.md5.as_deref(),
            HashAlgo::Sha1 => self.sha1.as_deref(),
            HashAlgo::Sha256 => self.sha256.as_deref(),
            HashAlgo::Sha512 => self.sha512.as_deref(),
        }
    }
}

#[derive(Default)]
pub struct MultiHasher {
    md5: Option<Md5>,
    sha1: Option<Sha1>,
    sha256: Option<Sha256>,
    sha512: Option<Sha512>,
}

impl MultiHasher {
    /// `mask` is a bitwise OR of `HashAlgo` values; 0 means SHA-256 only.
    pub fn new(mask: u32) -> Self {
        let mask = if mask == 0 {
            HashAlgo::Sha256 as u32
        } else {
            mask
        };
        Self {
            md5: (mask & HashAlgo::Md5 as u32 != 0).then(Md5::new),
            sha1: (mask & HashAlgo::Sha1 as u32 != 0).then(Sha1::new),
            sha256: (mask & HashAlgo::Sha256 as u32 != 0).then(Sha256::new),
            sha512: (mask & HashAlgo::Sha512 as u32 != 0).then(Sha512::new),
        }
    }

    pub fn update(&mut self, data: &[u8]) {
        if let Some(h) = &mut self.md5 {
            h.update(data);
        }
        if let Some(h) = &mut self.sha1 {
            h.update(data);
        }
        if let Some(h) = &mut self.sha256 {
            h.update(data);
        }
        if let Some(h) = &mut self.sha512 {
            h.update(data);
        }
    }

    pub fn finish(self) -> HashResult {
        HashResult {
            md5: self.md5.map(|h| hex(&h.finalize())),
            sha1: self.sha1.map(|h| hex(&h.finalize())),
            sha256: self.sha256.map(|h| hex(&h.finalize())),
            sha512: self.sha512.map(|h| hex(&h.finalize())),
        }
    }
}

pub fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        let _ = write!(s, "{b:02x}");
    }
    s
}

pub fn sha256_of(data: &[u8]) -> String {
    hex(&Sha256::digest(data))
}

/// Hash a whole stream, reporting progress against `total` (0 if unknown).
pub fn hash_reader(
    reader: &mut dyn Read,
    mask: u32,
    total: u64,
    ctx: &OpContext,
) -> Result<(HashResult, u64)> {
    let mut hasher = MultiHasher::new(mask);
    let mut buf = vec![0u8; 4 << 20];
    let mut tracker = ctx.phase(Phase::Hashing, total);
    let mut count = 0u64;
    loop {
        ctx.check()?;
        let n = reader.read(&mut buf).ctx("reading image for checksum")?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        count += n as u64;
        tracker.advance(n as u64);
    }
    tracker.finish();
    Ok((hasher.finish(), count))
}

/// Extract a hexadecimal digest from user input. Accepts a bare digest, a
/// `sha256:<hex>` prefix, or a `sha256sum`-style line `"<hex>  filename"`.
/// Returns the lowercase digest and the algorithm inferred from its length.
pub fn parse_expected(input: &str) -> Option<(String, HashAlgo)> {
    let token = input
        .split(|c: char| c.is_whitespace() || c == '=' || c == ':')
        .map(|t| t.trim_matches(|c| c == '(' || c == ')' || c == '*'))
        .find(|t| t.len() >= 32 && t.chars().all(|c| c.is_ascii_hexdigit()))?;
    let digest = token.to_ascii_lowercase();
    let algo = HashAlgo::ALL
        .into_iter()
        .find(|a| a.hex_len() == digest.len())?;
    Some((digest, algo))
}

/// Constant-time comparison of two hex digests.
pub fn digests_equal(a: &str, b: &str) -> bool {
    let (a, b) = (a.to_ascii_lowercase(), b.to_ascii_lowercase());
    if a.len() != b.len() {
        return false;
    }
    a.bytes()
        .zip(b.bytes())
        .fold(0u8, |acc, (x, y)| acc | (x ^ y))
        == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::progress::{CancelToken, NullSink};

    #[test]
    fn known_vectors_abc() {
        let mut h = MultiHasher::new(0xF);
        h.update(b"abc");
        let r = h.finish();
        assert_eq!(r.md5.unwrap(), "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(r.sha1.unwrap(), "a9993e364706816aba3e25717850c26c9cd0d89d");
        assert_eq!(
            r.sha256.unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            r.sha512.unwrap(),
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        );
    }

    #[test]
    fn default_mask_is_sha256_only() {
        let r = MultiHasher::new(0).finish();
        assert!(r.md5.is_none() && r.sha1.is_none() && r.sha512.is_none());
        assert_eq!(
            r.sha256.unwrap(),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn streaming_matches_one_shot() {
        let data: Vec<u8> = (0..10_000_000u32).map(|i| (i * 7 % 251) as u8).collect();
        let ctx = OpContext::new(&NullSink, CancelToken::new());
        let (r, n) = hash_reader(
            &mut &data[..],
            HashAlgo::Sha256 as u32,
            data.len() as u64,
            &ctx,
        )
        .unwrap();
        assert_eq!(n, data.len() as u64);
        assert_eq!(r.sha256.unwrap(), sha256_of(&data));
    }

    #[test]
    fn hashing_honours_cancellation() {
        let ctx = OpContext::new(&NullSink, CancelToken::new());
        ctx.cancel.cancel();
        let data = [0u8; 100];
        assert!(matches!(
            hash_reader(&mut &data[..], 0, 100, &ctx),
            Err(crate::error::EngineError::Cancelled)
        ));
    }

    #[test]
    fn parses_expected_digest_formats() {
        let d = "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855";
        assert_eq!(parse_expected(d).unwrap().1, HashAlgo::Sha256);
        assert_eq!(
            parse_expected(&format!("sha256:{d}")).unwrap().0,
            d.to_lowercase()
        );
        assert_eq!(
            parse_expected(&format!("{d}  ubuntu.iso")).unwrap().0,
            d.to_lowercase()
        );
        assert_eq!(
            parse_expected(&format!("SHA256 (ubuntu.iso) = {d}"))
                .unwrap()
                .0,
            d.to_lowercase()
        );
        assert_eq!(
            parse_expected("900150983cd24fb0d6963f7d28e17f72")
                .unwrap()
                .1,
            HashAlgo::Md5
        );
        assert!(parse_expected("not a hash").is_none());
        assert!(parse_expected("abcd").is_none());
        assert!(digests_equal("ABcd", "abCD"));
        assert!(!digests_equal("abcd", "abce"));
    }
}
