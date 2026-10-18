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
