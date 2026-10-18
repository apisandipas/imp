//! Types shared by the server and every client: the text buffer and the
//! messages that cross the client/server boundary.

pub mod buffer;
pub mod protocol;

pub use buffer::Buffer;
pub use protocol::{ClientMsg, CursorShape, Frame, ServerMsg};
