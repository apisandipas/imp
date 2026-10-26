# imp-gui

The window client, a library behind the `gui` feature (on by default): winit, wgpu, glyphon. It runs the server in-process or attaches with `--connect`, and is just another client of the protocol ([[0007-the-window-client-first]]).

- `--font`, `--font-size`, `--scale` (or `IMP_GUI_SCALE`); `C-=`, `C--` and `C-0` zoom; `S-<insert>` and `C-S-v` (`Cmd-v` on macOS) paste the clipboard, read beside the window, as a `Paste`. On connect, resize and zoom it sends `Hello` and `Cell` so the server lays out heights and dividers for it.
- Cells in the `normal` background are left undrawn and the padding is cleared to it, premultiplied with `background-opacity`; the surface is see-through only below opacity 1.
- `imp --screenshot OUT.png` draws off-screen; that is how the window is tested without a display, with Mesa's lavapipe (`VK_ICD_FILENAMES=<mesa>/share/vulkan/icd.d/lvp_icd.x86_64.json`) and `--font-file` pointing at a monospace TTF. Run it with a temporary `XDG_CONFIG_HOME` and `XDG_STATE_HOME`, or your recent files appear in the shot.
