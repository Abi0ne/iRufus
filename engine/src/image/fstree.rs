//! File tree extracted from an optical image (ISO9660 or UDF), independent of
//! the on-disc format, plus a reader over a file's extents.

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::os::unix::fs::FileExt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub struct Timestamp {
    pub year: u16,
    pub month: u8,
    pub day: u8,
    pub hour: u8,
    pub minute: u8,
    pub second: u8,
}

#[derive(Debug, Clone)]
pub struct Entry {
    /// Absolute path inside the image, `/`-separated, without trailing slash.
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    /// Byte extents (offset in image, length) that make up the file data.
    pub extents: Vec<(u64, u64)>,
    pub mtime: Option<Timestamp>,
    /// Rock Ridge symbolic link target, if the entry is a symlink.
    pub symlink: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub enum TreeSource {
    Iso9660,
    Joliet,
    RockRidge,
    Udf,
}

#[derive(Debug, Clone)]
pub struct FsTree {
    pub source: TreeSource,
    pub entries: Vec<Entry>,
}

/// Safety limits against malicious images.
pub const MAX_ENTRIES: usize = 2_000_000;
pub const MAX_DEPTH: usize = 64;
pub const MAX_DIR_BYTES: u64 = 64 << 20;

impl FsTree {
    /// Case-insensitive lookup (FAT and firmware are case-insensitive).
    pub fn find(&self, path: &str) -> Option<&Entry> {
        let want = normalize(path);
        self.entries
            .iter()
            .find(|e| e.path.eq_ignore_ascii_case(&want))
    }

    pub fn files(&self) -> impl Iterator<Item = &Entry> {
        self.entries.iter().filter(|e| !e.is_dir)
    }

    pub fn total_file_bytes(&self) -> u64 {
        self.files().map(|e| e.size).sum()
    }

    /// Children of a directory (case-insensitive), one level deep.
    pub fn list_dir<'a>(&'a self, dir: &str) -> impl Iterator<Item = &'a Entry> + 'a {
        let prefix = format!("{}/", normalize(dir).trim_end_matches('/'));
        self.entries.iter().filter(move |e| {
            e.path.len() > prefix.len()
                && e.path[..prefix.len()].eq_ignore_ascii_case(&prefix)
                && !e.path[prefix.len()..].contains('/')
        })
    }

    /// Replace Rock Ridge symlinks to regular files by a copy of the target's
    /// extents (FAT has no symlinks). Directory symlinks and dangling links are
    /// dropped. Returns the list of (link, outcome) for logging.
    pub fn resolve_symlinks(&mut self) -> Vec<(String, Option<String>)> {
        let mut report = Vec::new();
        let mut i = 0;
        while i < self.entries.len() {
            let Some(target) = self.entries[i].symlink.clone() else {
                i += 1;
                continue;
            };
            let link_path = self.entries[i].path.clone();
            let resolved = resolve_relative(&link_path, &target);
            let mut hops = 0;
            let mut cur = resolved.clone();
            let found = loop {
                match self.entries.iter().find(|e| e.path == cur) {
                    Some(e) if e.symlink.is_some() && hops < 8 => {
                        cur = resolve_relative(&e.path, e.symlink.as_ref().unwrap());
                        hops += 1;
                    }
                    Some(e) if !e.is_dir && e.symlink.is_none() => break Some(e.clone()),
                    _ => break None,
                }
            };
            match found {
                Some(t) => {
                    let e = &mut self.entries[i];
                    e.symlink = None;
                    e.size = t.size;
                    e.extents = t.extents;
                    report.push((link_path, Some(cur)));
                    i += 1;
                }
                None => {
                    self.entries.remove(i);
                    report.push((link_path, None));
                }
            }
        }
        report
    }
}

pub fn normalize(path: &str) -> String {
    let p = path.trim_end_matches('/');
    if p.starts_with('/') {
        p.to_string()
    } else {
        format!("/{p}")
    }
}

fn resolve_relative(link_path: &str, target: &str) -> String {
    let mut parts: Vec<&str> = if target.starts_with('/') {
        Vec::new()
    } else {
        let parent = link_path.rsplit_once('/').map(|(p, _)| p).unwrap_or("");
        parent.split('/').filter(|s| !s.is_empty()).collect()
    };
    for comp in target.split('/') {
        match comp {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            c => parts.push(c),
        }
    }
    format!("/{}", parts.join("/"))
}

/// Sequential reader over a list of extents of an image file.
pub struct ExtentReader<'f> {
    file: &'f File,
    extents: Vec<(u64, u64)>,
    total: u64,
    pos: u64,
}

impl<'f> ExtentReader<'f> {
    pub fn new(file: &'f File, extents: &[(u64, u64)], size: u64) -> Self {
        let mut ext = Vec::new();
        let mut remaining = size;
        for &(off, len) in extents {
            if remaining == 0 {
                break;
            }
            let l = len.min(remaining);
            ext.push((off, l));
            remaining -= l;
        }
        let total = size - remaining;
        Self {
            file,
            extents: ext,
            total,
            pos: 0,
        }
    }

    pub fn len(&self) -> u64 {
        self.total
    }

    pub fn is_empty(&self) -> bool {
        self.total == 0
    }
}

impl Read for ExtentReader<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.pos >= self.total || buf.is_empty() {
            return Ok(0);
        }
        let mut base = 0u64;
        for &(off, len) in &self.extents {
            if self.pos < base + len {
                let within = self.pos - base;
                let n = ((len - within) as usize).min(buf.len());
                self.file.read_exact_at(&mut buf[..n], off + within)?;
                self.pos += n as u64;
                return Ok(n);
            }
            base += len;
        }
        Ok(0)
    }
}

impl Seek for ExtentReader<'_> {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let new = match pos {
            SeekFrom::Start(p) => Some(p),
            SeekFrom::End(d) => self.total.checked_add_signed(d),
            SeekFrom::Current(d) => self.pos.checked_add_signed(d),
        }
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid seek"))?;
        self.pos = new;
        Ok(new)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(path: &str, symlink: Option<&str>) -> Entry {
        Entry {
            path: path.into(),
            is_dir: false,
            size: if symlink.is_some() { 0 } else { 10 },
            extents: if symlink.is_some() {
                vec![]
            } else {
                vec![(2048, 10)]
            },
            mtime: None,
            symlink: symlink.map(Into::into),
        }
    }

    #[test]
    fn symlinks_are_resolved_or_dropped() {
        let mut t = FsTree {
            source: TreeSource::RockRidge,
            entries: vec![
                entry("/EFI/boot/grubx64.efi", None),
                entry("/EFI/boot/bootx64.efi", Some("grubx64.efi")),
                entry("/a/link", Some("../EFI/boot/bootx64.efi")),
                entry("/dangling", Some("/nowhere")),
            ],
        };
        let rep = t.resolve_symlinks();
        assert_eq!(rep.len(), 3);
        assert_eq!(t.entries.len(), 3);
        assert_eq!(t.find("/efi/BOOT/BOOTX64.EFI").unwrap().size, 10);
        assert_eq!(t.find("/a/link").unwrap().extents, vec![(2048, 10)]);
        assert!(t.find("/dangling").is_none());
    }

    #[test]
    fn relative_resolution() {
        assert_eq!(resolve_relative("/a/b/c", "../d"), "/a/d");
        assert_eq!(resolve_relative("/a/b/c", "/x/./y"), "/x/y");
        assert_eq!(resolve_relative("/c", "../../d"), "/d");
    }
}
