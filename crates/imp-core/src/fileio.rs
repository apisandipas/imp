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
/// written through to its target; an existing file's permissions are
/// kept. With `backup`, the old file is kept as `path~`.
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
    let temp = dir.join(format!(".{name}.imp-{}", std::process::id()));
    let result = (|| {
        let mut file = std::fs::File::create(&temp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        if let Ok(meta) = std::fs::metadata(&target) {
            std::fs::set_permissions(&temp, meta.permissions())?;
            if backup {
                std::fs::copy(&target, dir.join(format!("{name}~")))?;
            }
        }
        std::fs::rename(&temp, &target)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    result
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
}
