---
type: Effort
status: active
specs: ["[[spec/overlays]]"]
issue: https://github.com/apisandipas/imp/issues/123
frozen:
  docs/specs/overlays.md: bc97912d2e13
---
# Overlay owner

One Scheme owner for the popup slot and the key interceptor, with every overlay moved onto it.

## Approach

`runtime/overlay.scm` loads right after `core.scm`. Adding it to `RUNTIME` in `lib.rs` is the only Rust change; the popup primitives stay as they are. The owner comes first, with its own tests. `show-popup!` and the key routing in `handle-top-level-key!` move onto it in the same task, because the owner's key routing replaces the `*popup-shown*` check. Then the overlays move over in groups, each with its tests: which-key, then menus and prompts, then the insert completion menu, then the command-line overlays. Every existing test passes unchanged along the way. The last task adds a test that fails when runtime code outside `overlay.scm` touches the popup slot or `*key-interceptor*`; snippet placeholders are allowed to set the interceptor.

## Tasks

- [x] Owner: `runtime/overlay.scm` with `overlay-open!`, `overlay-update!`, `overlay-close!` and `overlay-open?`, added to `RUNTIME` after `core.scm`.
  - Opening sets every field. A new overlay replaces the open one, and the replaced one's `'on-close` runs.
  - A `show-popup!` popup waits behind an overlay that takes keys, and only the last one waits.
  - Scrolling shows at most 10 rows, and no more than the window height less 2.
  - The open overlay's `'keys` gets each key first, in `handle-top-level-key!`.
  - `show-popup!`, `close-popup!` and LSP hover move onto the owner.
  - Tested in a new `tests/overlay.rs`.
  - Docs: the anchors go on the spec; `runtime/CONTEXT.md` gets the load order and `*key-interceptor*` as low-level; a new `ref-overlays.md` page; the look and buffers-and-windows pages re-stamped.
- [x] Which-key: the leader and `SPC m`, Vim prefixes, Emacs prefixes and the file tree's help go through the owner. Tests: a late `show-popup!` doesn't take the leader's popup; the file tree's `?` shows its help again after another overlay closed it.
- [x] Menus and prompts: `menu!`, `confirm!`, describe-key and dired's `:w` go through the owner. Test: `<esc>` at dired's `:w` closes the popup and the y/n question together.
- [x] Insert completion: the insert menu and the C-x keys go through the owner and its scrolling. Test: the menu opening during a snippet leaves the snippet's keys working.
- [x] Command-line overlays: the command-line menu, the wildmenu, completing-read and the calendar give the owner their rows and scroll through it. Test: the command-line menu keeps the selected line in view in a short window.
- [ ] Mouse and the rest:
  - Clicks follow `'click-closes`.
  - The remaining callers move over: mouse, mcp, the `popup-lines` readers.
  - A test fails on any runtime or package code outside `overlay.scm` that calls `set-popup!`, `set-popup-place!` or `set-popup-selected!`, or sets `*key-interceptor*`. Snippets are allowed to set the interceptor.

## Notes
