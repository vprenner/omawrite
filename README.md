# OmawriteV

A dead-simple Markdown writing app built with Qt Quick and C++ that automatically follows system dark/light mode.

<img width="2948" height="3227" alt="screenshot-2026-06-23_15-24-08" src="https://github.com/user-attachments/assets/4e930c0d-edda-4046-b444-a59eff523329" />
<img width="2948" height="3227" alt="screenshot-2026-06-23_15-23-23" src="https://github.com/user-attachments/assets/8ced7c26-961b-4ded-b263-84403001a951" />


## Install

This is the [vprenner/omawrite](https://github.com/vprenner/omawrite) fork of
[Omawrite](https://github.com/omacom/omawrite). Its executable, desktop app ID,
icon, package, settings, and session directory use `omawritev`, so it can be
installed alongside the upstream `omawrite` package. Build and install this
fork with `./bin/install`; it is not published in the Omarchy package repository.

## Command line

`omawritev` restores the previous window's tabs, or starts with an empty tab.
`omawritev FILE ...` also opens the supplied Markdown files in tabs. Opening a
file that is already in this window selects its existing tab.
`omawritev --help` and `omawritev --version` answer in the terminal without opening a window.

## Shortcuts

- `Ctrl+S` saves. Unsaved documents use the XDG desktop portal file picker.
- `Ctrl+Shift+S` saves as.
- `Ctrl+O` opens a Markdown file through the portal picker.
- `Ctrl+P` opens the system print dialog.
- `Ctrl+T` creates a tab; `Ctrl+W` closes the current tab.
- `Ctrl+Tab` / `Ctrl+Shift+Tab` (or `Ctrl+PageDown` / `Ctrl+PageUp`) switch tabs.
- `Ctrl+N` opens a new OmawriteV window.
- `Ctrl+Z`, `Ctrl+Shift+Z`, and `Ctrl+Y` handle undo and redo.
- `Super+F` toggles fullscreen. Qt maps this key as `Meta+F`.
- `Ctrl+F` searches the document. Use `Enter` or `Ctrl+G` for the next match and `Shift+Enter` for the previous match.
- `Ctrl+H` opens find and replace.
- `Ctrl+B`, `Ctrl+I`, and `Ctrl+Shift+X` toggle bold, italic, and strikethrough Markdown. `Ctrl+K` inserts a link.
- `Ctrl+=` and `Ctrl+-` change the text size, `Ctrl+0` returns to the default.
  `Ctrl+scroll` does the same.
- `Ctrl+Shift+C` copies the rendered document as HTML, with plain text as a fallback.
- `Ctrl+?`, `Ctrl+/`, or `F1` shows the keyboard shortcut reference.
- In the unsaved-changes dialog, `Alt+C`, `Alt+D`, and `Alt+S` choose Cancel,
  Discard, and Save.

Use **Aa ⋮** in the footer to select **Narrow**, **Medium**, **Wide**, or
**Full width**, adjust the font size, and turn **Autosave named files** on or off.
These preferences are remembered and apply to every tab in the window. Medium
is the original 65-character writing width; narrow and wide use 50 and 90
characters. All widths fit within the available window space.

Autosave is on by default. Once a document has been saved to a file, edits are
auto-saved a moment after you stop typing. Turning autosave off cancels pending
saves; `Ctrl+S` still saves explicitly. Untitled drafts wait for an explicit save
so OmawriteV never picks a file name for you. OmawriteV watches every open file,
including background tabs, and warns about external changes. Autosave pauses
until you reload, keep your version, or save.

Closing the window preserves its open tabs, active tab, cursor/scroll positions,
and unsaved text. The next launch restores them. Closing an individual modified
tab asks whether to save, discard, or cancel; discarded tabs are not restored.
Each tab retains its own undo history while the app is running.

Sessions are stored as private, atomic JSON snapshots in
`$XDG_DATA_HOME/Omacom/omawritev/sessions` (normally
`~/.local/share/Omacom/omawritev/sessions`). Snapshots update after a short typing
pause and on normal window close, independently of the autosave setting. They
contain document text, including unnamed drafts. Clean files reopen from disk;
unsaved edits and missing files restore from the snapshot. Restored unsaved
changes are never auto-saved over their file: save explicitly to keep them.
On the first launch after renaming, previous fork tab sessions and preferences
are copied from `Omacom/omawrite` when the new locations are empty. The original
state is retained.

Separate running windows use separate locked sessions. Each launch restores one
available previous window session.

The font button in the footer picks the writing font from any installed text font,
and OmawriteV remembers the choice. IBM Plex Mono is the default.

Text follows the desktop text size — `omarchy display text size`, or GNOME's
`text-scaling-factor` — and re-flows without a restart. The default of 12px leaves
OmawriteV at the size it is designed around; larger and smaller sizes scale from there.
`Ctrl+=`, `Ctrl+-`, and `Ctrl+scroll` set your own size on top of that, from 50% to
300% in browser-sized steps. It is remembered for the next window you open.

## Requirements

- Qt 6.7 or newer: `qt6-base` and `qt6-declarative` (which includes Qt Quick Controls)
- `xdg-desktop-portal` and a portal backend

The IBM Plex Mono font is bundled under the SIL Open Font License 1.1; see
`fonts/OFL.txt`. The font is copyright IBM Corp.

## Build and install

For a local build, install the Qt requirements above, a C++17 compiler such as
`gcc`, and `make`. The build scripts use `qmake6` (or `qmake`), and the tests use
QtTest; both ship in `qt6-base`.

```sh
./bin/build
./bin/test
./build/omawritev
```

`bin/test` runs the Qt test suite with the offscreen platform, so it does not
require an active graphical session. To open a file with the local build:

```sh
./build/omawritev path/to/document.md
```

On Arch Linux or Omarchy, install `base-devel` for the packaging tools, then
build and install the package:

```sh
./bin/install
```

This runs the local build and `makepkg -fsi`, which installs the package through
pacman and may ask for authentication. To build a package archive for inspection
without installing it:

```sh
cd pkgbuild
makepkg -f
```
