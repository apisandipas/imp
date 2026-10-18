//! The client/server protocol.
//!
//! Clients are dumb: they send raw input and draw whatever frame they are
//! given. Modes, keymaps and layout all live in the server, where Scheme can
//! reach them.

/// Client -> server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientMsg {
    /// A key in imp's notation: `"j"`, `"<esc>"`, `"<ret>"`, `"C-c"`.
    Key(String),
    Resize {
        width: u16,
        height: u16,
    },
}

/// Server -> client.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerMsg {
    Frame(Frame),
    Quit,
}

/// A full screen as a grid of rows. The last row is the status line.
///
/// This is deliberately the simplest protocol that works in a terminal; styled
/// cells and incremental updates come later without changing who decides what.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Frame {
    pub rows: Vec<String>,
    /// Screen position (column, row) of the cursor.
    pub cursor: (u16, u16),
    pub cursor_shape: CursorShape,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CursorShape {
    #[default]
    Block,
    Bar,
}
