//! Reading the loaded Scheme sources for their definitions and the first
//! line of each one's documentation, for M-x, help and completion. The
//! same reader as help.scm's (which describe-function uses for a single
//! definition), in Rust because reading every source is too slow in
//! Scheme: a few milliseconds here, ~0.4s there.

type Pos = (usize, usize);
/// (key, value) pairs.
type Pairs = Vec<(String, String)>;

/// The source as lines of chars; the end of a line reads as '\n', the
/// end of the source as None.
struct Source {
    lines: Vec<Vec<char>>,
}

impl Source {
    fn char(&self, (i, j): Pos) -> Option<char> {
        let line = self.lines.get(i)?;
        Some(line.get(j).copied().unwrap_or('\n'))
    }

    fn next(&self, (i, j): Pos) -> Pos {
        match self.lines.get(i) {
            Some(line) if j < line.len() => (i, j + 1),
            Some(_) => (i + 1, 0),
            None => (i, j),
        }
    }

    /// The first thing from `pos` that isn't whitespace or a ; comment.
    fn skip_blank(&self, mut pos: Pos) -> Pos {
        loop {
            match self.char(pos) {
                Some(c) if c.is_whitespace() => pos = self.next(pos),
                Some(';') => pos = (pos.0 + 1, 0),
                _ => return pos,
            }
        }
    }

    /// The string literal at `pos` (its opening quote) and the position
    /// after it.
    fn string_literal(&self, pos: Pos) -> (String, Pos) {
        let mut pos = self.next(pos);
        let mut text = String::new();
        loop {
            match self.char(pos) {
                None => return (text, pos),
                Some('"') => return (text, self.next(pos)),
                Some('\\') => {
                    let at = self.next(pos);
                    text.push(match self.char(at) {
                        Some('n') => '\n',
                        Some('t') => '\t',
                        Some(c) => c,
                        None => '\\',
                    });
                    pos = self.next(at);
                }
                Some(c) => {
                    text.push(c);
                    pos = self.next(pos);
                }
            }
        }
    }

    /// The position after the form at `pos`.
    fn skip_form(&self, pos: Pos) -> Pos {
        match self.char(pos) {
            None => pos,
            Some('"') => self.string_literal(pos).1,
            Some('\'' | '`' | ',') => self.skip_form(self.next(pos)),
            Some('(' | '[') => {
                let mut pos = self.skip_blank(self.next(pos));
                loop {
                    match self.char(pos) {
                        None => return pos,
                        Some(')' | ']') => return self.next(pos),
                        _ => pos = self.skip_blank(self.skip_form(pos)),
                    }
                }
            }
            Some('#') if self.char(self.next(pos)) == Some('\\') => {
                // A character: #\( is one, so step over the char first.
                let mut pos = self.next(self.next(self.next(pos)));
                while !delimiter(self.char(pos)) {
                    pos = self.next(pos);
                }
                pos
            }
            _ => {
                let mut pos = pos;
                while !delimiter(self.char(pos)) {
                    pos = self.next(pos);
                }
                pos
            }
        }
    }

    fn token(&self, mut pos: Pos) -> String {
        let mut s = String::new();
        while let Some(c) = self.char(pos).filter(|&c| !delimiter(Some(c))) {
            s.push(c);
            pos = self.next(pos);
        }
        s
    }

    /// The docstring at `pos`, the start of a body: a string literal with
    /// more of the body after it.
    fn body_docstring(&self, pos: Pos) -> Option<String> {
        if self.char(pos) != Some('"') {
            return None;
        }
        let (text, after) = self.string_literal(pos);
        match self.char(self.skip_blank(after)) {
            None | Some(')' | ']') => None,
            _ => Some(text),
        }
    }

    /// At `pos`, a (lambda ARGS ...) form: its docstring.
    fn lambda_docstring(&self, pos: Pos) -> Option<String> {
        if self.char(pos) != Some('(') {
            return None;
        }
        let at = self.skip_blank(self.next(pos));
        if self.token(at) != "lambda" {
            return None;
        }
        let args = self.skip_blank(self.skip_form(at));
        self.body_docstring(self.skip_blank(self.skip_form(args)))
    }

    /// The docstring of the definition starting on line `n`.
    fn definition_docstring(&self, n: usize) -> Option<String> {
        let start = self.skip_blank(self.next((n, 0)));
        let head = self.skip_blank(self.skip_form(start));
        let after = self.skip_blank(self.skip_form(head));
        if self.token(start) == "define" && self.char(head) == Some('(') {
            self.body_docstring(after)
        } else {
            self.lambda_docstring(after)
        }
    }

    fn line(&self, n: usize) -> String {
        self.lines[n].iter().collect()
    }
}

fn delimiter(c: Option<char>) -> bool {
    match c {
        None => true,
        Some(c) => c.is_whitespace() || matches!(c, '(' | ')' | '[' | ']' | '"' | ';'),
    }
}

/// The name a line defines, if it starts a definition (help.scm's
/// defined-name).
pub fn defined_name(line: &str) -> Option<&str> {
    for prefix in [
        "(define (",
        "(define-command! '",
        "(define-option! '",
        "(define-syntax ",
        "(define ",
    ] {
        if let Some(rest) = line.strip_prefix(prefix) {
            let end = rest.find([' ', ')', '(']).unwrap_or(rest.len());
            return (end > 0).then(|| &rest[..end]);
        }
    }
    None
}

/// The names `text` defines, in order.
pub fn defined_names(text: &str) -> Vec<String> {
    text.lines()
        .filter_map(defined_name)
        .map(String::from)
        .collect()
}

/// `line` without its leading semicolons and the space after them.
fn strip_comment(line: &str) -> &str {
    let rest = line.trim_start_matches(';');
    rest.strip_prefix(' ').unwrap_or(rest)
}

/// The procedure a (define-command! 'name procedure) line names.
fn command_procedure(line: &str) -> Option<String> {
    let rest = line.strip_prefix("(define-command! '")?;
    let after_name = rest.find(|c: char| delimiter(Some(c)))?;
    let proc = rest[after_name..].trim_start();
    let end = proc
        .find(|c: char| delimiter(Some(c)))
        .unwrap_or(proc.len());
    (end > 0 && !proc.starts_with('(')).then(|| proc[..end].to_string())
}

/// The first line of the documentation of each documented definition in
/// `text`, as (key, line): its docstring's, or the comment block above's.
/// Commands go in as "command NAME". Also (key, procedure) for each
/// undocumented command defined as a named procedure, to take that
/// procedure's line.
pub fn doc_lines(text: &str) -> (Pairs, Pairs) {
    let source = Source {
        lines: text.lines().map(|l| l.chars().collect()).collect(),
    };
    let raw: Vec<&str> = text.lines().collect();
    let mut docs = Vec::new();
    let mut aliases = Vec::new();
    for (n, line) in raw.iter().enumerate() {
        let Some(name) = defined_name(line) else {
            continue;
        };
        let key = if line.starts_with("(define-command! '") {
            format!("command {name}")
        } else {
            name.to_string()
        };
        let first = match source.definition_docstring(n) {
            Some(doc) => doc.lines().next().unwrap_or("").trim().to_string(),
            None => {
                let mut i = n;
                while i > 0 && raw[i - 1].starts_with(';') {
                    i -= 1;
                }
                if i < n {
                    strip_comment(raw[i]).trim().to_string()
                } else {
                    String::new()
                }
            }
        };
        if !first.is_empty() {
            docs.push((key, first));
        } else if let Some(proc) = command_procedure(&source.line(n)) {
            aliases.push((key, proc));
        }
    }
    (docs, aliases)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn docstrings_and_comments() {
        let text = r#"(define (f x)
  "Doubles `x`.
   More."
  (* 2 x))
;; The answer.
(define answer 42)
(define (g) "only a value")
(define-command! 'go
  (lambda (count)
    "Go somewhere."
    (g)))
(define-command! 'run f)
(define h (lambda (y) "Halves (y)." (/ y 2)))
(define (c) (list #\( "not a doc"))
"#;
        let (docs, aliases) = doc_lines(text);
        assert_eq!(
            docs,
            [
                ("f".into(), "Doubles `x`.".into()),
                ("answer".into(), "The answer.".into()),
                ("command go".into(), "Go somewhere.".into()),
                ("h".into(), "Halves (y).".into()),
            ]
        );
        assert_eq!(aliases, [("command run".to_string(), "f".to_string())]);
    }

    #[test]
    fn names() {
        assert_eq!(defined_name("(define (a b) c)"), Some("a"));
        assert_eq!(defined_name("(define-option! 'wrap #f '())"), Some("wrap"));
        assert_eq!(defined_name("(define-key! 'normal"), None);
        assert_eq!(defined_name("(define x)"), Some("x"));
    }
}
