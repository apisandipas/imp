//! JSON for Scheme, and the framing LSP and DAP put around it.
//!
//! Objects become Steel hashes with string keys, arrays become lists,
//! `null` the symbol `null`. Going back, a list is an array (so `'()` is
//! `[]`; write `(hash)` for `{}`), and `void` and `'null` are `null`.

use serde_json::{Map, Number, Value};
use steel::gc::Gc;
use steel::rvals::{SteelHashMap, SteelVal};

pub fn to_steel(value: Value) -> SteelVal {
    match value {
        Value::Null => SteelVal::SymbolV("null".into()),
        Value::Bool(b) => SteelVal::BoolV(b),
        Value::Number(n) => match n.as_i64().and_then(|i| isize::try_from(i).ok()) {
            Some(i) => SteelVal::IntV(i),
            None => SteelVal::NumV(n.as_f64().unwrap_or(0.0)),
        },
        Value::String(s) => SteelVal::StringV(s.into()),
        Value::Array(items) => SteelVal::ListV(items.into_iter().map(to_steel).collect()),
        Value::Object(fields) => {
            let map: steel::HashMap<SteelVal, SteelVal> = fields
                .into_iter()
                .map(|(k, v)| (SteelVal::StringV(k.into()), to_steel(v)))
                .collect();
            SteelVal::HashMapV(SteelHashMap::from(Gc::new(map)))
        }
    }
}

pub fn from_steel(value: &SteelVal) -> Result<Value, String> {
    Ok(match value {
        SteelVal::Void => Value::Null,
        SteelVal::BoolV(b) => Value::Bool(*b),
        SteelVal::IntV(i) => Value::Number((*i as i64).into()),
        SteelVal::NumV(f) => Number::from_f64(*f).map_or(Value::Null, Value::Number),
        SteelVal::StringV(s) => Value::String(s.to_string()),
        SteelVal::SymbolV(s) if s.as_str() == "null" => Value::Null,
        SteelVal::SymbolV(s) => Value::String(s.to_string()),
        SteelVal::CharV(c) => Value::String(c.to_string()),
        SteelVal::ListV(items) => {
            Value::Array(items.iter().map(from_steel).collect::<Result<_, _>>()?)
        }
        SteelVal::VectorV(items) => {
            Value::Array(items.iter().map(from_steel).collect::<Result<_, _>>()?)
        }
        SteelVal::HashMapV(map) => {
            let mut out = Map::new();
            for (k, v) in map.iter() {
                let key = match k {
                    SteelVal::StringV(s) | SteelVal::SymbolV(s) => s.to_string(),
                    other => return Err(format!("JSON object keys must be strings, not {other}")),
                };
                out.insert(key, from_steel(v)?);
            }
            Value::Object(out)
        }
        other => return Err(format!("can't turn {other} into JSON")),
    })
}

/// A message with LSP's header: `Content-Length: N\r\n\r\n` then the body,
/// N counting bytes.
pub fn frame(body: &str) -> String {
    format!("Content-Length: {}\r\n\r\n{body}", body.len())
}

/// The first whole message in `buffer`, as (body, rest), or `None` if one
/// hasn't fully arrived.
pub fn take_message(buffer: &str) -> Option<(String, String)> {
    let (start, end) = message_bounds(buffer)?;
    Some((buffer[start..end].to_string(), buffer[end..].to_string()))
}

/// Where the body of the first whole message in `buffer` starts and ends
/// (bytes), or `None` if one hasn't fully arrived.
pub fn message_bounds(buffer: &str) -> Option<(usize, usize)> {
    let header_end = buffer.find("\r\n\r\n")?;
    let length: usize = buffer[..header_end].lines().find_map(|l| {
        let (name, value) = l.split_once(':')?;
        name.trim()
            .eq_ignore_ascii_case("content-length")
            .then(|| value.trim().parse().ok())?
    })?;
    let start = header_end + 4;
    let end = start + length;
    if buffer.len() < end || !buffer.is_char_boundary(end) {
        return None;
    }
    Some((start, end))
}

/// A `file://` URI for an absolute path, percent-encoding what URIs can't
/// hold.
pub fn path_to_uri(path: &str) -> String {
    let mut out = String::from("file://");
    for b in path.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// The path of a `file://` URI, or `None` for another scheme.
pub fn uri_to_path(uri: &str) -> Option<String> {
    let rest = uri.strip_prefix("file://")?;
    let mut bytes = Vec::with_capacity(rest.len());
    let raw = rest.as_bytes();
    let mut i = 0;
    while i < raw.len() {
        if raw[i] == b'%' && i + 2 < raw.len() {
            if let Ok(b) = u8::from_str_radix(&rest[i + 1..i + 3], 16) {
                bytes.push(b);
                i += 3;
                continue;
            }
        }
        bytes.push(raw[i]);
        i += 1;
    }
    String::from_utf8(bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn framing() {
        let body = r#"{"a":"é"}"#;
        let framed = frame(body);
        assert!(framed.starts_with("Content-Length: 10\r\n\r\n"));
        let two = format!("{framed}{}", frame("[]"));
        let (first, rest) = take_message(&two).unwrap();
        assert_eq!(first, body);
        assert_eq!(take_message(&rest).unwrap().0, "[]");
        assert!(take_message(&framed[..framed.len() - 1]).is_none());
    }

    #[test]
    fn uris() {
        let uri = path_to_uri("/home/me/my file.rs");
        assert_eq!(uri, "file:///home/me/my%20file.rs");
        assert_eq!(uri_to_path(&uri).unwrap(), "/home/me/my file.rs");
        assert!(uri_to_path("https://x").is_none());
    }

    #[test]
    fn values_round_trip() {
        let v: Value = serde_json::from_str(r#"{"a":[1,2.5,null,true,"s"],"b":{}}"#).unwrap();
        assert_eq!(from_steel(&to_steel(v.clone())).unwrap(), v);
    }
}
