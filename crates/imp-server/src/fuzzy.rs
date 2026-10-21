//! Matching for completion: orderless and fuzzy.
//!
//! The query is split on spaces and every part must match a candidate, in
//! any order. A part matches as a substring, or failing that as a fuzzy
//! subsequence (`fzf` style). Like smartcase, a part with an uppercase
//! letter matches case-sensitively. Candidates are ranked by how well the
//! parts match; this is the hot loop of every completion, so it is in Rust.

/// The candidates matching `query`, best first, at most `limit` of them.
/// With an empty query they come back in their original order.
pub fn filter(query: &str, candidates: &[String], limit: usize) -> Vec<String> {
    let parts: Vec<&str> = query.split_whitespace().collect();
    if parts.is_empty() {
        return candidates.iter().take(limit).cloned().collect();
    }
    let mut scored: Vec<(i64, usize, &String)> = candidates
        .iter()
        .enumerate()
        .filter_map(|(i, c)| {
            let mut total = 0;
            for part in &parts {
                total += score(part, c)?;
            }
            Some((total, i, c))
        })
        .collect();
    // Best score first; then shorter candidates; then original order.
    scored.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then(a.2.len().cmp(&b.2.len()))
            .then(a.1.cmp(&b.1))
    });
    scored
        .into_iter()
        .take(limit)
        .map(|(_, _, c)| c.clone())
        .collect()
}

/// How well `part` matches `candidate`, or `None` if it doesn't.
pub fn score(part: &str, candidate: &str) -> Option<i64> {
    let sensitive = part.chars().any(char::is_uppercase);
    let fold = |s: &str| {
        if sensitive {
            s.to_string()
        } else {
            s.to_lowercase()
        }
    };
    let (p, c) = (fold(part), fold(candidate));
    if let Some(at) = c.find(&p) {
        // Substring: best at the start, then at a word boundary.
        let boundary = at == 0 || is_separator(c[..at].chars().last().unwrap_or(' '));
        let mut s = 1000 - at as i64;
        if at == 0 {
            s += 500;
        } else if boundary {
            s += 300;
        }
        return Some(s);
    }
    // Fuzzy: every char in order; gaps cost, boundaries help.
    let mut s = 0i64;
    let mut chars = c.char_indices().peekable();
    let mut prev_end: Option<usize> = None;
    let mut prev_char = ' ';
    for pc in p.chars() {
        let mut found = None;
        for (i, cc) in chars.by_ref() {
            if cc == pc {
                found = Some(i);
                break;
            }
            prev_char = cc;
        }
        let i = found?;
        if let Some(end) = prev_end {
            s -= (i - end) as i64;
        }
        if is_separator(prev_char) {
            s += 10;
        }
        prev_end = Some(i + pc.len_utf8());
        prev_char = pc;
    }
    Some(s)
}

fn is_separator(c: char) -> bool {
    matches!(c, ' ' | '/' | '_' | '-' | '.' | ':')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn orderless_parts_all_match() {
        let c = strings(&["src/main.rs", "src/lib.rs", "tests/main_test.rs"]);
        assert_eq!(filter("main src", &c, 10), ["src/main.rs"]);
        assert_eq!(filter("rs lib", &c, 10), ["src/lib.rs"]);
    }

    #[test]
    fn substring_beats_fuzzy_and_start_beats_middle() {
        let c = strings(&["xbuffer", "buffer-list", "b_u_f"]);
        assert_eq!(filter("buf", &c, 10), ["buffer-list", "xbuffer", "b_u_f"]);
    }

    #[test]
    fn fuzzy_subsequence() {
        let c = strings(&["describe-function", "delete-file"]);
        assert_eq!(filter("dfn", &c, 10), ["describe-function"]);
    }

    #[test]
    fn smartcase_and_limit() {
        let c = strings(&["Foo", "foo", "food"]);
        assert_eq!(filter("Foo", &c, 10), ["Foo"]);
        assert_eq!(filter("foo", &c, 2), ["Foo", "foo"]);
        assert_eq!(filter("", &c, 2), ["Foo", "foo"]);
    }
}
