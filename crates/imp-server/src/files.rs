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
