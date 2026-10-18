//! Turns editor state into a frame for the client.

use imp_core::{Frame, Row, Span, Style};

use crate::editor::Editor;

pub fn frame(e: &mut Editor) -> Frame {
    let width = e.width.max(1) as usize;
    let text_rows = e.text_rows();

    let cursor_line = e.buffer.offset_to_line(e.cursor);
    let cursor_col = e.buffer.offset_to_col(e.cursor);

    // Scroll just enough to keep the cursor on screen.
    if cursor_line < e.scroll {
        e.scroll = cursor_line;
    } else if cursor_line >= e.scroll + text_rows {
        e.scroll = cursor_line + 1 - text_rows;
    }

    // The line-number gutter, then the text area. Lines don't wrap; the
    // text scrolls sideways to keep the cursor in view.
    let gutter = gutter_width(e);
    let text_width = width.saturating_sub(gutter).max(1);
    let cursor_x = display_col(&e.buffer.line_text(cursor_line), cursor_col, e.tab_width);
    if cursor_x < e.hscroll {
        e.hscroll = cursor_x;
    } else if cursor_x >= e.hscroll + text_width {
        e.hscroll = cursor_x + 1 - text_width;
    }

    let mut rows = Vec::with_capacity(text_rows + 1);
    for row in 0..text_rows {
        let line = e.scroll + row;
        if line >= e.buffer.line_count() {
            rows.push(vec![Span::new("~", e.face("nontext"))]);
            continue;
        }
        let mut spans = gutter_spans(e, line, cursor_line, gutter);
        let (text, _) = line_row(e, line, text_width, line == cursor_line);
        spans.extend(text);
        rows.push(spans);
    }
    // The popup covers the bottom rows of the window.
    let shown = e.popup.len().min(text_rows);
    let first = e.popup.len() - shown;
    for (i, line) in e.popup[first..].iter().enumerate() {
        let text: String = line.chars().take(width).collect();
        let pad = width.saturating_sub(text.chars().count());
        let face = if e.popup_selected == Some(first + i) {
            e.face("popup-selected")
        } else {
            e.face("popup")
        };
        rows[text_rows - shown + i] = vec![Span::new(text + &" ".repeat(pad), face)];
    }
    let mut cursor = (
        (gutter + cursor_x - e.hscroll).min(width - 1) as u16,
        (cursor_line - e.scroll) as u16,
    );
    match &e.cmdline {
        Some((text, col)) => {
            // Keep the cursor's end of a long command line in view.
            let skip = (col + 1).saturating_sub(width);
            let shown: String = text.chars().skip(skip).take(width).collect();
            rows.push(vec![Span::new(shown, Style::default())]);
            cursor = ((col - skip).min(width - 1) as u16, text_rows as u16);
        }
        None => rows.push(status_line(e, cursor_line, cursor_col, width)),
    }

    Frame {
        rows,
        cursor,
        cursor_shape: e.cursor_shape,
    }
}

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

fn gutter_width(e: &Editor) -> usize {
    if e.line_numbers == LineNumbers::Off {
        return 0;
    }
    let digits = e.buffer.line_count().to_string().len();
    digits.max(3) + 1
}

fn gutter_spans(e: &Editor, line: usize, cursor_line: usize, gutter: usize) -> Row {
    if gutter == 0 {
        return Vec::new();
    }
    let n = match e.line_numbers {
        LineNumbers::Absolute => line + 1,
        LineNumbers::Hybrid if line == cursor_line => line + 1,
        _ => line.abs_diff(cursor_line),
    };
    let face = if line == cursor_line {
        e.face("line-number-current")
    } else {
        e.face("line-number")
    };
    // Hybrid numbers sit left on the cursor's line, as in Vim.
    let text = if e.line_numbers == LineNumbers::Hybrid && line == cursor_line {
        format!("{:<w$} ", n, w = gutter - 1)
    } else {
        format!("{:>w$} ", n, w = gutter - 1)
    };
    vec![Span::new(text, face)]
}

/// The display column of char column `col` in `text`, counting tabs.
fn display_col(text: &str, col: usize, tab_width: usize) -> usize {
    let mut x = 0;
    for c in text.chars().take(col) {
        x += if c == '\t' {
            tab_width - x % tab_width
        } else {
            1
        };
    }
    x
}

/// Draws buffer line `line`: the display columns from `e.hscroll` on,
/// `width` of them.
fn line_row(e: &Editor, line: usize, width: usize, is_cursor_line: bool) -> (Row, usize) {
    let start = e.buffer.line_col_to_offset(line, 0);
    let text = e.buffer.line_text(line);
    let mut styles = char_styles(e, start, &text);
    if is_cursor_line && e.cursorline {
        let face = e.face("cursorline");
        for s in &mut styles {
            *s = s.over(face);
        }
    }

    let (left, right) = (e.hscroll, e.hscroll + width);
    let mut row: Row = Vec::new();
    let mut x = 0;
    for (i, c) in text.chars().enumerate() {
        let n = if c == '\t' {
            e.tab_width - x % e.tab_width
        } else {
            1
        };
        // Each display cell of the char that falls inside the window.
        let visible = (x.max(left)..(x + n).min(right)).len();
        if visible > 0 {
            let shown = if c == '\t' {
                " ".repeat(visible)
            } else {
                c.to_string()
            };
            push(&mut row, &shown, styles[i]);
        }
        x += n;
        if x >= right {
            break;
        }
    }
    // A selection that takes in the line break shows as one highlighted cell
    // past the end of the line, as in Vim, so selected empty lines are visible.
    let eol = styles[text.chars().count()];
    if eol != Style::default() && x >= left && x < right {
        push(&mut row, " ", eol);
    }
    // The cursor line's face runs to the window's edge.
    if is_cursor_line && e.cursorline {
        let used: usize = row.iter().map(|s| s.text.chars().count()).sum();
        if used < width {
            push(&mut row, &" ".repeat(width - used), e.face("cursorline"));
        }
    }
    (row, x)
}

/// The style of each char of `text`, the line starting at offset `start`,
/// plus one more entry for its line break.
fn char_styles(e: &Editor, start: usize, text: &str) -> Vec<Style> {
    let len = text.chars().count();
    let mut styles = vec![Style::default(); len + 1];
    let end = start + len + 1;
    for layer in &e.layers {
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

fn status_line(e: &Editor, line: usize, col: usize, width: usize) -> Row {
    let name = e.buffer.display_name();
    let modified = if e.buffer.is_modified() { " [+]" } else { "" };
    let left = format!(" {} | {name}{modified} | {}", e.mode_name, e.status);
    let right = format!("{}:{} ", line + 1, col + 1);
    let gap = width.saturating_sub(left.chars().count() + right.chars().count());
    let mut s = format!("{left}{}{right}", " ".repeat(gap));
    if s.chars().count() > width {
        s = s.chars().take(width).collect();
    }
    vec![Span::new(s, e.face("status"))]
}
