# vidpaper

A single-file Swift menubar tool for macOS that plays mp4 / mov / m4v as a
desktop wallpaper — per screen, with independent volume / pause / restore
state, and a backup/restore round-trip that preserves your original
(including dynamic) system wallpaper on quit.

## Requirements

macOS with Xcode Command Line Tools (`swift --version` to check;
`xcode-select --install` if missing). No third-party dependencies.

## Install

```sh
git clone https://github.com/FishfishCai/vidpaper.git
chmod +x vidpaper/vidpaper.swift
```

## Start/stop toggle command

The repo ships **`vidpaper-toggle`**, a start/stop wrapper — run it once to
start (▶ appears in the menu bar), run it again to stop (it sends `SIGTERM` so
the app restores your original wallpaper gracefully). It locates
`vidpaper.swift` next to itself, so just symlink it onto a directory in your
`$PATH`:

```sh
ln -sf "$(pwd)/vidpaper/vidpaper-toggle" ~/.local/bin/vidpaper
```

Now `vidpaper` starts it and `vidpaper` again stops it.

## Usage

Once started, the menu bar ▶ opens a per-screen menu:

```
— Built-in Retina Display (1) —     header
Select Wallpaper…                   open NSOpenPanel, pick mp4 / mov / m4v
Volume  100%   [====●]              0 / 20 / 40 / 60 / 80 / 100 (6 ticks)
Pause / Resume                      toggle this screen's playback
Stop / Restore                      stop tears down; Restore re-plays the last video
─────
— External Display (2) —            ... per-screen block, independent state ...
─────
Language ▸   ✓ 中文  English
Quit ⌘Q
```

Per-screen state is independent: each display has its own current video,
last-played path, volume, and pause/resume state.

## State files

```
~/.config/vidpaper/
├── state.json                  per-screen lastPath / volume / language
├── black.png                   2×2 black PNG used as system wallpaper placeholder
└── wallpaper-backup.plist      snapshot of macOS Index.plist taken at first launch
```

Delete the directory to reset. The backup plist is recreated from the current
macOS wallpaper config the next time you launch vidpaper.

## License

MIT — see [LICENSE](./LICENSE).
