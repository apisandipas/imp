//! Reading and writing files: line endings, encodings, and saving without
//! ever leaving a half-written file behind.

use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// How a file's text is stored on disk, so it is written back the same way.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct FileFormat {
    /// Lines end in CR LF (Vim's fileformat=dos). In memory they are LF.
    pub crlf: bool,
    /// The file started with a UTF-8 byte order mark.
    pub bom: bool,
    pub encoding: Encoding,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Encoding {
    #[default]
    Utf8,
    /// Bytes that aren't valid UTF-8 are read as Latin-1, one char per
    /// byte, so the file round-trips unchanged.
    Latin1,
}

const BOM: &[u8] = b"\xEF\xBB\xBF";

/// Turns file bytes into text and the format to write it back in.
pub fn decode(bytes: &[u8]) -> (String, FileFormat) {
    let mut format = FileFormat::default();
    let bytes = match bytes.strip_prefix(BOM) {
        Some(rest) => {
            format.bom = true;
            rest
        }
        None => bytes,
    };
    let text = match std::str::from_utf8(bytes) {
        Ok(text) => text.to_string(),
        Err(_) => {
            format.encoding = Encoding::Latin1;
            bytes.iter().map(|&b| b as char).collect()
        }
    };
    // CR LF if most line breaks are: a stray CR LF in an LF file stays.
    let lf = text.matches('\n').count();
    let crlf = text.matches("\r\n").count();
    if crlf > 0 && crlf * 2 > lf {
        format.crlf = true;
        return (text.replace("\r\n", "\n"), format);
    }
    (text, format)
}

/// Turns text back into file bytes in `format`. Chars Latin-1 can't hold
/// are an error rather than silently changed.
pub fn encode(text: &str, format: FileFormat) -> io::Result<Vec<u8>> {
    let text = if format.crlf {
        text.replace('\n', "\r\n")
    } else {
        text.to_string()
    };
    let mut out = Vec::with_capacity(text.len() + 3);
    if format.bom {
        out.extend_from_slice(BOM);
    }
    match format.encoding {
        Encoding::Utf8 => out.extend_from_slice(text.as_bytes()),
        Encoding::Latin1 => {
            for c in text.chars() {
                let n = c as u32;
                if n > 255 {
                    return Err(io::Error::other(format!(
                        "{c:?} can't be written as latin1 (set fileencoding=utf-8)"
                    )));
                }
                out.push(n as u8);
            }
        }
    }
    Ok(out)
}

/// Writes `bytes` to `path` atomically: to a temporary file beside it,
/// then renamed over it, so a crash never leaves half a file. A symlink is
/// written through to its target; an existing file's permissions, and its
/// owner where allowed, are kept. With `backup`, the old file is kept as
/// `path~`.
///
/// The directory may be writable by others, so neither the temporary file
/// nor `path~` follows a symlink planted there, and the temporary file is
/// never readable by more people than the file it replaces.
pub fn write_atomic(path: &Path, bytes: &[u8], backup: bool) -> io::Result<()> {
    let target: PathBuf = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let dir = target
        .parent()
        .filter(|d| !d.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let name = target
        .file_name()
        .ok_or_else(|| io::Error::other("not a file name"))?
        .to_string_lossy();
    let meta = std::fs::metadata(&target).ok();
    let (temp, mut file) = create_temp(dir, &name, meta.as_ref())?;
    let result = (|| {
        file.write_all(bytes)?;
        if let Some(meta) = &meta {
            keep_owner_and_mode(&file, meta)?;
        }
        file.sync_all()?;
        if let (true, Some(meta)) = (backup, &meta) {
            write_backup(&target, &dir.join(format!("{name}~")), meta)?;
        }
        std::fs::rename(&temp, &target)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    result
}

/// Creates a new temporary file in `dir` for saving `name`, with
/// [`open_new`] and under a name others can't guess ahead of time.
fn create_temp(
    dir: &Path,
    name: &str,
    meta: Option<&std::fs::Metadata>,
) -> io::Result<(PathBuf, std::fs::File)> {
    use std::hash::{BuildHasher, Hasher};
    // Unique per write, so two writes of one file (from threads, or two
    // editors) can't take each other's temporary file.
    static WRITES: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let mut tries = 0;
    loop {
        let n = WRITES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        // RandomState is seeded randomly per process; with the time mixed
        // in, the suffix can't be predicted from the pid and counter.
        let mut h = std::collections::hash_map::RandomState::new().build_hasher();
        h.write_u32(std::process::id());
        h.write_usize(n);
        if let Ok(t) = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH) {
            h.write_u128(t.as_nanos());
        }
        let temp = dir.join(format!(".{name}.imp-{:016x}", h.finish()));
        match open_new(&temp, meta) {
            Ok(file) => return Ok((temp, file)),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists && tries < 16 => tries += 1,
            Err(e) => return Err(e),
        }
    }
}

/// Creates `path`, which must not exist yet: `create_new` refuses any
/// existing name, a symlink included, rather than following it. On Unix
/// the file is born with the permission bits in `meta` (the default for a
/// new file), so it is never readable by more people than the original.
fn open_new(path: &Path, meta: Option<&std::fs::Metadata>) -> io::Result<std::fs::File> {
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    if let Some(meta) = meta {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        // Only the permission bits: setuid and friends are put back once
        // the file is whole and has its owner.
        opts.mode(meta.permissions().mode() & 0o777);
    }
    #[cfg(not(unix))]
    let _ = meta;
    opts.open(path)
}

/// Gives `file` the owner, group and permissions in `meta`. The owner is
/// kept only where allowed (root saving another user's file): a user
/// can't give a file away, and that isn't a reason to refuse the save.
fn keep_owner_and_mode(file: &std::fs::File, meta: &std::fs::Metadata) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        match std::os::unix::fs::fchown(file, Some(meta.uid()), Some(meta.gid())) {
            Err(e) if e.kind() != io::ErrorKind::PermissionDenied => return Err(e),
            _ => {}
        }
    }
    // After the chown, which clears setuid and setgid.
    file.set_permissions(meta.permissions())
}

/// Copies `target` to `backup` without following a symlink at `backup`:
/// any old backup is removed (a symlink itself, not what it points to),
/// then the new one is made with `create_new`.
fn write_backup(target: &Path, backup: &Path, meta: &std::fs::Metadata) -> io::Result<()> {
    match std::fs::remove_file(backup) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
        _ => {}
    }
    let mut out = open_new(backup, Some(meta))?;
    io::copy(&mut std::fs::File::open(target)?, &mut out)?;
    keep_owner_and_mode(&out, meta)
}

/// What the file on disk looks like now: modification time and size.
pub fn stamp(path: &Path) -> Option<(SystemTime, u64)> {
    let meta = std::fs::metadata(path).ok()?;
    Some((meta.modified().ok()?, meta.len()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crlf_round_trips() {
        let (text, f) = decode(b"a\r\nb\r\n");
        assert_eq!(text, "a\nb\n");
        assert!(f.crlf);
        assert_eq!(encode(&text, f).unwrap(), b"a\r\nb\r\n");
        // A lone CR LF in an LF file is left alone.
        let (text, f) = decode(b"a\nb\nc\r\nd\n");
        assert!(!f.crlf);
        assert_eq!(text, "a\nb\nc\r\nd\n");
    }

    #[test]
    fn bom_and_latin1_round_trip() {
        let (text, f) = decode(b"\xEF\xBB\xBFhi\n");
        assert_eq!(text, "hi\n");
        assert_eq!(encode(&text, f).unwrap(), b"\xEF\xBB\xBFhi\n");
        let (text, f) = decode(b"caf\xE9\n");
        assert_eq!(text, "café\n");
        assert_eq!(f.encoding, Encoding::Latin1);
        assert_eq!(encode(&text, f).unwrap(), b"caf\xE9\n");
        assert!(encode("日", f).is_err());
    }

    #[test]
    fn atomic_write_keeps_permissions_and_backup() {
        let dir = std::env::temp_dir().join(format!("imp-fileio-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("f.txt");
        std::fs::write(&path, "old").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();
        }
        write_atomic(&path, b"new", true).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "new");
        assert_eq!(std::fs::read_to_string(dir.join("f.txt~")).unwrap(), "old");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o640);
        }
        // No temporary files are left.
        let leftovers = std::fs::read_dir(&dir)
            .unwrap()
            .filter(|e| {
                e.as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .contains(".imp-")
            })
            .count();
        assert_eq!(leftovers, 0);
    }

    #[cfg(unix)]
    #[test]
    fn private_file_stays_private_while_saving() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("imp-fileio-private-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(".env");
        std::fs::write(&path, "SECRET=1").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o7777;
        // The temporary file is 0600 from the moment it exists, before any
        // text is in it, whatever the umask.
        let meta = std::fs::metadata(&path).unwrap();
        let (temp, _file) = create_temp(&dir, ".env", Some(&meta)).unwrap();
        assert_eq!(mode(&temp), 0o600);
        std::fs::remove_file(&temp).unwrap();
        write_atomic(&path, b"SECRET=2", true).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "SECRET=2");
        assert_eq!(mode(&path), 0o600);
        assert_eq!(mode(&dir.join(".env~")), 0o600);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn save_does_not_follow_planted_symlinks() {
        let dir = std::env::temp_dir().join(format!("imp-fileio-link-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("f.txt");
        let victim = dir.join("victim");
        std::fs::write(&path, "old").unwrap();
        std::fs::write(&victim, "untouched").unwrap();
        // A symlink at the backup name is replaced, not written through.
        std::os::unix::fs::symlink(&victim, dir.join("f.txt~")).unwrap();
        write_atomic(&path, b"new", true).unwrap();
        assert_eq!(std::fs::read_to_string(&victim).unwrap(), "untouched");
        let backup = std::fs::symlink_metadata(dir.join("f.txt~")).unwrap();
        assert!(backup.file_type().is_file());
        assert_eq!(std::fs::read_to_string(dir.join("f.txt~")).unwrap(), "old");
        // A temporary file is never made over an existing name, so a
        // symlink planted at one is refused rather than followed.
        let temp = dir.join("planted");
        std::os::unix::fs::symlink(&victim, &temp).unwrap();
        let meta = std::fs::metadata(&path).unwrap();
        let err = open_new(&temp, Some(&meta)).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(std::fs::read_to_string(&victim).unwrap(), "untouched");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
