//! Turns editor state into a frame for the client.
//!
//! The screen is the windows (each with its own status line) and, on the
//! bottom row, the message line or the command line being typed. Windows
//! side by side are separated by a border column.

use std::collections::BTreeMap;

use imp_core::{Buffer, Frame, Row, Span, Style};
use unicode_width::UnicodeWidthChar;

use crate::editor::{window_mark, Editor, Layer};
use crate::layout::Rect;

/// How the gutter shows line numbers, set from Scheme (the `number` and
/// `relativenumber` options).
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub enum LineNumbers {
    #[default]
    Off,
    Absolute,
    Relative,
    /// Relative, but the cursor's line shows its own number.
    Hybrid,
}

pub fn frame(e: &mut Editor) -> Frame {
    let width = e.width.max(1) as usize;
    let height = e.height.max(2) as usize;
    let screen = e.layout.rects(e.windows_area());
    // Parse what changed in every buffer on screen before drawing.
    let shown: Vec<usize> = screen
        .iter()
        .map(|(id, _)| {
            if *id == e.current_window {
                e.current
            } else {
                e.windows[id].buffer
            }
        })
        .collect();
    for id in shown {
        e.update_syntax(id);
    }

    // Draw each window; scroll positions are worked out on the way and
    // stored afterwards.
    let mut segments: Vec<Vec<(usize, Row)>> = vec![Vec::new(); height];
    let mut cursor = (0, 0);
    let mut scrolls = Vec::new();
    for (id, rect) in &screen {
        let focused = *id == e.current_window;
        let drawn = draw_window(e, *id, *rect, focused, rect.x + rect.w < width);
        for (i, row) in drawn.rows.into_iter().enumerate() {
            if rect.y + i < height - 1 {
                segments[rect.y + i].push((rect.x, row));
            }
        }
        if focused {
            cursor = drawn.cursor;
        }
        scrolls.push((*id, drawn.scroll, drawn.hscroll));
    }
    for (id, scroll, hscroll) in scrolls {
        if id == e.current_window {
            e.scroll = scroll;
            e.hscroll = hscroll;
        } else if let Some(w) = e.windows.get_mut(&id) {
            w.scroll = scroll;
            w.hscroll = hscroll;
        }
    }

    let separator = e.face("separator");
    let mut rows: Vec<Row> = segments
        .into_iter()
        .take(height - 1)
        .map(|mut segs| {
            segs.sort_by_key(|(x, _)| *x);
            let mut row: Row = Vec::new();
            let mut at = 0;
            for (x, seg) in segs {
                if x > at {
                    push(&mut row, &"│".repeat(x - at), separator);
                }
                at = x + seg.iter().map(|s| text_width(&s.text)).sum::<usize>();
                for span in seg {
                    push(&mut row, &span.text, span.style);
                }
            }
            row
        })
        .collect();

    let area = height - 1;
    if !e.popup.is_empty() {
        match e.popup_at_cursor {
            None => bottom_popup(e, &mut rows, area, width),
            Some(dx) => cursor_popup(e, &mut rows, area, width, cursor, dx),
        }
    }

    match &e.cmdline {
        Some((text, col)) => {
            // Keep the cursor's end of a long command line in view.
            let skip = (col + 1).saturating_sub(width);
            let shown: String = text.chars().skip(skip).take(width).collect();
            rows.push(vec![Span::new(shown, Style::default())]);
            cursor = ((col - skip).min(width - 1), height - 1);
        }
        None => rows.push(vec![Span::new(clip(&e.status, width), Style::default())]),
    }

    // The theme's "normal" face is under everything; with a background,
    // rows are padded so it reaches the right edge.
    let normal = e.face("normal");
    if normal != Style::default() {
        for row in rows.iter_mut() {
            for span in row.iter_mut() {
                span.style = span.style.over(normal);
            }
            let used: usize = row.iter().map(|s| text_width(&s.text)).sum();
            if used < width && normal.bg.is_some() {
                push(row, &" ".repeat(width - used), normal);
            }
        }
    }

    Frame {
        rows,
        cursor: (cursor.0 as u16, cursor.1 as u16),
        cursor_shape: e.cursor_shape,
    }
}

/// A popup row `width` cells wide: its runs over the popup's face (or the
/// selected one), padded.
fn popup_row(e: &Editor, line: &[(String, String)], selected: bool, width: usize) -> Row {
    let base = e.face(if selected { "popup-selected" } else { "popup" });
    let mut row = Vec::new();
    let mut used = 0;
    for (text, face) in line {
        let style = if face.is_empty() {
            base
        } else {
            e.face(face).over(base)
        };
        let text = clip(text, width - used);
        used += text_width(&text);
        push(&mut row, &text, style);
        if used >= width {
            break;
        }
    }
    if used < width {
        push(&mut row, &" ".repeat(width - used), base);
    }
    row
}

/// A border row: `left`, the title (if any), `fill` to the width, `right`.
fn border_row(e: &Editor, left: &str, right: &str, width: usize) -> Row {
    let border = e.face("popup-border");
    let mut row = Vec::new();
    let inner = width.saturating_sub(text_width(left) + text_width(right));
    push(&mut row, left, border);
    let title = if e.popup_title.is_empty() {
        String::new()
    } else {
        clip(&format!(" {} ", e.popup_title), inner.saturating_sub(1))
    };
    let mut used = 0;
    if !title.is_empty() {
        push(&mut row, "─", border);
        push(&mut row, &title, e.face("popup-title").over(border));
        used = 1 + text_width(&title);
    }
    push(&mut row, &"─".repeat(inner.saturating_sub(used)), border);
    push(&mut row, right, border);
    row
}

/// The popup across the bottom of the screen, above the message line,
/// under a border with its title.
fn bottom_popup(e: &Editor, rows: &mut [Row], area: usize, width: usize) {
    let shown = e.popup.len().min(area.saturating_sub(1));
    let first = e.popup.len() - shown;
    let top = area - shown - 1;
    rows[top] = border_row(e, "", "", width);
    for (i, line) in e.popup[first..].iter().enumerate() {
        rows[top + 1 + i] = popup_row(e, line, e.popup_selected == Some(first + i), width);
    }
}

/// The popup in a box below the cursor, or above it when there is more
/// room there, `dx` columns from it.
fn cursor_popup(
    e: &Editor,
    rows: &mut [Row],
    area: usize,
    width: usize,
    cursor: (usize, usize),
    dx: isize,
) {
    let content = e
        .popup
        .iter()
        .map(|l| l.iter().map(|(t, _)| text_width(t)).sum::<usize>())
        .max()
        .unwrap_or(0)
        .max(text_width(&e.popup_title) + 3);
    let inner = (content + 2).min(width.saturating_sub(2)).max(1);
    let below = area.saturating_sub(cursor.1 + 1);
    let above = cursor.1;
    let fits_below = e.popup.len() + 2 <= below;
    let (room, under) = if fits_below || below >= above {
        (below, true)
    } else {
        (above, false)
    };
    if room < 3 {
        return;
    }
    let shown = e.popup.len().min(room - 2);
    let top = if under {
        cursor.1 + 1
    } else {
        cursor.1 - shown - 2
    };
    let x =
        (cursor.0 as isize + dx - 1).clamp(0, width.saturating_sub(inner + 2) as isize) as usize;
    let border = e.face("popup-border");
    rows[top] = splice(&rows[top], x, border_row(e, "╭", "╮", inner + 2), inner + 2);
    for i in 0..shown {
        let mut line = vec![(String::from(" "), String::new())];
        line.extend(e.popup[i].iter().cloned());
        let mut row = vec![Span::new("│", border)];
        row.extend(popup_row(e, &line, e.popup_selected == Some(i), inner));
        push(&mut row, "│", border);
        rows[top + 1 + i] = splice(&rows[top + 1 + i], x, row, inner + 2);
    }
    let bottom = top + shown + 1;
    let mut row = vec![Span::new("╰", border)];
    push(&mut row, &"─".repeat(inner), border);
    push(&mut row, "╯", border);
    rows[bottom] = splice(&rows[bottom], x, row, inner + 2);
}

/// `row` with cells `x..x + width` replaced by `insert`. A wide char cut
/// in half becomes spaces.
fn splice(row: &Row, x: usize, insert: Row, width: usize) -> Row {
    let mut out = Vec::new();
    let mut at = 0;
    for span in row {
        for ch in span.text.chars() {
            let w = ch.width().unwrap_or(0);
            if at + w <= x {
                push(&mut out, &ch.to_string(), span.style);
            } else if at < x {
                push(&mut out, &" ".repeat(x - at), span.style);
            }
            at += w;
            if at >= x {
                break;
            }
        }
        if at >= x {
            break;
        }
    }
    if at < x {
        push(&mut out, &" ".repeat(x - at), Style::default());
    }
    for span in insert {
        push(&mut out, &span.text, span.style);
    }
    let end = x + width;
    let mut at = 0;
    for span in row {
        for ch in span.text.chars() {
            let w = ch.width().unwrap_or(0);
            if at >= end {
                push(&mut out, &ch.to_string(), span.style);
            } else if at + w > end {
                push(&mut out, &" ".repeat(at + w - end), span.style);
            }
            at += w;
        }
    }
    out
}

struct DrawnWindow {
    rows: Vec<Row>,
    cursor: (usize, usize),
    scroll: usize,
    hscroll: usize,
}

/// A buffer's closed folds: (first, last) lines, sorted, not nested. A
/// closed fold shows as its first line.
#[derive(Clone, Copy)]
struct Folds<'a>(&'a [(usize, usize)]);

impl Folds<'_> {
    fn of(e: &Editor, buffer_id: usize) -> Folds<'_> {
        Folds(e.folds.get(&buffer_id).map_or(&[], Vec::as_slice))
    }

    fn at(self, line: usize) -> Option<(usize, usize)> {
        self.0
            .iter()
            .copied()
            .find(|&(a, b)| a <= line && line <= b)
    }

    /// The line `line` shows on: its fold's first line, or itself.
    fn shown(self, line: usize) -> usize {
        self.at(line).map_or(line, |(a, _)| a)
    }

    /// The shown line after `line`'s.
    fn next(self, line: usize) -> usize {
        self.at(line).map_or(line, |(_, b)| b) + 1
    }

    /// Whether at most `limit` shown lines run from `a` to `b`.
    fn within(self, a: usize, b: usize, limit: usize) -> bool {
        let (mut line, mut n) = (a, 0);
        while line <= b {
            n += 1;
            if n > limit {
                return false;
            }
            line = self.next(line);
        }
        true
    }

    /// Shown lines between `a` and `b`, as `j` would count them.
    fn distance(self, a: usize, b: usize) -> usize {
        let (from, to) = (self.shown(a.min(b)), self.shown(a.max(b)));
        let (mut line, mut n) = (from, 0);
        while line < to {
            n += 1;
            line = self.next(line);
        }
        n
    }
}

/// Everything about one window's view needed to draw it.
struct View<'a> {
    e: &'a Editor,
    buffer: &'a Buffer,
    /// Syntax highlights near the visible rows: (start, end, faces to try).
    syntax: Vec<(usize, usize, &'static [String])>,
    /// Whether this window shows the current buffer, whose highlight
    /// ranges (selection) apply.
    current_buffer: bool,
    /// The buffer's own highlight layers.
    buffer_layers: &'a [Layer],
    /// The buffer's gutter signs, if it has any.
    signs: Option<&'a BTreeMap<usize, (String, String)>>,
    folds: Folds<'a>,
    cursor_line: usize,
    gutter: usize,
    text_width: usize,
    hscroll: usize,
}

fn draw_window(e: &Editor, id: usize, rect: Rect, focused: bool, pad: bool) -> DrawnWindow {
    let (buffer_id, mut scroll, mut hscroll) = if focused {
        (e.current, e.scroll, e.hscroll)
    } else {
        let w = &e.windows[&id];
        (w.buffer, w.scroll, w.hscroll)
    };
    let buffer = e.buffer_by_id(buffer_id).unwrap_or(&e.buffer);
    let cursor = if focused {
        e.cursor
    } else {
        buffer.mark(&window_mark(id)).unwrap_or(0)
    }
    .min(buffer.len());
    let text_rows = rect.h.saturating_sub(1).max(1);
    let folds = Folds::of(e, buffer_id);
    let real_line = buffer.offset_to_line(cursor);
    let cursor_col = buffer.offset_to_col(cursor);
    // In a closed fold the cursor shows at the start of the fold's line.
    let folded = folds.at(real_line).is_some();
    let cursor_line = folds.shown(real_line);
    let gutter = gutter_width(e, buffer_id, buffer);
    let text_width = rect.w.saturating_sub(gutter).max(1);

    // Where the cursor is within its line: (row, x) with wrap, (0, x)
    // without.
    let cursor_cells = layout_line(&buffer.line_text(cursor_line), e.tab_width);
    let (cursor_row, cursor_x) = if folded {
        (0, 0)
    } else {
        cursor_position(&cursor_cells, cursor_col, e.wrap, text_width)
    };

    // Scroll just enough to keep the cursor in view.
    scroll = folds.shown(scroll);
    if cursor_line < scroll {
        scroll = cursor_line;
    }
    if e.wrap {
        hscroll = 0;
        // Walk back from the cursor's line to find the highest line that
        // still leaves the cursor on screen; that bounds the work by the
        // window's height, however far the cursor jumped.
        let mut top = cursor_line;
        let mut used = cursor_row + 1;
        while top > scroll {
            let prev = folds.shown(top - 1);
            let rows = if folds.at(prev).is_some() {
                1
            } else {
                line_rows(
                    &layout_line(&buffer.line_text(prev), e.tab_width),
                    text_width,
                )
            };
            if used + rows > text_rows {
                break;
            }
            used += rows;
            top = prev;
        }
        scroll = scroll.max(top);
    } else {
        if !folds.within(scroll, cursor_line, text_rows) {
            scroll = cursor_line;
            for _ in 1..text_rows {
                if scroll == 0 {
                    break;
                }
                scroll = folds.shown(scroll - 1);
            }
        }
        if cursor_x < hscroll {
            hscroll = cursor_x;
        } else if cursor_x >= hscroll + text_width {
            hscroll = cursor_x + 1 - text_width;
        }
    }

    // Syntax highlights for about the rows on screen.
    let syntax = e.syntax.get(&buffer_id).map(|s| {
        let rope = buffer.rope();
        let mut end = scroll;
        for _ in 0..=text_rows {
            end = folds.next(end);
        }
        let first = rope.line_to_byte(scroll.min(rope.len_lines()));
        let last = rope.line_to_byte(end.min(rope.len_lines()));
        s.highlights(rope, first..last)
    });
    let view = View {
        e,
        buffer,
        syntax: syntax.unwrap_or_default(),
        current_buffer: buffer_id == e.current,
        buffer_layers: e.buffer_layers.get(&buffer_id).map_or(&[], Vec::as_slice),
        signs: e.signs.get(&buffer_id).filter(|s| !s.is_empty()),
        folds,
        cursor_line,
        gutter,
        text_width,
        hscroll,
    };
    let mut rows: Vec<Row> = Vec::with_capacity(rect.h);
    let mut cursor_screen = (rect.x, rect.y);
    let mut line = scroll;
    while rows.len() < text_rows {
        if line >= buffer.line_count() {
            rows.push(fill(vec![Span::new("~", e.face("nontext"))], rect.w, pad));
            continue;
        }
        if let Some((first, last)) = folds.at(line) {
            // A closed fold: its first line and how many lines it holds.
            let mut row = view.line_rows(first).into_iter().next().unwrap_or_default();
            let note = format!(" ··· {} lines", last - first + 1);
            let used: usize = row.iter().map(|s| self::text_width(&s.text)).sum();
            if used + self::text_width(&note) <= rect.w {
                push(&mut row, &note, e.face("fold"));
            }
            if first == cursor_line {
                cursor_screen = (rect.x + gutter, rect.y + rows.len());
            }
            rows.push(fill(row, rect.w, pad));
            line = last + 1;
            continue;
        }
        let line_rows = view.line_rows(line);
        if line == cursor_line {
            cursor_screen = (
                rect.x + gutter + cursor_x.saturating_sub(hscroll).min(text_width - 1),
                rect.y + rows.len() + cursor_row.min(line_rows.len() - 1),
            );
        }
        for row in line_rows {
            if rows.len() < text_rows {
                rows.push(fill(row, rect.w, pad));
            }
        }
        line += 1;
    }
    rows.push(status_line(
        e, buffer_id, buffer, focused, real_line, cursor_col, rect.w,
    ));
    DrawnWindow {
        rows,
        cursor: cursor_screen,
        scroll,
        hscroll,
    }
}

/// Pads a row to `width` cells when something is drawn to its right.
fn fill(mut row: Row, width: usize, pad: bool) -> Row {
    if pad {
        let used: usize = row.iter().map(|s| text_width(&s.text)).sum();
        if used < width {
            push(&mut row, &" ".repeat(width - used), Style::default());
        }
    }
    row
}

/// A char of a line as laid out: its index, the char, its display column
/// in the unwrapped line, and how many cells it takes (tabs expand, wide
/// chars take two, combining marks none).
struct Cell {
    index: usize,
    ch: char,
    x: usize,
    w: usize,
}

fn layout_line(text: &str, tab_width: usize) -> Vec<Cell> {
    let mut x = 0;
    text.chars()
        .enumerate()
        .map(|(index, ch)| {
            let w = if ch == '\t' {
                tab_width - x % tab_width
            } else {
                ch.width().unwrap_or(0)
            };
            let cell = Cell { index, ch, x, w };
            x += w;
            cell
        })
        .collect()
}

/// With wrap, which row of the line each cell is on and its column there:
/// a cell that doesn't fit moves to the next row whole.
fn wrapped(cells: &[Cell], width: usize) -> Vec<(usize, usize)> {
    let mut row = 0;
    let mut col = 0;
    cells
        .iter()
        .map(|c| {
            if col + c.w > width && col > 0 {
                row += 1;
                col = 0;
            }
            let at = (row, col);
            col += c.w;
            at
        })
        .collect()
}

/// How many screen rows a line takes with wrap.
fn line_rows(cells: &[Cell], width: usize) -> usize {
    wrapped(cells, width).last().map_or(1, |(row, _)| row + 1)
}

/// The cursor's (row, x) in its line. Past the last char (insert mode),
/// it sits just after it, on the next row if that row is full.
fn cursor_position(cells: &[Cell], col: usize, wrap: bool, width: usize) -> (usize, usize) {
    if !wrap {
        let x = cells
            .get(col)
            .map_or_else(|| cells.last().map_or(0, |c| c.x + c.w), |c| c.x);
        return (0, x);
    }
    let at = wrapped(cells, width);
    match (at.get(col), at.last(), cells.last()) {
        (Some(&(row, x)), _, _) => (row, x),
        (None, Some(&(row, x)), Some(last)) => {
            let end = x + last.w;
            if end >= width {
                (row + 1, 0)
            } else {
                (row, end)
            }
        }
        _ => (0, 0),
    }
}

impl View<'_> {
    /// The screen rows for buffer line `line`, with its gutter.
    fn line_rows(&self, line: usize) -> Vec<Row> {
        let e = self.e;
        let start = self.buffer.line_col_to_offset(line, 0);
        let text = self.buffer.line_text(line);
        let cells = layout_line(&text, e.tab_width);
        let mut styles = char_styles(
            e,
            start,
            &text,
            self.current_buffer,
            self.buffer_layers,
            &self.syntax,
        );
        let cursorline = e.cursorline && line == self.cursor_line;
        if cursorline {
            let face = e.face("cursorline");
            for s in &mut styles {
                *s = s.over(face);
            }
        }
        let eol_style = styles[cells.len()];

        let mut rows: Vec<Row> = Vec::new();
        if e.wrap {
            let at = wrapped(&cells, self.text_width);
            let count = at.last().map_or(1, |(r, _)| r + 1);
            rows.resize(count, Vec::new());
            for (cell, &(r, _)) in cells.iter().zip(&at) {
                push_cell(&mut rows[r], cell, cell.w, &styles);
            }
            let end = at.last().map_or(0, |&(_, x)| x) + cells.last().map_or(0, |c| c.w);
            if eol_style != Style::default() && end < self.text_width {
                push(rows.last_mut().expect("one row"), " ", eol_style);
            }
        } else {
            let (left, right) = (self.hscroll, self.hscroll + self.text_width);
            let mut row: Row = Vec::new();
            let mut x_end = 0;
            for cell in &cells {
                x_end = cell.x + cell.w;
                // The cells of this char inside the window.
                let visible = (cell.x.max(left)..x_end.min(right)).len();
                if cell.w == 0 && cell.x >= left && cell.x < right {
                    push_cell(&mut row, cell, 0, &styles);
                } else if visible == cell.w {
                    push_cell(&mut row, cell, visible, &styles);
                } else if visible > 0 {
                    // A wide char cut by the window's edge.
                    push(&mut row, &" ".repeat(visible), styles[cell.index]);
                }
                if x_end >= right {
                    break;
                }
            }
            if eol_style != Style::default() && x_end >= left && x_end < right {
                push(&mut row, " ", eol_style);
            }
            rows.push(row);
        }

        let gutter_face = if line == self.cursor_line {
            e.face("line-number-current")
        } else {
            e.face("line-number")
        };
        rows.into_iter()
            .enumerate()
            .map(|(i, text_row)| {
                let mut row = Vec::new();
                let mut numbers = self.gutter;
                if let Some(signs) = self.signs {
                    numbers -= SIGN_WIDTH;
                    match signs.get(&line).filter(|_| i == 0) {
                        Some((text, face)) => {
                            let text: String = text.chars().take(SIGN_WIDTH).collect();
                            let pad = SIGN_WIDTH.saturating_sub(text_width(&text));
                            row.push(Span::new(
                                format!("{text}{}", " ".repeat(pad)),
                                e.face(face),
                            ));
                        }
                        None => row.push(Span::new(" ".repeat(SIGN_WIDTH), e.face("sign-column"))),
                    }
                }
                if numbers > 0 {
                    row.push(if i == 0 {
                        Span::new(
                            gutter_text(
                                e,
                                line,
                                self.cursor_line,
                                self.folds.distance(line, self.cursor_line),
                                numbers,
                            ),
                            gutter_face,
                        )
                    } else {
                        Span::new(" ".repeat(numbers), gutter_face)
                    });
                }
                let used: usize = text_row.iter().map(|s| text_width(&s.text)).sum();
                row.extend(text_row);
                // The cursor line's face runs to the window's edge.
                if cursorline && used < self.text_width {
                    push(
                        &mut row,
                        &" ".repeat(self.text_width - used),
                        e.face("cursorline"),
                    );
                }
                row
            })
            .collect()
    }
}

fn push_cell(row: &mut Row, cell: &Cell, shown: usize, styles: &[Style]) {
    let text = if cell.ch == '\t' {
        " ".repeat(shown)
    } else {
        cell.ch.to_string()
    };
    push(row, &text, styles[cell.index]);
}

/// Cells of the sign column, when a buffer has signs.
const SIGN_WIDTH: usize = 2;

fn gutter_width(e: &Editor, buffer_id: usize, buffer: &Buffer) -> usize {
    let signs = if e.signs.get(&buffer_id).is_some_and(|s| !s.is_empty()) {
        SIGN_WIDTH
    } else {
        0
    };
    if e.line_numbers == LineNumbers::Off {
        return signs;
    }
    let digits = buffer.line_count().to_string().len();
    signs + digits.max(3) + 1
}

/// `distance` is how far `line` is from the cursor's, counting a closed
/// fold as one line.
fn gutter_text(
    e: &Editor,
    line: usize,
    cursor_line: usize,
    distance: usize,
    gutter: usize,
) -> String {
    let n = match e.line_numbers {
        LineNumbers::Absolute => line + 1,
        LineNumbers::Hybrid if line == cursor_line => line + 1,
        _ => distance,
    };
    // Hybrid numbers sit left on the cursor's line, as in Vim.
    if e.line_numbers == LineNumbers::Hybrid && line == cursor_line {
        format!("{:<w$} ", n, w = gutter - 1)
    } else {
        format!("{:>w$} ", n, w = gutter - 1)
    }
}

/// The style of each char of `text`, the line starting at offset `start`,
/// plus one more entry for its line break. Global highlight ranges are
/// offsets into the current buffer, so they only apply to windows showing
/// it; global patterns (search) apply everywhere. A buffer's own layers
/// apply wherever it is shown.
fn char_styles(
    e: &Editor,
    start: usize,
    text: &str,
    current_buffer: bool,
    buffer_layers: &[Layer],
    syntax: &[(usize, usize, &'static [String])],
) -> Vec<Style> {
    let len = text.chars().count();
    let mut styles = vec![Style::default(); len + 1];
    let end = start + len + 1;
    // Syntax first, underneath everything; where captures overlap the
    // first one to paint a char keeps it.
    let mut painted = vec![false; len + 1];
    for (s, t, faces) in syntax {
        if *t <= start || *s >= end {
            continue;
        }
        let Some(face) = faces.iter().find_map(|f| e.faces.get(f)) else {
            continue;
        };
        for i in s.max(&start) - start..t.min(&end) - start {
            if !painted[i] {
                styles[i] = *face;
                painted[i] = true;
            }
        }
    }
    let layers = e
        .layers
        .iter()
        .map(|l| (l, current_buffer))
        .chain(buffer_layers.iter().map(|l| (l, true)));
    for (layer, ranges_apply) in layers {
        if ranges_apply {
            for h in &layer.ranges {
                if h.end <= start || h.start >= end {
                    continue;
                }
                let face = e.face(&h.face);
                let from = h.start.max(start) - start;
                let to = h.end.min(end) - start;
                for style in &mut styles[from..to] {
                    *style = face.over(*style);
                }
            }
        }
        if let Some((re, face)) = &layer.pattern {
            let face = e.face(face);
            for m in re.find_iter(text) {
                let from = text[..m.start()].chars().count();
                let to = from + m.as_str().chars().count();
                for style in &mut styles[from..to] {
                    *style = face.over(*style);
                }
            }
        }
    }
    styles
}

/// Appends text to a row, merging it into the last span if the style matches.
fn push(row: &mut Row, text: &str, style: Style) {
    match row.last_mut() {
        Some(last) if last.style == style => last.text.push_str(text),
        _ => row.push(Span::new(text, style)),
    }
}

/// The display column of char column `col` on `line` of the current
/// buffer (tabs and wide chars counted).
pub fn display_col(e: &Editor, line: usize, col: usize) -> usize {
    let cells = layout_line(&e.buffer.line_text(line), e.tab_width);
    cells
        .get(col)
        .map_or_else(|| cells.last().map_or(0, |c| c.x + c.w), |c| c.x)
}

/// The char column on `line` that covers display column `x`, or the end
/// of the line.
pub fn col_at_display(e: &Editor, line: usize, x: usize) -> usize {
    let cells = layout_line(&e.buffer.line_text(line), e.tab_width);
    cells
        .iter()
        .position(|c| x < c.x + c.w.max(1))
        .unwrap_or(cells.len())
}

/// Columns for text in the current window: its width less the gutter.
pub fn window_text_width(e: &Editor) -> usize {
    let rect = e.window_rect(e.current_window);
    rect.w
        .saturating_sub(gutter_width(e, e.current, &e.buffer))
        .max(1)
}

/// Display width of a string.
fn text_width(text: &str) -> usize {
    text.chars().map(|c| c.width().unwrap_or(0)).sum()
}

/// `text` cut to `width` display cells.
fn clip(text: &str, width: usize) -> String {
    let mut used = 0;
    text.chars()
        .take_while(|c| {
            used += c.width().unwrap_or(0);
            used <= width
        })
        .collect()
}

/// A window's status line, from the `statusline` format (or
/// `statusline_inactive` for windows without focus), as Vim's: text, and
///
///   %m mode   %f buffer name   %F path   %M ● when modified
///   %l line   %c column   %L lines   %p percent through the buffer
///   %{name}   a value set from Scheme for the buffer (or globally); it
///             may hold %# items itself
///   %#face#   draw what follows with `face` (%#mode#: the mode's face)
///   %*        back to the status line's own face
///   %=        what follows goes on the right
///   %%        a %
///
/// When it doesn't fit, `%{...}` values on the right go first, then the
/// left is cut short; the end of the right side (the position) stays.
fn status_line(
    e: &Editor,
    buffer_id: usize,
    buffer: &Buffer,
    focused: bool,
    line: usize,
    col: usize,
    width: usize,
) -> Row {
    let base = e.face(if focused { "status" } else { "status-inactive" });
    let format = match (
        focused,
        e.statusline.as_str(),
        e.statusline_inactive.as_str(),
    ) {
        (true, "", _) => " %m | %f%M%=%{major}  %l:%c ",
        (false, _, "") => " %f%M%=%l:%c ",
        (true, f, _) => f,
        (false, _, f) => f,
    };
    let render = |drop_values: bool, trim_file: usize| {
        let mut status = Status {
            e,
            buffer_id,
            buffer,
            focused,
            line,
            col,
            base,
            style: base,
            left: Vec::new(),
            right: Vec::new(),
            on_right: false,
            drop_values,
            trim_file,
        };
        status.expand(format, 0);
        (status.left, status.right)
    };
    let row_width = |row: &Row| row.iter().map(|s| text_width(&s.text)).sum::<usize>();
    // Too long: first shorten the file name from its start (as Vim does),
    // then also leave out values on the right.
    let over =
        |(left, right): &(Row, Row)| (row_width(left) + row_width(right)).saturating_sub(width);
    let mut parts = render(false, 0);
    for drop_values in [false, true] {
        if drop_values {
            parts = render(true, 0);
        }
        if over(&parts) > 0 {
            parts = render(drop_values, over(&parts));
        }
        if over(&parts) == 0 {
            break;
        }
    }
    let (left, right) = parts;
    let right = clip_row_end(&right, width);
    let room = width - row_width(&right);
    let mut row = clip_row(&left, room);
    let used = row_width(&row);
    push(&mut row, &" ".repeat(room - used), base);
    for span in right {
        push(&mut row, &span.text, span.style);
    }
    row
}

/// `name` with `cells` taken off its start, marked with "<" as in Vim. The
/// file name itself (after the last "/") is kept whole.
fn trim_start(name: &str, cells: usize) -> String {
    if cells == 0 {
        return name.to_string();
    }
    let keep = text_width(name).saturating_sub(cells + 1);
    let base = name.rsplit('/').next().unwrap_or(name);
    if keep <= text_width(base) {
        return if base.len() < name.len() {
            format!("<{base}")
        } else {
            name.to_string()
        };
    }
    let mut start = name.len();
    let mut used = 0;
    for (i, ch) in name.char_indices().rev() {
        let w = ch.width().unwrap_or(0);
        if used + w > keep {
            break;
        }
        used += w;
        start = i;
    }
    format!("<{}", &name[start..])
}

/// The last `width` cells of a row.
fn clip_row_end(row: &Row, width: usize) -> Row {
    let total: usize = row.iter().map(|s| text_width(&s.text)).sum();
    let mut skip = total.saturating_sub(width);
    let mut out = Vec::new();
    for span in row {
        let mut text = String::new();
        for ch in span.text.chars() {
            let w = ch.width().unwrap_or(0);
            if skip >= w && skip > 0 {
                skip -= w;
            } else if skip > 0 {
                text.push(' ');
                skip = 0;
            } else {
                text.push(ch);
            }
        }
        push(&mut out, &text, span.style);
    }
    out
}

struct Status<'a> {
    e: &'a Editor,
    buffer_id: usize,
    buffer: &'a Buffer,
    focused: bool,
    line: usize,
    col: usize,
    base: Style,
    style: Style,
    left: Row,
    right: Row,
    on_right: bool,
    /// Leave out %{...} values on the right, to make room.
    drop_values: bool,
    /// Cells to take off the start of %f and %F, to make room.
    trim_file: usize,
}

impl Status<'_> {
    fn add(&mut self, text: &str) {
        let side = if self.on_right {
            &mut self.right
        } else {
            &mut self.left
        };
        push(side, text, self.style);
    }

    fn value(&self, name: &str) -> Option<String> {
        let values = &self.e.status_values;
        values
            .get(&self.buffer_id)
            .and_then(|v| v.get(name))
            .or_else(|| values.get(&usize::MAX).and_then(|v| v.get(name)))
            .cloned()
    }

    fn expand(&mut self, format: &str, depth: usize) {
        let mut chars = format.chars();
        while let Some(c) = chars.next() {
            if c != '%' {
                self.add(&c.to_string());
                continue;
            }
            match chars.next() {
                Some('m') if self.focused => {
                    let mode = self.e.mode_name.clone();
                    self.add(&mode)
                }
                Some('m') => {}
                Some('f') => {
                    let name = trim_start(&self.buffer.display_name(), self.trim_file);
                    self.add(&name)
                }
                Some('F') => {
                    let path = self
                        .buffer
                        .path()
                        .map_or_else(|| self.buffer.display_name(), |p| p.display().to_string());
                    self.add(&trim_start(&path, self.trim_file))
                }
                Some('M') if self.buffer.is_modified() => self.add("●"),
                Some('M') => {}
                Some('l') => self.add(&(self.line + 1).to_string()),
                Some('c') => self.add(&(self.col + 1).to_string()),
                Some('L') => self.add(&self.buffer.line_count().to_string()),
                Some('p') => {
                    let pct = (self.line + 1) * 100 / self.buffer.line_count().max(1);
                    self.add(&format!("{pct}%"))
                }
                Some('=') => self.on_right = true,
                Some('*') => self.style = self.base,
                Some('%') => self.add("%"),
                Some('#') => {
                    let name: String = chars.by_ref().take_while(|&c| c != '#').collect();
                    let name = if name == "mode" {
                        self.e.mode_face.clone()
                    } else {
                        name
                    };
                    self.style = if self.focused || !name.starts_with("status.mode") {
                        self.e.face(&name).over(self.base)
                    } else {
                        self.base
                    };
                }
                Some('{') => {
                    let name: String = chars.by_ref().take_while(|&c| c != '}').collect();
                    if let Some(value) = self.value(&name) {
                        if depth < 2 && !(self.drop_values && self.on_right) {
                            self.expand(&value, depth + 1);
                        }
                    }
                }
                Some(other) => self.add(&format!("%{other}")),
                None => self.add("%"),
            }
        }
    }
}

/// The first `width` cells of a row.
fn clip_row(row: &Row, width: usize) -> Row {
    let mut out = Vec::new();
    let mut used = 0;
    for span in row {
        let text = clip(&span.text, width - used);
        used += text_width(&text);
        push(&mut out, &text, span.style);
        if used >= width {
            break;
        }
    }
    out
}

/// What is at screen cell (`x`, `y`): the window there, and the buffer
/// offset under the cell, or `None` on its status line. Clicking past a
/// line's end gives the end of that screen row. Uses the scroll positions
/// of the last frame drawn.
pub fn screen_position(e: &Editor, x: usize, y: usize) -> Option<(usize, Option<usize>)> {
    let (id, rect) = e
        .layout
        .rects(e.windows_area())
        .into_iter()
        .find(|(_, r)| x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h)?;
    if y + 1 == rect.y + rect.h {
        return Some((id, None));
    }
    let (buffer_id, scroll, hscroll) = if id == e.current_window {
        (e.current, e.scroll, e.hscroll)
    } else {
        let w = &e.windows[&id];
        (w.buffer, w.scroll, w.hscroll)
    };
    let buffer = e.buffer_by_id(buffer_id).unwrap_or(&e.buffer);
    let gutter = gutter_width(e, buffer_id, buffer);
    let width = rect.w.saturating_sub(gutter).max(1);
    let dx = (x - rect.x).saturating_sub(gutter);
    let mut row = y - rect.y;
    let folds = Folds::of(e, buffer_id);
    let mut line = folds.shown(scroll);
    while line < buffer.line_count() {
        let start = buffer.line_col_to_offset(line, 0);
        if let Some((_, last)) = folds.at(line) {
            if row == 0 {
                return Some((id, Some(start)));
            }
            row -= 1;
            line = last + 1;
            continue;
        }
        let cells = layout_line(&buffer.line_text(line), e.tab_width);
        if !e.wrap {
            if row == 0 {
                let at = dx + hscroll;
                let col = cells
                    .iter()
                    .position(|c| at < c.x + c.w.max(1))
                    .unwrap_or(cells.len());
                return Some((id, Some(start + col)));
            }
        } else {
            let at = wrapped(&cells, width);
            let rows = at.last().map_or(1, |(r, _)| r + 1);
            if row < rows {
                // The cell under the click, or the last one on that row.
                let on_row: Vec<usize> = (0..cells.len()).filter(|&i| at[i].0 == row).collect();
                let col = on_row
                    .iter()
                    .copied()
                    .find(|&i| dx < at[i].1 + cells[i].w.max(1))
                    .or_else(|| on_row.last().map(|&i| i + 1).filter(|&i| i < cells.len()))
                    .unwrap_or(cells.len());
                return Some((id, Some(start + col)));
            }
            row -= rows;
            line += 1;
            continue;
        }
        row -= 1;
        line += 1;
    }
    Some((id, Some(buffer.len())))
}
