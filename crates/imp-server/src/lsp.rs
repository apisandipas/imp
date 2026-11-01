//! The hot paths of the LSP client (runtime/lsp.scm), kept out of Scheme:
//! collecting each server's output into messages, and completion replies,
//! which can be megabytes (TypeScript's offers every export it could
//! import, ~16k items). Such a reply is read here with only the fields
//! the menu shows; Scheme gets its candidates ready, and a whole item
//! only when one is accepted.

use crate::editor::Editor;
use crate::json::{message_bounds, to_steel};
use serde::de::IgnoredAny;
use serde::Deserialize;
use serde_json::value::RawValue;
use serde_json::Value;
use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use steel::gc::Gc;
use steel::rvals::{SteelHashMap, SteelVal};

/// Completion replies kept for their items, newest last.
const KEPT: usize = 8;

#[derive(Default)]
struct State {
    /// Each server's output not yet read as a message.
    input: HashMap<String, String>,
    /// Completion requests awaiting a reply, by (server, id): whether it
    /// is still wanted (a superseded one's reply is dropped unread).
    expected: HashMap<(String, i64), bool>,
    /// Recent completion replies.
    replies: VecDeque<Reply>,
    next_handle: i64,
}

struct Reply {
    handle: i64,
    items: Vec<Item>,
}

/// What the menu needs of a completion item, and the item's JSON.
struct Item {
    label: String,
    detail: String,
    sort: String,
    /// What it inserts: its edit's text, insertText or label.
    text: String,
    snippet: bool,
    kind: Option<i64>,
    /// Where its edit starts, (line, character).
    edit_start: Option<(u64, u64)>,
    raw: Box<RawValue>,
}

/// Just enough of a message to route it.
#[derive(Deserialize)]
struct Peek {
    id: Option<Value>,
    method: Option<IgnoredAny>,
}

#[derive(Deserialize)]
struct ReplyMsg<'a> {
    #[serde(borrow)]
    result: Option<&'a RawValue>,
    error: Option<Value>,
}

#[derive(Deserialize)]
struct CompletionList<'a> {
    #[serde(rename = "isIncomplete", default)]
    incomplete: bool,
    #[serde(borrow, default)]
    items: Vec<&'a RawValue>,
}

#[derive(Deserialize)]
struct Position {
    #[serde(default)]
    line: u64,
    #[serde(default)]
    character: u64,
}

#[derive(Deserialize)]
struct Range {
    start: Position,
}

#[derive(Deserialize)]
struct TextEdit {
    #[serde(rename = "newText")]
    new_text: Option<String>,
    range: Option<Range>,
    insert: Option<Range>,
}

#[derive(Deserialize)]
struct ItemFields {
    label: Option<String>,
    detail: Option<String>,
    #[serde(rename = "sortText")]
    sort_text: Option<String>,
    #[serde(rename = "insertText")]
    insert_text: Option<String>,
    #[serde(rename = "insertTextFormat")]
    insert_text_format: Option<i64>,
    kind: Option<i64>,
    #[serde(rename = "textEdit")]
    text_edit: Option<TextEdit>,
}

impl Item {
    fn read(raw: &RawValue) -> Option<Item> {
        let f: ItemFields = serde_json::from_str(raw.get()).ok()?;
        let label = f.label.unwrap_or_default();
        let edit_start = f
            .text_edit
            .as_ref()
            .and_then(|e| e.range.as_ref().or(e.insert.as_ref()))
            .map(|r| (r.start.line, r.start.character));
        let text = f
            .text_edit
            .and_then(|e| e.new_text)
            .or(f.insert_text)
            .unwrap_or_else(|| label.clone());
        Some(Item {
            sort: f.sort_text.unwrap_or_else(|| label.clone()),
            label,
            detail: f.detail.unwrap_or_default(),
            text,
            snippet: f.insert_text_format == Some(2),
            kind: f.kind,
            edit_start,
            raw: raw.to_owned(),
        })
    }
}

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State::default());
}

fn hash(pairs: Vec<(&str, SteelVal)>) -> SteelVal {
    let map: steel::HashMap<SteelVal, SteelVal> = pairs
        .into_iter()
        .map(|(k, v)| (SteelVal::StringV(k.into()), v))
        .collect();
    SteelVal::HashMapV(SteelHashMap::from(Gc::new(map)))
}

/// Adds `text`, output from server `key`, to what it has sent, and returns
/// the messages now whole, decoded. The reply to an expected completion
/// request has as its result a hash of "imp-completion" (a handle for
/// lsp-completion-candidates) and "isIncomplete"; one no longer wanted,
/// null.
pub fn read_messages(key: &str, text: &str) -> Vec<SteelVal> {
    STATE.with(|state| {
        let mut state = state.borrow_mut();
        let mut input = state.input.remove(key).unwrap_or_default();
        input.push_str(text);
        let mut out = Vec::new();
        let mut used = 0;
        while let Some((start, end)) = message_bounds(&input[used..]) {
            let body = &input[used + start..used + end];
            used += end;
            if let Some(msg) = state.decode(key, body) {
                out.push(msg);
            }
        }
        input.drain(..used);
        state.input.insert(key.to_string(), input);
        out
    })
}

impl State {
    fn decode(&mut self, key: &str, body: &str) -> Option<SteelVal> {
        let peek: Peek = serde_json::from_str(body).ok()?;
        let id = peek
            .id
            .as_ref()
            .and_then(Value::as_i64)
            .filter(|_| peek.method.is_none());
        let wanted = id.and_then(|id| self.expected.remove(&(key.to_string(), id)));
        let (Some(id), Some(wanted)) = (id, wanted) else {
            return serde_json::from_str::<Value>(body).ok().map(to_steel);
        };
        let id_val = SteelVal::IntV(id as isize);
        let null = || SteelVal::SymbolV("null".into());
        if !wanted {
            return Some(hash(vec![("id", id_val), ("result", null())]));
        }
        let msg: ReplyMsg = serde_json::from_str(body).ok()?;
        if let Some(error) = msg.error {
            return Some(hash(vec![("id", id_val), ("error", to_steel(error))]));
        }
        let result = msg.result.map(RawValue::get).unwrap_or("null").trim_start();
        let (incomplete, raws) = if result.starts_with('[') {
            (
                false,
                serde_json::from_str::<Vec<&RawValue>>(result).unwrap_or_default(),
            )
        } else if result.starts_with('{') {
            let list: CompletionList = serde_json::from_str(result).ok()?;
            (list.incomplete, list.items)
        } else {
            (false, Vec::new())
        };
        let handle = self.next_handle;
        self.next_handle += 1;
        let items = raws.into_iter().filter_map(Item::read).collect();
        self.replies.push_back(Reply { handle, items });
        while self.replies.len() > KEPT {
            self.replies.pop_front();
        }
        Some(hash(vec![
            ("id", id_val),
            (
                "result",
                hash(vec![
                    ("imp-completion", SteelVal::IntV(handle as isize)),
                    ("isIncomplete", SteelVal::BoolV(incomplete)),
                ]),
            ),
        ]))
    }
}

/// Expects the reply to completion request `id` to server `key`.
pub fn expect_completion(key: &str, id: i64) {
    STATE.with(|s| s.borrow_mut().expected.insert((key.to_string(), id), true));
}

/// Drops the reply to completion request `id`, superseded, when it comes.
pub fn drop_completion(key: &str, id: i64) {
    STATE.with(|s| {
        if let Some(wanted) = s.borrow_mut().expected.get_mut(&(key.to_string(), id)) {
            *wanted = false;
        }
    })
}

/// The offset of LSP position (`line`, `character`) in the current buffer,
/// clamped to it; `character` counts in `encoding` (lsp.scm's lsp-offset).
fn offset(e: &Editor, line: usize, character: usize, utf32: bool) -> usize {
    let buffer = e.buffer();
    if line >= buffer.line_count() {
        return buffer.len();
    }
    let start = buffer.rope().line_to_char(line);
    let len = buffer.line_len(line);
    if utf32 {
        return start + character.min(len);
    }
    let mut units = 0;
    for (col, c) in buffer.rope().slice(start..start + len).chars().enumerate() {
        if units >= character {
            return start + col;
        }
        units += c.len_utf16();
    }
    start + len
}

/// The menu candidates of completion reply `handle`, in the server's
/// order (sortText): lists (label detail text start item) as complete.scm
/// takes them. `start` is where the typed word starts, for items without
/// a textEdit, and edits' positions count in `encoding`. Snippets are
/// reduced to plain text. `item` is (imp-completion handle index kind),
/// for lsp-completion-item.
pub fn candidates(e: &Editor, handle: i64, start: usize, encoding: &str) -> Vec<SteelVal> {
    STATE.with(|state| {
        let state = state.borrow();
        let Some(reply) = state.replies.iter().find(|r| r.handle == handle) else {
            return Vec::new();
        };
        let mut order: Vec<usize> = (0..reply.items.len()).collect();
        order.sort_by(|&a, &b| reply.items[a].sort.cmp(&reply.items[b].sort));
        let utf32 = encoding == "utf-32";
        let mut offsets: HashMap<(u64, u64), usize> = HashMap::new();
        let tag = SteelVal::SymbolV("imp-completion".into());
        order
            .into_iter()
            .map(|i| {
                let item = &reply.items[i];
                let text = if item.snippet {
                    strip_snippet(&item.text)
                } else {
                    item.text.clone()
                };
                let at = item.edit_start.map_or(start, |(line, character)| {
                    *offsets
                        .entry((line, character))
                        .or_insert_with(|| offset(e, line as usize, character as usize, utf32))
                });
                let kind = item
                    .kind
                    .map_or(SteelVal::BoolV(false), |k| SteelVal::IntV(k as isize));
                let stub = vec![
                    tag.clone(),
                    SteelVal::IntV(handle as isize),
                    SteelVal::IntV(i as isize),
                    kind,
                ];
                SteelVal::ListV(
                    vec![
                        SteelVal::StringV(item.label.as_str().into()),
                        SteelVal::StringV(item.detail.as_str().into()),
                        SteelVal::StringV(text.into()),
                        SteelVal::IntV(at as isize),
                        SteelVal::ListV(stub.into()),
                    ]
                    .into(),
                )
            })
            .collect()
    })
}

/// Item `index` of completion reply `handle`, whole, or None once the
/// reply is gone.
pub fn item(handle: i64, index: usize) -> Option<SteelVal> {
    STATE.with(|state| {
        let state = state.borrow();
        let reply = state.replies.iter().find(|r| r.handle == handle)?;
        let raw = &reply.items.get(index)?.raw;
        serde_json::from_str::<Value>(raw.get()).ok().map(to_steel)
    })
}

/// Snippet `text` as plain text, without its tab stops (lsp.scm's
/// strip-snippet): ${1:text} -> text, $1 ${1} $0 -> nothing, ${1|a,b|}
/// -> a, \$ -> $.
pub fn strip_snippet(text: &str) -> String {
    let cs: Vec<char> = text.chars().collect();
    let mut out = String::new();
    let mut depth = 0;
    let mut i = 0;
    let digits_from = |mut j: usize| {
        while j < cs.len() && cs[j].is_ascii_digit() {
            j += 1;
        }
        j
    };
    while i < cs.len() {
        match cs[i] {
            '\\' if i + 1 < cs.len() => {
                out.push(cs[i + 1]);
                i += 2;
            }
            '$' if i + 1 < cs.len() && cs[i + 1].is_ascii_digit() => i = digits_from(i + 1),
            '$' if i + 1 < cs.len() && cs[i + 1] == '{' => {
                let j = digits_from(i + 2);
                match cs.get(j) {
                    Some(':') => {
                        depth += 1;
                        i = j + 1;
                    }
                    Some('|') => {
                        // A choice: keep the first option.
                        let mut k = j + 1;
                        while k < cs.len() && cs[k] != ',' && cs[k] != '|' {
                            out.push(cs[k]);
                            k += 1;
                        }
                        while k < cs.len() && cs[k] != '}' {
                            k += 1;
                        }
                        i = k + 1;
                    }
                    _ => i = j + 1,
                }
            }
            '}' if depth > 0 => {
                depth -= 1;
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snippets_as_plain_text() {
        assert_eq!(strip_snippet("foo(${1:x}, $2)$0"), "foo(x, )");
        assert_eq!(strip_snippet("${1|let,const|} a"), "let a");
        assert_eq!(strip_snippet("\\$1 ${2}"), "$1 ");
    }

    #[test]
    fn messages_across_chunks() {
        let body = r#"{"jsonrpc":"2.0","id":3,"result":{"isIncomplete":true,"items":[{"label":"a","kind":3}]}}"#;
        let framed = crate::json::frame(body);
        let (a, b) = framed.split_at(30);
        assert!(read_messages("test", a).is_empty());
        expect_completion("test", 3);
        let msgs = read_messages("test", &format!("{b}{}", crate::json::frame("{\"id\":4}")));
        assert_eq!(msgs.len(), 2);
        let s = format!("{}", msgs[0]);
        assert!(s.contains("imp-completion") && !s.contains("items"), "{s}");
        let handle = STATE.with(|s| s.borrow().replies.back().unwrap().handle);
        assert!(format!("{}", item(handle, 0).unwrap()).contains("kind"));
        // A dropped one comes back with a null result.
        expect_completion("test", 5);
        drop_completion("test", 5);
        let msgs = read_messages("test", &crate::json::frame(&body.replace(":3,", ":5,")));
        assert!(!format!("{}", msgs[0]).contains("imp-completion"));
    }
}
