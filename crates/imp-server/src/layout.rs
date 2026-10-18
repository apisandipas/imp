//! The window layout: a tree of splits with windows at the leaves.
//!
//! A split lays its children out in a row (side by side) or a column (one
//! above another), sized by weight. Side-by-side windows are separated by
//! a one-column border; every window's area includes its own status line.

/// How a split arranges its children.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dir {
    /// One above another (Vim's :split).
    Column,
    /// Side by side (Vim's :vsplit).
    Row,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Layout {
    Window(usize),
    Split(Dir, Vec<(Layout, f64)>),
}

impl Default for Layout {
    fn default() -> Self {
        Layout::Window(1)
    }
}

/// A screen rectangle: column, row, width, height.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rect {
    pub x: usize,
    pub y: usize,
    pub w: usize,
    pub h: usize,
}

impl Rect {
    pub fn contains(&self, x: usize, y: usize) -> bool {
        x >= self.x && x < self.x + self.w && y >= self.y && y < self.y + self.h
    }
}

impl Layout {
    /// Every window with its rectangle inside `area`.
    pub fn rects(&self, area: Rect) -> Vec<(usize, Rect)> {
        let mut out = Vec::new();
        self.place(area, &mut out);
        out
    }

    fn place(&self, area: Rect, out: &mut Vec<(usize, Rect)>) {
        match self {
            Layout::Window(id) => out.push((*id, area)),
            Layout::Split(dir, children) => {
                let n = children.len();
                // Borders between side-by-side windows take a column each.
                let borders = if *dir == Dir::Row { n - 1 } else { 0 };
                let total = match dir {
                    Dir::Row => area.w.saturating_sub(borders),
                    Dir::Column => area.h,
                };
                let sizes = share(total, children.iter().map(|(_, w)| *w));
                let mut at = 0;
                for ((child, _), size) in children.iter().zip(sizes) {
                    let rect = match dir {
                        Dir::Row => Rect {
                            x: area.x + at,
                            w: size,
                            ..area
                        },
                        Dir::Column => Rect {
                            y: area.y + at,
                            h: size,
                            ..area
                        },
                    };
                    child.place(rect, out);
                    at += size + usize::from(*dir == Dir::Row);
                }
            }
        }
    }

    pub fn windows(&self) -> Vec<usize> {
        self.rects(Rect {
            w: 1000,
            h: 1000,
            ..Rect::default()
        })
        .into_iter()
        .map(|(id, _)| id)
        .collect()
    }

    /// Splits window `target`, putting `new` before or after it in
    /// direction `dir`. Returns false if `target` isn't in the layout.
    pub fn split(&mut self, target: usize, new: usize, dir: Dir, before: bool) -> bool {
        match self {
            Layout::Window(id) if *id == target => {
                let pair = if before {
                    vec![(Layout::Window(new), 1.0), (Layout::Window(target), 1.0)]
                } else {
                    vec![(Layout::Window(target), 1.0), (Layout::Window(new), 1.0)]
                };
                *self = Layout::Split(dir, pair);
                true
            }
            Layout::Window(_) => false,
            Layout::Split(d, children) => {
                // Splitting in the split's own direction adds a sibling, so
                // three :splits make three equal rows rather than halves of
                // halves.
                if *d == dir {
                    if let Some(i) = children
                        .iter()
                        .position(|(c, _)| *c == Layout::Window(target))
                    {
                        let weight = children[i].1;
                        children.insert(
                            if before { i } else { i + 1 },
                            (Layout::Window(new), weight),
                        );
                        return true;
                    }
                }
                children
                    .iter_mut()
                    .any(|(c, _)| c.split(target, new, dir, before))
            }
        }
    }

    /// Removes window `target`. A split left with one child becomes that
    /// child. Returns false if `target` is the only window.
    pub fn remove(&mut self, target: usize) -> bool {
        let Layout::Split(_, children) = self else {
            return false;
        };
        if let Some(i) = children
            .iter()
            .position(|(c, _)| *c == Layout::Window(target))
        {
            children.remove(i);
        } else if !children.iter_mut().any(|(c, _)| c.remove(target)) {
            return false;
        }
        if children.len() == 1 {
            *self = children.remove(0).0;
        }
        true
    }

    /// Makes every split share its space equally.
    pub fn equalize(&mut self) {
        if let Layout::Split(_, children) = self {
            for (child, weight) in children.iter_mut() {
                *weight = 1.0;
                child.equalize();
            }
        }
    }

    /// Grows (or with a negative `delta`, shrinks) window `target` by
    /// `delta` rows or columns in direction `dir`, taking the space from
    /// its neighbor. `size` is the space the split has to share.
    pub fn resize(&mut self, target: usize, dir: Dir, delta: isize, area: Rect) -> bool {
        let Layout::Split(d, children) = self else {
            return false;
        };
        let holds = |c: &Layout| c.windows().contains(&target);
        let Some(i) = children.iter().position(|(c, _)| holds(c)) else {
            return false;
        };
        if *d == dir && children.len() > 1 {
            let total = match dir {
                Dir::Row => area.w,
                Dir::Column => area.h,
            } as f64;
            let sum: f64 = children.iter().map(|(_, w)| w).sum();
            let per_cell = sum / total.max(1.0);
            let j = if i + 1 < children.len() { i + 1 } else { i - 1 };
            let change = delta as f64 * per_cell;
            // Keep both at least a row or two.
            let min = 2.0 * per_cell;
            let change = change.min(children[j].1 - min).max(-(children[i].1 - min));
            children[i].1 += change;
            children[j].1 -= change;
            return true;
        }
        let rects = Layout::Split(*d, children.clone()).child_rects(area);
        children[i].0.resize(target, dir, delta, rects[i])
    }

    /// The rectangle of each direct child of a split.
    fn child_rects(&self, area: Rect) -> Vec<Rect> {
        match self {
            Layout::Window(_) => vec![area],
            Layout::Split(dir, children) => {
                let n = children.len();
                let borders = if *dir == Dir::Row { n - 1 } else { 0 };
                let total = match dir {
                    Dir::Row => area.w.saturating_sub(borders),
                    Dir::Column => area.h,
                };
                let sizes = share(total, children.iter().map(|(_, w)| *w));
                let mut at = 0;
                sizes
                    .into_iter()
                    .map(|size| {
                        let r = match dir {
                            Dir::Row => Rect {
                                x: area.x + at,
                                w: size,
                                ..area
                            },
                            Dir::Column => Rect {
                                y: area.y + at,
                                h: size,
                                ..area
                            },
                        };
                        at += size + usize::from(*dir == Dir::Row);
                        r
                    })
                    .collect()
            }
        }
    }
}

/// Splits `total` cells by weight, giving any remainder to the last.
fn share(total: usize, weights: impl Iterator<Item = f64>) -> Vec<usize> {
    let weights: Vec<f64> = weights.collect();
    let sum: f64 = weights.iter().sum::<f64>().max(f64::EPSILON);
    let mut sizes: Vec<usize> = weights
        .iter()
        .map(|w| ((total as f64) * w / sum).floor() as usize)
        .collect();
    let used: usize = sizes.iter().sum();
    if let Some(last) = sizes.last_mut() {
        *last += total.saturating_sub(used);
    }
    sizes
}

#[cfg(test)]
mod tests {
    use super::*;

    fn area() -> Rect {
        Rect {
            x: 0,
            y: 0,
            w: 81,
            h: 20,
        }
    }

    #[test]
    fn splits_and_rects() {
        let mut l = Layout::Window(1);
        assert!(l.split(1, 2, Dir::Row, false));
        let r = l.rects(area());
        assert_eq!(
            r[0],
            (
                1,
                Rect {
                    x: 0,
                    y: 0,
                    w: 40,
                    h: 20
                }
            )
        );
        assert_eq!(
            r[1],
            (
                2,
                Rect {
                    x: 41,
                    y: 0,
                    w: 40,
                    h: 20
                }
            )
        );
        assert!(l.split(2, 3, Dir::Column, true));
        let r = l.rects(area());
        assert_eq!(
            r[1],
            (
                3,
                Rect {
                    x: 41,
                    y: 0,
                    w: 40,
                    h: 10
                }
            )
        );
        assert_eq!(
            r[2],
            (
                2,
                Rect {
                    x: 41,
                    y: 10,
                    w: 40,
                    h: 10
                }
            )
        );
    }

    #[test]
    fn same_direction_splits_are_siblings() {
        let mut l = Layout::Window(1);
        l.split(1, 2, Dir::Column, false);
        l.split(2, 3, Dir::Column, false);
        let r = l.rects(Rect { h: 21, ..area() });
        assert_eq!(r.iter().map(|(_, r)| r.h).collect::<Vec<_>>(), [7, 7, 7]);
    }

    #[test]
    fn remove_collapses() {
        let mut l = Layout::Window(1);
        l.split(1, 2, Dir::Row, false);
        l.split(2, 3, Dir::Column, false);
        assert!(l.remove(3));
        assert_eq!(l.windows(), [1, 2]);
        assert!(l.remove(1));
        assert_eq!(l, Layout::Window(2));
        assert!(!l.remove(2));
    }

    #[test]
    fn resize_moves_space_to_a_neighbor() {
        let mut l = Layout::Window(1);
        l.split(1, 2, Dir::Column, false);
        assert!(l.resize(1, Dir::Column, 4, area()));
        let r = l.rects(area());
        assert_eq!((r[0].1.h, r[1].1.h), (14, 6));
        l.equalize();
        assert_eq!(l.rects(area())[0].1.h, 10);
    }
}
