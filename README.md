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

`vidpaper` is driven by a small toggle — run `vidpaper` to start it (▶ appears
in the menu bar), run `vidpaper` again to stop it. Stopping sends `SIGTERM` so
the app restores your original wallpaper gracefully before exiting. Save the
script below into **any directory on your `$PATH`** (e.g. `~/.local/bin`,
`/usr/local/bin`, or your own bin dir), name it `vidpaper`, `chmod +x` it, and
point `DIR` at your clone:

```sh
#!/bin/sh
# vidpaper toggle: running -> stop (graceful, restores wallpaper), stopped -> start.
DIR="$HOME/Documents/app/vidpaper"      # adjust to your clone directory
PIDFILE="$DIR/.vidpaper.pid"

running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && return 0
    pgrep -f "$DIR/vidpaper.swift" >/dev/null 2>&1
}

if running; then
    # Stop gracefully (SIGTERM) so applicationWillTerminate restores the wallpaper.
    if [ -f "$PIDFILE" ]; then
        PID=$(cat "$PIDFILE")
        kill "$PID" 2>/dev/null
        # wait up to ~5s for wallpaper restore + WallpaperAgent bounce, then force-kill if stuck
        i=0
        while [ $i -lt 10 ] && kill -0 "$PID" 2>/dev/null; do sleep 0.5; i=$((i+1)); done
        kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null
        rm -f "$PIDFILE"
    else
        pkill -f "$DIR/vidpaper.swift" 2>/dev/null
    fi
    echo "vidpaper stopped"
    exit 0
fi

# stopped -> start: clear any stale state first
if [ -f "$PIDFILE" ]; then
    kill -9 "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
fi
pkill -9 -f "$DIR/vidpaper.swift" 2>/dev/null
sleep 1

"$DIR/vidpaper.swift" > /tmp/vidpaper.log 2>&1 &
echo $! > "$PIDFILE"

sleep 1
if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "vidpaper failed to start (see /tmp/vidpaper.log)"
    exit 1
fi
echo "vidpaper started (PID $(cat "$PIDFILE"))"
```

If that bin dir isn't on your `PATH` yet (zsh is the default macOS shell):

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

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
