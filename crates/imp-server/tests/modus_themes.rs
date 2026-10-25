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
