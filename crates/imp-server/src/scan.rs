//! Whole-buffer scans that are too slow a char at a time from Scheme:
//! matching brackets and pairing tags. They answer questions; what the
//! answers mean (text objects, %) is decided in Scheme.

use ropey::Rope;

/// Scanning back from `from` (inclusive), the `count`th unmatched `open`.
/// A `close` at `from` itself doesn't count, so from inside or on the
/// closing bracket of a pair this finds its opening one.
pub fn find_open(
    rope: &Rope,
    open: char,
    close: char,
    from: usize,
    mut count: usize,
) -> Option<usize> {
    if from >= rope.len_chars() {
        return None;
    }
    let mut depth = 0usize;
    let mut chars = rope.chars_at(from + 1);
    let mut at = from + 1;
    while let Some(c) = chars.prev() {
        at -= 1;
        if c == close && at != from {
            depth += 1;
        } else if c == open {
            if depth > 0 {
                depth -= 1;
            } else if count <= 1 {
                return Some(at);
            } else {
                count -= 1;
            }
        }
    }
    None
}

/// Scanning forward from `from` (inclusive), the first `close` that isn't
/// matched by an `open` after `from`.
pub fn find_close(rope: &Rope, open: char, close: char, from: usize) -> Option<usize> {
    if from > rope.len_chars() {
        return None;
    }
    let mut depth = 0usize;
    for (i, c) in rope.chars_at(from).enumerate() {
        if c == open {
            depth += 1;
        } else if c == close {
            if depth == 0 {
                return Some(from + i);
            }
            depth -= 1;
        }
    }
    None
}

/// Every `<tag ...>...</tag>` pair that contains char offset `offset`, as
/// (open-start, open-end, close-start, close-end) char offsets, innermost
/// first. Unclosed tags (`<br>`) and self-closing ones are skipped.
pub fn tag_pairs_around(rope: &Rope, offset: usize) -> Vec<[usize; 4]> {
    let text = rope.to_string();
    let bytes = text.as_bytes();
    let mut stack: Vec<(&str, usize, usize)> = Vec::new();
    let mut pairs = Vec::new();
    let mut p = 0;
    while let Some(i) = text[p..].find('<') {
        let start = p + i;
        p = start + 1;
        let closing = bytes.get(start + 1) == Some(&b'/');
        let name_start = start + 1 + usize::from(closing);
        let name_end = text[name_start..]
            .find(|c: char| c.is_whitespace() || c == '>' || c == '/')
            .map_or(text.len(), |n| name_start + n);
        let name = &text[name_start..name_end];
        let Some(gt) = text[name_end..].find('>') else {
            break;
        };
        let end = name_end + gt + 1;
        if name.is_empty() {
            continue;
        }
        p = end;
        if closing {
            // Pop to the matching open tag, dropping unclosed ones.
            if let Some(k) = stack.iter().rposition(|(n, _, _)| *n == name) {
                let (_, os, oe) = stack[k];
                stack.truncate(k);
                pairs.push([os, oe, start, end]);
            }
        } else if bytes[end - 2] != b'/' {
            stack.push((name, start, end));
        }
    }
    let offset = rope.char_to_byte(offset.min(rope.len_chars()));
    let mut around: Vec<[usize; 4]> = pairs
        .into_iter()
        .filter(|t| t[0] <= offset && offset < t[3])
        .collect();
    // The latest-opening pair is the innermost.
    around.sort_by(|a, b| b[0].cmp(&a[0]));
    around
        .into_iter()
        .map(|t| t.map(|b| rope.byte_to_char(b)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn brackets() {
        let r = Rope::from_str("f(a, (b), c)");
        assert_eq!(find_open(&r, '(', ')', 6, 1), Some(5));
        assert_eq!(find_open(&r, '(', ')', 6, 2), Some(1));
        assert_eq!(find_open(&r, '(', ')', 7, 1), Some(5)); // on the )
        assert_eq!(find_open(&r, '(', ')', 0, 1), None);
        assert_eq!(find_close(&r, '(', ')', 2), Some(11));
        assert_eq!(find_close(&r, '(', ')', 6), Some(7));
    }

    #[test]
    fn tags() {
        let r = Rope::from_str("<a><b x='1'>tëxt</b><br></a>");
        let pairs = tag_pairs_around(&r, 13);
        assert_eq!(pairs, vec![[3, 12, 16, 20], [0, 3, 24, 28]]);
        assert!(tag_pairs_around(&r, 30).is_empty());
    }
}
