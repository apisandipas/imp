//! Turns editor state into a frame for the client.

use imp_core::Frame;

use crate::editor::Editor;

const TAB_WIDTH: usize = 4;

pub fn frame(e: &mut Editor) -> Frame {
    let width = e.width.max(1) as usize;
    let text_rows = e.height.saturating_sub(1).max(1) as usize;

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
            rows.push("~".to_string());
            continue;
        }
        let (display, x) = expand_tabs(&e.buffer.line_text(line), cursor_col);
        if line == cursor_line {
            cursor_x = x;
        }
        rows.push(display.chars().take(width).collect());
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

/// Expands tabs to spaces, returning the display text and the display column
/// of char column `col`.
fn expand_tabs(line: &str, col: usize) -> (String, usize) {
    let mut out = String::with_capacity(line.len());
    let mut x = None;
    for (i, c) in line.chars().enumerate() {
        if i == col {
            x = Some(out.chars().count());
        }
        if c == '\t' {
            let n = TAB_WIDTH - out.chars().count() % TAB_WIDTH;
            out.extend(std::iter::repeat_n(' ', n));
        } else {
            out.push(c);
        }
    }
    let end = out.chars().count();
    (out, x.unwrap_or(end))
}

fn status_line(e: &Editor, line: usize, col: usize, width: usize) -> String {
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
    s
}
