---
status: accepted
issue: https://github.com/apisandipas/imp/issues/70
summary: "Pickers put what you pick often and lately first: M-x, find-file, project switching and the other completing-read menus, from a history kept in the state directory."
anchors: [runtime/completion.scm, crates/imp-server/src/fuzzy.rs]
---
# Completion by use

What you pick in a menu is remembered, and the menus put what you use most and most recently first, as zoxide and Firefox's address bar do ("frecency").

## Behaviour

- **Every picker.** Each `completing-read` menu remembers what you pick in it: `M-x`, `find-file` (`SPC SPC`), `project-switch` (`SPC p p`), the describe commands, themes, `switch-terminal` and the rest. Each kind of menu has its own history, so a command used often doesn't rank a file. Menus whose order is already by use keep their own: `recent-files` (`SPC f r`) and `switch-buffer` (`SPC b b`). Completion at point (in insert state) isn't a picker and is unchanged.
- **The score.** Each pick adds one to the candidate's count. Its score is the count weighed by how long ago it was last picked: ×4 within the hour, ×2 within the day, ×1 within the week, ×½ after that.
- **Nothing typed.** The candidates you've picked come first, highest score first (the most recent first on equal scores), then the rest in the menu's own order.
- **Typing.** A candidate typed in full comes first (`install-grammar` runs `install-grammar`, however often you run `install-grammars`), then the best matches. Among equally good matches, the one with the higher score comes first, then the shorter, then the menu's order, as now.
- **Files by their full path.** `find-file` remembers files by their full path, so a file you open often ranks first wherever you search from, as long as it is under the directory listed.
- **Kept.** The history is saved in the state directory (`completion-history`), so it survives restarts; each menu keeps the 500 candidates with the highest scores. Candidates that no longer exist (a removed command, a deleted file) are skipped when the menu opens.
- **Turning it off.** `(set-option! 'completion-history #f)` stops recording and ranking; the menus show their own order.
- **Forgetting.** `M-x clear-completion-history` forgets it all.

## Keys and options

`completion-history` (on). `clear-completion-history`.

## Out of scope

- Ranking completion at point (insert state) by use.
- Sharing the history between machines, or between daemon clients' users (a daemon has one history).
- Removing one candidate from the history from inside the menu.
