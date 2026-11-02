---
type: Effort
status: active
specs: ["[[spec/buffers-and-windows]]", "[[spec/look]]"]
issue: https://github.com/apisandipas/imp/issues/156
frozen:
  docs/specs/buffers-and-windows.md: 76dc5e32ba7a
  docs/specs/look.md: 5f0cc2cbffc2
---
# Control chars in their own face

## Approach

The renderer already draws a control char in buffer text as its caret notation (`caret` in `render.rs`). `char_styles` paints each char's style bottom up: syntax first, then highlight layers. The `special-char` face goes in between, over the syntax face of each control char, so syntax can't hide it while the visual selection and search matches still show over it. Because both clients draw the same `Frame`, nothing changes client side. `describe-face` lists it through `faces_at`. Only buffer text gets the face: the status line, messages and popups keep their own faces, which mark them apart already.

## Tasks

- [x] Paint control chars in buffer text with `special-char` over their syntax face, list it in `describe-face`, with a render test that the caret cells carry the face, syntax or not.
- [ ] Set `special-char` in every bundled theme: cyan from the palette in `theme.scm`, Modus's `keybind` (bold with bold constructs, as Emacs's `escape-glyph`) in modus-themes, with a test of the Modus colors; update `ref-buffers-and-windows`, `ref-look` and the configuring guide, stamped.
