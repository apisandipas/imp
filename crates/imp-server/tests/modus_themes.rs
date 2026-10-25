//! The modus-themes package (packages/modus-themes): its faces' colors
//! against the values in modus-themes.el 5.3.0, its options and toggle.

mod common;

use common::*;

fn modus(theme: &str) -> imp_server::Server {
    let mut s = server("");
    s.eval(&format!(
        "(use-package! 'modus-themes) (load-theme! '{theme})"
    ))
    .unwrap();
    s
}

/// Face `name`'s spec, as set-face! would take it.
fn spec(s: &mut imp_server::Server, name: &str) -> String {
    s.eval(&format!("(face-spec \"{name}\")"))
        .unwrap()
        .trim_matches('"')
        .to_string()
}

#[test]
fn vivendi_s_code_and_frame_are_modus_s_colors() {
    let mut s = modus("modus-vivendi");
    // Each face against the color Modus Vivendi gives the same thing:
    // default, font-lock-keyword-face, and so on.
    for (face, want) in [
        ("normal", "fg=#ffffff bg=#000000"),
        ("syntax.keyword", "fg=#b6a0ff"),
        ("syntax.string", "fg=#79a8ff"),
        ("syntax.comment", "fg=#989898"),
        ("syntax.comment.documentation", "fg=#9ac8e0"),
        ("syntax.function", "fg=#feacd0"),
        ("syntax.function.builtin", "fg=#f78fe7"),
        ("syntax.type", "fg=#6ae4b9"),
        ("syntax.constant", "fg=#00bcff"),
        ("syntax.function.macro", "fg=#ff7f86"),
        ("syntax.punctuation", "fg=#ffffff"),
        ("visual", "fg=#ffffff bg=#5a5a5a"),
        ("cursorline", "bg=#2f3849"),
        ("line-number-current", "fg=#ffffff bg=#535353 bold"),
        ("search-current", "fg=#ffffff bg=#7a6100"),
        ("separator", "fg=#646464"),
    ] {
        assert_eq!(spec(&mut s, face), want, "{face}");
    }
}

#[test]
fn operandi_s_code_and_frame_are_modus_s_colors() {
    let mut s = modus("modus-operandi");
    for (face, want) in [
        ("normal", "fg=#000000 bg=#ffffff"),
        ("syntax.keyword", "fg=#531ab6"),
        ("syntax.string", "fg=#3548cf"),
        ("syntax.comment", "fg=#595959"),
        ("syntax.comment.documentation", "fg=#2a5045"),
        ("syntax.function", "fg=#721045"),
        ("syntax.function.builtin", "fg=#8f0075"),
        ("syntax.type", "fg=#005f5f"),
        ("syntax.constant", "fg=#0000b0"),
        ("visual", "fg=#000000 bg=#bdbdbd"),
        ("cursorline", "bg=#dae5ec"),
        ("line-number-current", "fg=#000000 bg=#c4c4c4 bold"),
        ("search-current", "fg=#000000 bg=#f3d000"),
    ] {
        assert_eq!(spec(&mut s, face), want, "{face}");
    }
}

#[test]
fn a_modus_theme_is_drawn_in_its_colors_and_leaves_nothing_behind() {
    let mut s = modus("modus-vivendi");
    let f = s.frame();
    assert_eq!(f.rows[0][0].style.bg, Some(imp_core::Color::Rgb(0, 0, 0)));
    s.eval("(load-theme! 'one-dark)").unwrap();
    assert_eq!(spec(&mut s, "syntax.function.builtin"), "#false");
    assert_eq!(spec(&mut s, "normal"), "fg=#abb2bf bg=#282c34");
}

#[test]
fn the_rest_of_imp_is_in_modus_s_colors_too() {
    // A face or two from each part, against Modus Vivendi's mode-line,
    // corfu, which-key, flymake, dired, org, magit, diff and diff-hl.
    let mut s = modus("modus-vivendi");
    for (face, want) in [
        ("status", "fg=#ffffff bg=#505050"),
        ("status-inactive", "fg=#969696 bg=#2d2d2d"),
        ("status.mode.insert", "fg=#9fefff bg=#505050 bold"),
        ("popup", "fg=#ffffff bg=#0c0c0c"),
        ("which-key.key", "fg=#00bcff bold"),
        ("diagnostic.error", "fg=#ff5f5f underline"),
        ("dired.directory", "fg=#00bcff"),
        ("calendar.today", "fg=#000000 bg=#ffffff"),
        ("org.level1", "fg=#ffffff bold"),
        ("org.todo", "fg=#ff5f59"),
        ("git.branch", "fg=#00bcff"),
        ("start.key", "fg=#00bcff bold"),
        ("diff.added", "fg=#a0e0a0 bg=#00381f"),
        ("git-gutter.added", "fg=#237f3f"),
    ] {
        assert_eq!(spec(&mut s, face), want, "{face}");
    }
    let mut s = modus("modus-operandi");
    for (face, want) in [
        ("status", "fg=#000000 bg=#c8c8c8"),
        ("popup", "fg=#000000 bg=#f3f3f3"),
        ("diagnostic.error", "fg=#d00000 underline"),
        ("diff.added", "fg=#005000 bg=#c1f2d1"),
    ] {
        assert_eq!(spec(&mut s, face), want, "{face}");
    }
}

#[test]
fn terminal_colors_are_modus_s_term_colors() {
    let mut s = modus("modus-vivendi");
    let colors = s
        .eval("(terminal-palette (car (hash-ref *themes* 'modus-vivendi)))")
        .unwrap();
    // red, then bright black and bright red.
    let colors: Vec<&str> = colors.split('"').filter(|c| c.starts_with('#')).collect();
    assert_eq!(colors.len(), 16, "{colors:?}");
    assert_eq!(colors[1], "#ff5f59");
    assert_eq!(colors[8], "#595959");
    assert_eq!(colors[9], "#ff6b55");
}

#[test]
fn bold_and_italic_constructs_redraw_the_theme_in_use() {
    let mut s = modus("modus-vivendi");
    assert_eq!(spec(&mut s, "syntax.keyword"), "fg=#b6a0ff");
    s.eval("(set-option! 'modus-themes-bold-constructs #t)")
        .unwrap();
    assert_eq!(spec(&mut s, "syntax.keyword"), "fg=#b6a0ff bold");
    assert_eq!(spec(&mut s, "syntax.type.builtin"), "fg=#f78fe7 bold");
    assert_eq!(spec(&mut s, "syntax.comment"), "fg=#989898");
    s.eval("(set-option! 'modus-themes-italic-constructs #t)")
        .unwrap();
    assert_eq!(spec(&mut s, "syntax.comment"), "fg=#989898 italic");
    assert_eq!(
        spec(&mut s, "syntax.comment.documentation"),
        "fg=#9ac8e0 italic"
    );
    // The other theme has them too when it's loaded.
    s.eval("(load-theme! 'modus-operandi)").unwrap();
    assert_eq!(spec(&mut s, "syntax.keyword"), "fg=#531ab6 bold");
    // And off again.
    s.eval("(set-option! 'modus-themes-bold-constructs #f)")
        .unwrap();
    assert_eq!(spec(&mut s, "syntax.keyword"), "fg=#531ab6");
}

#[test]
fn constructs_set_before_the_theme_loads_count() {
    let mut s = server("");
    s.eval(
        "(use-package! 'modus-themes)
         (set-option! 'modus-themes-italic-constructs #t)
         (load-theme! 'modus-vivendi)",
    )
    .unwrap();
    assert_eq!(spec(&mut s, "syntax.comment"), "fg=#989898 italic");
}

#[test]
fn palette_overrides_change_every_face_using_a_name() {
    let mut s = modus("modus-vivendi");
    // A mapping to another name, and a named color to a color.
    s.eval(r##"(set-option! 'modus-themes-common-palette-overrides '((keyword red) (bg-main "#111111")))"##)
        .unwrap();
    assert_eq!(spec(&mut s, "syntax.keyword"), "fg=#ff5f59");
    assert_eq!(spec(&mut s, "normal"), "fg=#ffffff bg=#111111");
    // bg-main is what org.hide uses too.
    assert_eq!(spec(&mut s, "org.hide"), "fg=#111111");
    // A theme's own list wins over the common one, for that theme only.
    s.eval("(set-option! 'modus-vivendi-palette-overrides '((keyword green)))")
        .unwrap();
    assert_eq!(spec(&mut s, "syntax.keyword"), "fg=#44bc44");
    s.eval("(load-theme! 'modus-operandi)").unwrap();
    assert_eq!(spec(&mut s, "syntax.keyword"), "fg=#a60000");
}

#[test]
fn an_unknown_override_is_an_error_naming_it() {
    let mut s = modus("modus-vivendi");
    let err = s
        .eval("(set-option! 'modus-themes-common-palette-overrides '((keywrd red)))")
        .unwrap_err();
    assert!(err.contains("no color named keywrd"), "{err}");
    let err = s
        .eval("(set-option! 'modus-themes-common-palette-overrides '((keyword nope)))")
        .unwrap_err();
    assert!(err.contains("no color named nope"), "{err}");
    // A good list afterwards still takes.
    s.eval("(set-option! 'modus-themes-common-palette-overrides '((keyword red)))")
        .unwrap();
    assert_eq!(spec(&mut s, "syntax.keyword"), "fg=#ff5f59");
}
