//! The editor documents itself from its own source.

mod common;

use common::*;

fn popup_text(s: &mut imp_server::Server) -> String {
    s.frame().text_rows().join("\n")
}

#[test]
fn describe_function_shows_comment_and_location() {
    let mut s = server("");
    type_keys(&mut s, ":help line-first-nonblank<ret>");
    let text = popup_text(&mut s);
    assert!(text.contains("Defined in runtime/core.scm:"), "{text}");
    assert!(
        text.contains("Offset of the first non-blank char"),
        "{text}"
    );
}

#[test]
fn describe_key_finds_the_binding() {
    let mut s = server("");
    s.eval("(run-command 'describe-key)").unwrap();
    type_keys(&mut s, "w");
    let text = popup_text(&mut s);
    assert!(text.contains("w runs the motion w"), "{text}");
    assert!(text.contains("define-motion! \"w\""), "{text}");
    // Prefix keys wait for the rest.
    type_keys(&mut s, "<esc>");
    s.eval("(run-command 'describe-key)").unwrap();
    type_keys(&mut s, "gg");
    assert!(popup_text(&mut s).contains("gg runs the motion gg"));
    type_keys(&mut s, "<esc>");
    s.eval("(run-command 'describe-key)").unwrap();
    type_keys(&mut s, "fx");
    assert!(popup_text(&mut s).contains("motion taking a char f"));
    type_keys(&mut s, "<esc>");
    s.eval("(run-command 'describe-key)").unwrap();
    type_keys(&mut s, "p");
    assert!(popup_text(&mut s).contains("paste-command! \"p\""));
}

#[test]
fn describe_key_names_commands() {
    let mut s = server("");
    s.eval("(define-key! 'normal \"Q\" 'eval-buffer)").unwrap();
    s.eval("(run-command 'describe-key)").unwrap();
    type_keys(&mut s, "Q");
    let text = popup_text(&mut s);
    assert!(text.contains("Q runs the command eval-buffer"), "{text}");
    assert!(text.contains("Evaluate the whole buffer."), "{text}");
}

#[test]
fn help_for_options_and_ex_commands() {
    let mut s = server("");
    type_keys(&mut s, ":help sw<ret>");
    assert!(popup_text(&mut s).contains("shiftwidth = 4"));
    type_keys(&mut s, "<esc>:help sort<ret>");
    assert!(popup_text(&mut s).contains(":sort"));
}

#[test]
fn apropos_lists_matching_names() {
    let mut s = server("");
    type_keys(&mut s, ":apropos paragraph<ret>");
    let text = popup_text(&mut s);
    assert!(text.contains("paragraph-forward"), "{text}");
}

#[test]
fn definitions_in_init_win() {
    let mut s = server("");
    s.eval("(record-source! \"init.scm\" \"\" \";; Mine now.\\n(define (line-first-nonblank line) 0)\\n\")")
        .unwrap();
    type_keys(&mut s, ":help line-first-nonblank<ret>");
    let text = popup_text(&mut s);
    assert!(text.contains("Defined in init.scm:2"), "{text}");
    assert!(text.contains("Mine now."), "{text}");
}

#[test]
fn find_definition_opens_the_source() {
    let mut s = server("");
    type_keys(&mut s, ":find-definition blank-line?<ret>");
    assert!(s.text().contains(";;; vim.scm"));
    let line_start = s.text()[..s.cursor()].rfind('\n').map_or(0, |i| i + 1);
    assert!(s.text()[line_start..].starts_with("(define (blank-line? line)"));
    // The copy is not modified, so it can be left.
    type_keys(&mut s, ":bd<ret>");
    assert_eq!(s.text(), "");
}

/// Records `text` as a loaded source called `name`, as init.scm would be.
fn record_source(s: &mut imp_server::Server, name: &str, text: &str) {
    let path = temp_path(name);
    std::fs::write(&path, text).unwrap();
    s.eval(&format!(
        "(record-source! {name:?} \"\" (read-file {:?}))",
        path.display().to_string()
    ))
    .unwrap();
}

const DOCUMENTED: &str = r#"(define (shout text)
  "TEXT in capitals, with a \"!\" after.
   A second line, lined up under the first.
     Indented further."
  (string-append (string-upcase text) "!"))

(define (paren-char) #\()

(define (not-a-docstring)
  "This is the value.")

;; A comment, as variables have.
(define (commented x) x)

(define (both x)
  "The docstring wins."
  x)

(define-command! 'shout-line
  (lambda (count)
    "Shout the current line."
    (message "!")))

(define (whisper! count)
  "Whisper the current line."
  #t)
(define-command! 'whisper-line whisper!)
"#;

#[test]
fn docstrings_document_functions_and_commands() {
    let mut s = server("");
    s.set_size(120, 30);
    record_source(&mut s, "documented.scm", DOCUMENTED);
    s.eval(DOCUMENTED).unwrap();
    // The value is unchanged by the docstring.
    assert_eq!(s.eval("(shout \"hi\")").unwrap(), "\"HI!\"");
    type_keys(&mut s, ":help shout<ret>");
    let text = popup_text(&mut s);
    assert!(
        text.contains("TEXT in capitals, with a \"!\" after."),
        "{text}"
    );
    assert!(
        text.contains("\nA second line, lined up under the first."),
        "{text}"
    );
    assert!(text.contains("\n  Indented further."), "{text}");
    // A string that is the whole body is its value.
    type_keys(&mut s, "<esc>:help not-a-docstring<ret>");
    assert!(popup_text(&mut s).contains("Not documented."));
    // Without a docstring, the comment above.
    type_keys(&mut s, "<esc>:help commented<ret>");
    assert!(popup_text(&mut s).contains("A comment, as variables have."));
    type_keys(&mut s, "<esc>:help both<ret>");
    assert!(popup_text(&mut s).contains("The docstring wins."));
    // M-x shows a command's first line, from its lambda or its procedure.
    let doc = |s: &mut imp_server::Server, name: &str| {
        s.eval(&format!("(command-doc {name:?} (doc-lines))"))
            .unwrap()
    };
    assert_eq!(doc(&mut s, "shout-line"), "\"Shout the current line.\"");
    assert_eq!(doc(&mut s, "whisper-line"), "\"Whisper the current line.\"");
    assert_eq!(
        doc(&mut s, "shout"),
        "\"TEXT in capitals, with a \\\"!\\\" after.\""
    );
    // A character literal like #\( doesn't throw the reader.
    assert_eq!(
        doc(&mut s, "commented"),
        "\"A comment, as variables have.\""
    );
}
