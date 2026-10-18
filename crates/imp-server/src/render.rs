//! Turns editor state into a frame for the client.

use imp_core::{Frame, Row, Span, Style};

use crate::editor::Editor;

const TAB_WIDTH: usize = 4;

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

    let mut rows = Vec::with_capacity(text_rows + 1);
    let mut cursor_x = 0;
    for row in 0..text_rows {
        let line = e.scroll + row;
        if line >= e.buffer.line_count() {
            rows.push(vec![Span::new("~", e.face("nontext"))]);
            continue;
        }
        let (row, x) = line_row(e, line, cursor_col, width);
        if line == cursor_line {
            cursor_x = x;
        }
        rows.push(row);
    }
    rows.push(status_line(e, cursor_line, cursor_col, width));

    Frame {
        rows,
        cursor: (
            cursor_x.min(width - 1) as u16,
            (cursor_line - e.scroll) as u16,
        ),
        cursor_shape: e.cursor_shape,
    }
}

/// Draws buffer line `line`, clipped to `width` display columns. Returns the
/// row and the display column of char column `col`.
fn line_row(e: &Editor, line: usize, col: usize, width: usize) -> (Row, usize) {
    let start = e.buffer.line_col_to_offset(line, 0);
    let text = e.buffer.line_text(line);
    let styles = char_styles(e, start, &text);

    let mut row: Row = Vec::new();
    let mut x = 0;
    let mut cursor_x = None;
    for (i, c) in text.chars().enumerate() {
        if i == col {
            cursor_x = Some(x);
        }
        let (shown, n) = if c == '\t' {
            let n = TAB_WIDTH - x % TAB_WIDTH;
            (" ".repeat(n), n)
        } else {
            (c.to_string(), 1)
        };
        x += n;
        if x <= width {
            push(&mut row, &shown, styles[i]);
        } else if x - n < width {
            push(&mut row, &shown[..width - (x - n)], styles[i]);
        }
    }
    // A selection that takes in the line break shows as one highlighted cell
    // past the end of the line, as in Vim, so selected empty lines are visible.
    let eol = styles[text.chars().count()];
    if eol != Style::default() && x < width {
        push(&mut row, " ", eol);
    }
    (row, cursor_x.unwrap_or(x))
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
    let name = match e.buffer.path() {
        Some(path) => path.display().to_string(),
        None => "[scratch]".to_string(),
    };
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
