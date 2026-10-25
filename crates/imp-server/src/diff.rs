//! Line diffs: which blocks of lines differ between two texts, as git's
//! `-U0` hunks give them. The git-gutter package compares a buffer's text
//! with git's copy this way, without temporary files.

/// One changed block: old lines `old_start..old_start + old_count` became
/// new lines `new_start..new_start + new_count`, counting from 0. A count
/// of 0 means lines were only added (or only removed), before that start.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Hunk {
    pub old_start: usize,
    pub old_count: usize,
    pub new_start: usize,
    pub new_count: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Op {
    Equal,
    Delete,
    Insert,
}

/// The lines of `text`; a final line break doesn't start another line, so
/// a missing one isn't a change.
fn lines(text: &str) -> Vec<&str> {
    let text = text.strip_suffix('\n').unwrap_or(text);
    if text.is_empty() {
        Vec::new()
    } else {
        text.split('\n').collect()
    }
}

/// The changed blocks between `old` and `new`, in order.
pub fn line_hunks(old: &str, new: &str) -> Vec<Hunk> {
    let (a, b) = (lines(old), lines(new));
    // Most edits leave the start and end alone; Myers only sees the middle.
    let prefix = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let suffix = a[prefix..]
        .iter()
        .rev()
        .zip(b[prefix..].iter().rev())
        .take_while(|(x, y)| x == y)
        .count();
    let (a, b) = (&a[prefix..a.len() - suffix], &b[prefix..b.len() - suffix]);
    let mut hunks = Vec::new();
    let (mut i, mut j) = (0, 0);
    let ops = myers(a, b);
    let mut ops = ops.iter().peekable();
    while let Some(&op) = ops.next() {
        if op == Op::Equal {
            i += 1;
            j += 1;
            continue;
        }
        let mut hunk = Hunk {
            old_start: prefix + i,
            old_count: 0,
            new_start: prefix + j,
            new_count: 0,
        };
        let mut op = Some(op);
        while let Some(o) = op.filter(|o| *o != Op::Equal) {
            if o == Op::Delete {
                hunk.old_count += 1;
                i += 1;
            } else {
                hunk.new_count += 1;
                j += 1;
            }
            op = ops.next_if(|o| **o != Op::Equal).copied();
        }
        hunks.push(hunk);
    }
    hunks
}

/// The shortest edit from `a` to `b`, by Myers' O(ND) algorithm.
fn myers(a: &[&str], b: &[&str]) -> Vec<Op> {
    let (n, m) = (a.len() as isize, b.len() as isize);
    let max = (n + m) as usize;
    let at = |k: isize| (k + max as isize) as usize;
    let mut v = vec![0isize; 2 * max + 2];
    let mut trace = Vec::new();
    'search: for d in 0..=max as isize {
        trace.push(v.clone());
        for k in (-d..=d).step_by(2) {
            let mut x = if k == -d || (k != d && v[at(k - 1)] < v[at(k + 1)]) {
                v[at(k + 1)]
            } else {
                v[at(k - 1)] + 1
            };
            let mut y = x - k;
            while x < n && y < m && a[x as usize] == b[y as usize] {
                x += 1;
                y += 1;
            }
            v[at(k)] = x;
            if x >= n && y >= m {
                break 'search;
            }
        }
    }
    // Walk back from the end through each step's furthest points.
    let mut ops = Vec::new();
    let (mut x, mut y) = (n, m);
    for (d, v) in trace.iter().enumerate().rev() {
        let d = d as isize;
        let k = x - y;
        let prev_k = if k == -d || (k != d && v[at(k - 1)] < v[at(k + 1)]) {
            k + 1
        } else {
            k - 1
        };
        let prev_x = v[at(prev_k)];
        let prev_y = prev_x - prev_k;
        while x > prev_x && y > prev_y {
            ops.push(Op::Equal);
            x -= 1;
            y -= 1;
        }
        if d > 0 {
            ops.push(if x == prev_x { Op::Insert } else { Op::Delete });
        }
        x = prev_x;
        y = prev_y;
    }
    ops.reverse();
    ops
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hunks(old: &str, new: &str) -> Vec<(usize, usize, usize, usize)> {
        line_hunks(old, new)
            .into_iter()
            .map(|h| (h.old_start, h.old_count, h.new_start, h.new_count))
            .collect()
    }

    #[test]
    fn the_same_text_has_no_hunks() {
        assert_eq!(hunks("", ""), []);
        assert_eq!(hunks("a\nb\n", "a\nb\n"), []);
        // A missing final line break isn't a change.
        assert_eq!(hunks("a\nb", "a\nb\n"), []);
    }

    #[test]
    fn added_lines() {
        assert_eq!(hunks("a\nb\n", "a\nx\ny\nb\n"), [(1, 0, 1, 2)]);
        assert_eq!(hunks("a\n", "x\na\n"), [(0, 0, 0, 1)]);
        assert_eq!(hunks("a\n", "a\nx\n"), [(1, 0, 1, 1)]);
        assert_eq!(hunks("", "x\ny\n"), [(0, 0, 0, 2)]);
    }

    #[test]
    fn removed_lines() {
        assert_eq!(hunks("a\nx\ny\nb\n", "a\nb\n"), [(1, 2, 1, 0)]);
        assert_eq!(hunks("x\na\n", "a\n"), [(0, 1, 0, 0)]);
        assert_eq!(hunks("a\nx\n", "a\n"), [(1, 1, 1, 0)]);
        assert_eq!(hunks("a\n", ""), [(0, 1, 0, 0)]);
    }

    #[test]
    fn changed_lines_and_several_hunks() {
        assert_eq!(hunks("a\nb\nc\n", "a\nB\nc\n"), [(1, 1, 1, 1)]);
        assert_eq!(hunks("a\nb\nc\n", "a\nB\nB2\nc\n"), [(1, 1, 1, 2)]);
        assert_eq!(
            hunks("1\n2\n3\n4\n5\n6\n", "1\nx\n3\n4\n6\ny\n"),
            [(1, 1, 1, 1), (4, 1, 4, 0), (6, 0, 5, 1)]
        );
        // Repeated lines still pair up as few changes as can be.
        assert_eq!(hunks("a\na\na\n", "a\nb\na\na\n"), [(1, 0, 1, 1)]);
    }
}
