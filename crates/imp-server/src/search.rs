//! Vim-style patterns on top of the `regex` crate.
//!
//! Users type Vim's "magic" syntax (`\(a\|b\)`, `\<word\>`, `x\+`), so it is
//! translated here rather than taught anew. Case follows Vim with
//! `ignorecase smartcase`: a pattern with an uppercase letter is case
//! sensitive, otherwise not; `\c` and `\C` force it either way.

use imp_core::Buffer;
use regex::{Regex, RegexBuilder};

/// Compiles a Vim pattern.
pub fn compile(pattern: &str) -> Result<Regex, String> {
    let (translated, case) = translate(pattern);
    let insensitive = match case {
        Case::Smart => !has_uppercase(pattern),
        Case::Ignore => true,
        Case::Match => false,
    };
    RegexBuilder::new(&translated)
        .case_insensitive(insensitive)
        .multi_line(true)
        .build()
        .map_err(|e| format!("bad pattern {pattern:?}: {}", first_line(&e.to_string())))
}

#[derive(Clone, Copy)]
enum Case {
    Smart,
    Ignore,
    Match,
}

fn first_line(s: &str) -> &str {
    s.lines().last().unwrap_or(s).trim()
}

/// Uppercase letters, ignoring escapes such as `\S` and `\W`.
fn has_uppercase(pattern: &str) -> bool {
    let mut chars = pattern.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            chars.next();
        } else if c.is_uppercase() {
            return true;
        }
    }
    false
}

/// Vim magic syntax -> `regex` syntax.
fn translate(pattern: &str) -> (String, Case) {
    let mut out = String::with_capacity(pattern.len() + 8);
    let mut case = Case::Smart;
    // After \v ("very magic") the pattern is close to `regex` syntax already.
    let mut very_magic = false;
    let mut chars = pattern.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            let Some(next) = chars.next() else {
                out.push_str("\\\\");
                break;
            };
            match next {
                'c' => case = Case::Ignore,
                'C' => case = Case::Match,
                'v' => very_magic = true,
                'm' | 'M' | 'V' => very_magic = false,
                '<' | '>' => out.push_str("\\b"),
                '{' if !very_magic => copy_count(&mut chars, &mut out),
                '(' | ')' | '|' | '+' | '?' | '}' if !very_magic => out.push(next),
                '=' if !very_magic => out.push('?'),
                's' | 'S' | 'd' | 'D' | 'w' | 'W' | 'n' | 't' | 'b' | 'B' => {
                    out.push('\\');
                    out.push(next);
                }
                'e' => out.push_str("\\x1b"),
                'r' => out.push_str("\\r"),
                'a' => out.push_str("[[:alpha:]]"),
                'l' => out.push_str("[[:lower:]]"),
                'u' => out.push_str("[[:upper:]]"),
                'x' => out.push_str("[[:xdigit:]]"),
                'h' => out.push_str("[A-Za-z_]"),
                _ => out.push_str(&regex::escape(&next.to_string())),
            }
        } else if very_magic {
            match c {
                '<' | '>' => out.push_str("\\b"),
                '=' => out.push('?'),
                _ => out.push(c),
            }
        } else {
            match c {
                // Special in `regex` but literal in Vim's magic mode.
                '(' | ')' | '|' | '+' | '?' | '{' | '}' => {
                    out.push('\\');
                    out.push(c);
                }
                // `~` is the last substitute string in Vim; literal is the
                // useful approximation until that exists.
                '~' => out.push('~'),
                '[' => copy_class(&mut chars, &mut out),
                _ => out.push(c),
            }
        }
    }
    (out, case)
}

/// After `\{`: Vim's counted repetition `\{n,m}` closes with a plain `}`,
/// and `\{-n,m}` is the non-greedy form.
fn copy_count(chars: &mut std::iter::Peekable<std::str::Chars>, out: &mut String) {
    let lazy = chars.next_if_eq(&'-').is_some();
    let mut body = String::new();
    for c in chars.by_ref() {
        match c {
            '}' => break,
            '\\' => {}
            _ => body.push(c),
        }
    }
    // `\{}` is `*` and `\{n}` exact, as in `regex`; `\{,m}` needs a 0.
    let body = if body.is_empty() || body == "," {
        "0,".to_string()
    } else if body.starts_with(',') {
        format!("0{body}")
    } else {
        body
    };
    out.push('{');
    out.push_str(&body);
    out.push('}');
    if lazy {
        out.push('?');
    }
}

/// Copies a `[...]` class through. Vim and `regex` agree on classes except
/// that `regex` treats a few chars inside them specially (`[` and `&&`).
fn copy_class(chars: &mut std::iter::Peekable<std::str::Chars>, out: &mut String) {
    let rest: String = chars.clone().collect();
    // An unclosed `[` is a literal in Vim.
    let closes = rest
        .char_indices()
        .any(|(i, c)| c == ']' && i > usize::from(rest.starts_with('^')));
    if !closes {
        out.push_str("\\[");
        return;
    }
    out.push('[');
    let mut first = true;
    while let Some(c) = chars.next() {
        match c {
            ']' if !first => {
                out.push(']');
                return;
            }
            '^' if first => {
                out.push('^');
                continue;
            }
            '\\' => match chars.next() {
                Some(n @ ('n' | 't' | 'r' | '\\' | ']' | '^' | '-')) => {
                    out.push('\\');
                    out.push(n);
                }
                Some(n) => out.push_str(&regex::escape(&n.to_string())),
                None => out.push_str("\\\\"),
            },
            '[' | '&' | '~' => {
                out.push('\\');
                out.push(c);
            }
            _ => out.push(c),
        }
        first = false;
    }
}

/// Translates a Vim replacement string to `regex`'s: `&` and `\0` are the
/// whole match, `\1`-`\9` groups, `\r` (and `\n`) a line break, `\&` a
/// literal `&`.
pub fn translate_replacement(rep: &str) -> String {
    let mut out = String::with_capacity(rep.len());
    let mut chars = rep.chars();
    while let Some(c) = chars.next() {
        match c {
            '&' => out.push_str("${0}"),
            '$' => out.push_str("$$"),
            '\\' => match chars.next() {
                Some(d @ '0'..='9') => {
                    out.push_str("${");
                    out.push(d);
                    out.push('}');
                }
                Some('r' | 'n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some('$') => out.push_str("$$"),
                Some(other) => out.push(other),
                None => out.push('\\'),
            },
            _ => out.push(c),
        }
    }
    out
}

/// The start of the next match after char offset `from` (or before it, when
/// searching backward), wrapping around the end of the buffer. The flag says
/// whether it wrapped.
pub fn next_match(
    buffer: &Buffer,
    re: &Regex,
    from: usize,
    forward: bool,
) -> Option<(usize, bool)> {
    let text = buffer.text();
    let from = buffer.char_to_byte(from);
    let starts = re.find_iter(&text).map(|m| m.start());
    let found = if forward {
        let mut first = None;
        let mut after = None;
        for start in starts {
            first.get_or_insert(start);
            if start > from {
                after = Some(start);
                break;
            }
        }
        after.map(|s| (s, false)).or(first.map(|s| (s, true)))
    } else {
        let mut before = None;
        let mut last = None;
        for start in starts {
            if start < from {
                before = Some(start);
            }
            last = Some(start);
        }
        before.map(|s| (s, false)).or(last.map(|s| (s, true)))
    };
    found.map(|(byte, wrapped)| (buffer.byte_to_char(byte), wrapped))
}

/// Replaces matches on lines `first..=last` with a Vim replacement string:
/// the first match on each line, or all of them if `global`. Returns how
/// many were replaced and the last line changed.
pub fn substitute(
    buffer: &mut Buffer,
    re: &Regex,
    replacement: &str,
    first: usize,
    last: usize,
    global: bool,
) -> (usize, Option<usize>) {
    let replacement = translate_replacement(replacement);
    let mut count = 0;
    let mut changed = None;
    let mut line = first;
    let mut last = last.min(buffer.line_count().saturating_sub(1));
    while line <= last {
        let text = buffer.line_text(line);
        let n = re.find_iter(&text).count();
        if n > 0 {
            let limit = if global { 0 } else { 1 };
            let new = re.replacen(&text, limit, replacement.as_str()).into_owned();
            count += if global { n } else { 1 };
            let start = buffer.line_col_to_offset(line, 0);
            buffer.delete(start, start + text.chars().count());
            buffer.insert(start, &new);
            // A replacement with line breaks adds lines; skip past them.
            let added = new.matches('\n').count();
            line += added;
            last += added;
            changed = Some(line);
        }
        line += 1;
    }
    (count, changed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn matches(pattern: &str, text: &str) -> Vec<String> {
        compile(pattern)
            .unwrap()
            .find_iter(text)
            .map(|m| m.as_str().to_string())
            .collect()
    }

    #[test]
    fn magic_syntax() {
        assert_eq!(matches(r"\<is\>", "this is his"), ["is"]);
        assert_eq!(matches(r"a\+", "caaat"), ["aaa"]);
        assert_eq!(matches(r"a+", "a+ aa"), ["a+"]);
        assert_eq!(matches(r"\(ab\)\{2}", "ababab"), ["abab"]);
        assert_eq!(matches(r"a\{-1,}", "aaa"), ["a", "a", "a"]);
        assert_eq!(matches(r"x\{,2}y", "xxy"), ["xxy"]);
        assert_eq!(matches(r"x\|y", "axby"), ["x", "y"]);
        assert_eq!(matches(r"f(x)", "f(x)"), ["f(x)"]);
        assert_eq!(matches(r"\v(a|b)+", "abba c"), ["abba"]);
        assert_eq!(matches(r"[a-c]\+", "xabcx"), ["abc"]);
        assert_eq!(matches(r"[", "a[b"), ["["]);
    }

    #[test]
    fn smartcase() {
        assert_eq!(matches("foo", "Foo foo"), ["Foo", "foo"]);
        assert_eq!(matches("Foo", "Foo foo"), ["Foo"]);
        assert_eq!(matches(r"\Cfoo", "Foo foo"), ["foo"]);
        assert_eq!(matches(r"Foo\c", "Foo foo"), ["Foo", "foo"]);
        // \S is an escape, not an uppercase letter.
        assert_eq!(matches(r"a\S", "ab AB"), ["ab", "AB"]);
    }

    #[test]
    fn replacements() {
        let re = compile(r"\(\w\+\)=\(\w\+\)").unwrap();
        let rep = translate_replacement(r"\2=\1 [&] \& $x");
        assert_eq!(re.replace("a=b", rep.as_str()), "b=a [a=b] & $x");
    }
}
