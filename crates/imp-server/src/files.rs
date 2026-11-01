//! Listing a project's files for find-file, the way ripgrep would: hidden
//! files and anything .gitignore'd are skipped.

use ignore::WalkBuilder;
use std::path::Path;

/// Files under `root`, as paths relative to it, sorted, at most `limit`.
pub fn list(root: &str, limit: usize) -> Vec<String> {
    let root = Path::new(root);
    let mut files: Vec<String> = WalkBuilder::new(root)
        .build()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_some_and(|t| t.is_file()))
        .filter_map(|entry| {
            entry
                .path()
                .strip_prefix(root)
                .ok()
                .map(|p| p.display().to_string())
        })
        .take(limit)
        .collect();
    files.sort();
    files
}

/// The names in directory `dir` that git ignores, sorted: those its
/// .gitignore files (the parents' too) leave out. Empty outside a
/// repository, or if `dir` can't be read.
pub fn ignored(dir: &str) -> Vec<String> {
    let dir = Path::new(dir);
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let kept: std::collections::HashSet<std::ffi::OsString> = WalkBuilder::new(dir)
        .max_depth(Some(1))
        .hidden(false)
        .build()
        .filter_map(Result::ok)
        .filter(|entry| entry.depth() == 1)
        .map(|entry| entry.file_name().to_owned())
        .collect();
    let mut names: Vec<String> = entries
        .filter_map(Result::ok)
        .map(|e| e.file_name())
        .filter(|name| !kept.contains(name))
        .map(|name| name.to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

/// A file's type and permissions as `ls -l` shows them: "drwxr-xr-x".
pub fn permissions(m: &std::fs::Metadata) -> String {
    let t = m.file_type();
    let kind = if t.is_dir() {
        'd'
    } else if t.is_symlink() {
        'l'
    } else {
        '-'
    };
    #[cfg(unix)]
    let mode = {
        use std::os::unix::fs::PermissionsExt;
        m.permissions().mode()
    };
    #[cfg(not(unix))]
    let mode = if m.permissions().readonly() {
        0o555
    } else {
        0o755
    };
    let mut out = String::from(kind);
    for shift in [6, 3, 0] {
        let bits = (mode >> shift) & 7;
        out.push(if bits & 4 != 0 { 'r' } else { '-' });
        out.push(if bits & 2 != 0 { 'w' } else { '-' });
        out.push(if bits & 1 != 0 { 'x' } else { '-' });
    }
    out
}

#[cfg(all(test, unix))]
mod permission_tests {
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn shows_permissions_as_ls_does() {
        let dir = std::env::temp_dir().join(format!("imp-perm-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("f");
        std::fs::write(&file, "x").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o640)).unwrap();
        let m = std::fs::symlink_metadata(&file).unwrap();
        assert_eq!(super::permissions(&m), "-rw-r-----");
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        let m = std::fs::symlink_metadata(&dir).unwrap();
        assert_eq!(super::permissions(&m), "drwxr-xr-x");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}

/// Whether process `pid` is running and is imp, so a crash copy it
/// wrote is still in use. On Linux by its name in /proc, so a reused pid
/// that isn't imp doesn't count; elsewhere on Unix only whether it runs.
/// Where neither can be asked, false: a copy offered twice is better
/// than one never offered.
pub fn imp_running(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    #[cfg(target_os = "linux")]
    {
        std::fs::read_to_string(format!("/proc/{pid}/comm"))
            .map(|name| {
                let name = name.trim_end();
                name == "imp" || name.starts_with("imp-")
            })
            .unwrap_or(false)
    }
    #[cfg(all(unix, not(target_os = "linux")))]
    {
        let Ok(pid) = libc::pid_t::try_from(pid) else {
            return false;
        };
        // Signal 0 only asks; EPERM means it runs as someone else.
        // SAFETY: kill with signal 0 sends nothing.
        unsafe { libc::kill(pid, 0) == 0 }
        || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }
    #[cfg(not(unix))]
    {
        false
    }
}

#[cfg(test)]
mod ignored_tests {
    #[test]
    fn names_what_git_ignores() {
        let dir = std::env::temp_dir().join(format!("imp-ignored-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("target")).unwrap();
        std::fs::create_dir_all(dir.join("src")).unwrap();
        for f in ["a.rs", "x.log", ".env", "src/b.rs", "src/y.log"] {
            std::fs::write(dir.join(f), "").unwrap();
        }
        std::fs::write(dir.join(".gitignore"), "target/\n*.log\n").unwrap();
        let d = dir.display().to_string();
        assert!(super::ignored(&d).is_empty(), "outside a repository");
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        assert_eq!(super::ignored(&d), ["target", "x.log"]);
        assert_eq!(super::ignored(&format!("{d}/src")), ["y.log"]);
        assert!(super::ignored(&format!("{d}/missing")).is_empty());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
