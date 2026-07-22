# clipwarp

Paste clipboard images into **Claude Code on native Windows** — reliably.

Claude Code on Windows can't read an image from the clipboard — `Ctrl+V` and
`Alt+V` silently fail no matter what put the image there (Snipping Tool,
Lightshot, ShareX, "copy image" in a browser...). See anthropics/claude-code
issues
[#22068](https://github.com/anthropics/claude-code/issues/22068),
[#26679](https://github.com/anthropics/claude-code/issues/26679),
[#32791](https://github.com/anthropics/claude-code/issues/32791) — still open.
`Alt+V` only works under WSL, not native Windows.

What **always** works is a file **path** pasted as text: Claude Code auto-attaches
any `.png` / `.jpg` / `.gif` / `.webp` path in your message. `clipwarp` turns the
clipboard image into exactly that:

1. reads the clipboard image in whatever format the source app used:
   * a standard bitmap — Snipping Tool / `Win+Shift+S` (`CF_BITMAP` / `CF_DIB`)
   * a PNG stream — **Lightshot**, Chrome, Firefox, Discord, ShareX... (`PNG` / `image/png`)
   * an alpha bitmap — alpha-aware apps (`CF_DIBV5`, decoded manually since GDI+ can't)
   * an image file copied in Explorer (`CF_HDROP`)
   * HTML with an embedded `data:` URI or `file:///` src (browser fallback)
   * plain text that is already a path to an image file
2. saves it to a PNG under `%USERPROFILE%\.claude\pasted-images` (unless it is already a file),
3. puts that file path on the clipboard **as text**.

Then `Ctrl+V` in Claude Code pastes the path and the image attaches. Windows
Terminal pastes text fine, so nothing gets intercepted.

## Install

One command (PowerShell):

```powershell
irm https://raw.githubusercontent.com/botnick/clipwarp/main/install.ps1 | iex
```

Or from a clone:

```powershell
git clone https://github.com/botnick/clipwarp
.\clipwarp\install.ps1
```

The installer copies `clipwarp.ps1` to `%USERPROFILE%\.claude\scripts` and registers
a `clipwarp` function (plus a short `cw` alias) in your all-hosts PowerShell profile. Re-run it any time to
update. Open a **new** terminal afterwards (or run `. $PROFILE`) so `clipwarp` is
found.

Works in both **Windows PowerShell 5.1** and **PowerShell 7** (clipboard access
is marshalled onto an STA thread internally).

## Usage

1. Snip an image — `Win+Shift+S`, Lightshot, ShareX, or copy any image anywhere
   (or `Ctrl+C` an image file in Explorer).
2. In a terminal, run:
   ```powershell
   clipwarp    # or just: cw
   ```
3. Switch to Claude Code and press `Ctrl+V`. The image attaches.

## Auto mode — plain `Ctrl+C` → `Ctrl+V`

Skip the manual `clipwarp` step entirely:

```powershell
clipwarp watch     # start the background watcher
clipwarp status    # check it
clipwarp stop      # stop it
clipwarp autostart # start it automatically at login (unautostart to undo)
```

While the watcher runs, every image that lands on the clipboard (snip, Lightshot,
browser "copy image", `Ctrl+C` on an image file...) is converted automatically.
The clipboard is rewritten as **dual format**:

* **text** = the saved PNG's path → `Ctrl+V` in Claude Code attaches the image
* **image** = the original bitmap → `Ctrl+V` in Photoshop / Word / Discord still
  pastes the image, so nothing else breaks

Clipboards carrying meaningful text alongside an image (e.g. copying a paragraph
in Word) are left untouched — only pure image copies convert.

To start the watcher automatically at login:

```powershell
clipwarp autostart     # registers a hidden Startup shortcut; clipwarp unautostart removes it
```

## Scripting

`clipwarp` also prints the saved path, so you can use it in scripts:

```powershell
$img = clipwarp -Quiet   # -> C:\Users\you\.claude\pasted-images\clip-....png
```

Options:

| Flag | Meaning |
|------|---------|
| `-OutDir <path>` | Where to save PNGs (default `%USERPROFILE%\.claude\pasted-images`) |
| `-Quiet` | Print only the path, no status lines |
| `-KeepImage` | Dual-format write: path as text AND the original image (what the watcher uses) |

Saved PNGs older than 7 days are cleaned up automatically.

## Uninstall

```powershell
.\uninstall.ps1              # remove script + profile function
.\uninstall.ps1 -PurgeImages # also delete the saved-images folder
```

## Note: why not hook Ctrl+V itself?

Claude Code's TUI captures the keyboard, so PowerShell key bindings can't fire
while it is focused, and its own image paste (`Ctrl+V` / `Alt+V`) is broken on
native Windows for **every** screenshot tool. Rewriting the clipboard — manually
with `clipwarp`, or automatically with `clipwarp watch` — is the reliable bridge:
Windows Terminal pastes text fine, and Claude Code attaches any image path it
sees in the message.

## License

MIT
