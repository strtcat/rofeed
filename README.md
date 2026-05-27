# Mi Feed — YouTube Subscription Browser

A fast, keyboard-driven YouTube subscription feed for the Linux desktop.
Uses `rofi-blocks` as the UI, `yt-dlp` + YouTube RSS for data, and `mpv` for playback.
The local cache is the primary source of truth; background scraping is always non-blocking.

```
┌─────────────────────────────────────────────────────────────────┐
│ 🎬 Mi Feed          🎬 480p  CC:off                              │
├─────────────────────────────────────────────────────────────────┤
│  ⏺  312 vídeos en caché  ·  actualizado hace 12 min             │  ← status row
│  ⚙  Ajustes   modo · resolución · subtítulos                    │  ← compact row
├──────────────┬──────────────────────────────────────────────────┤
│  [thumbnail] │ 2025-07-10  12m 34s                              │  ┐
│              │ Video title truncated to ~58 chars               │  │ video row
│              │ — Channel Name                                   │  ┘
├──────────────┼──────────────────────────────────────────────────┤
│  [thumbnail] │ …                                                │  (×4 on screen)
└──────────────┴──────────────────────────────────────────────────┘
```

---

## Architecture — strict UI / Worker separation

```
rofeed-launch.sh          (thin launcher — keybind / systemd target)
  │
  ├─(--update)──────────► rofeed-worker.sh --crawl-only
  │                            Fetches RSS, yt-dlp durations, thumbnails.
  │                            Writes to filesystem only.  No UI output.
  │
  └─(default)──► rofi -blocks-wrap rofeed.sh
                      │
                      │  reads                     writes
                      ├──────────────────────────────────────────────────────┐
                      │  ~/.cache/rofeed-feed/videos.tsv       (read-only)   │
                      │  ~/.cache/rofeed-feed/.crawler_status  (read-only)   │
                      │  ~/.cache/rofeed-feed/.last_update     (read-only)   │
                      │  ~/.cache/rofeed-thumbs/<id>.jpg       (read-only)   │
                      │                                                       │
                      │  ~/.cache/rofeed-feed/settings         (read/write)  │
                      │  ~/.cache/rofeed-feed/.viewmode        (write only)  │
                      └──────────────────────────────────────────────────────┘
                      │
                      │  spawns (on "Force Update")
                      └──────────────────────────► rofeed-worker.sh --crawl-only
                                                       (detached background process)
```

**Key invariant:** `rofeed.sh` never makes network calls and never writes to
`videos.tsv`, `channel-ids`, or thumbnails.  `rofeed-worker.sh` never writes
to stdout (its stdout is redirected to `/dev/null`).

---

## Dependencies

| Package            | Arch package              | Purpose                        |
|--------------------|---------------------------|--------------------------------|
| rofi-blocks-git    | AUR: `rofi-blocks-git`    | rofi plugin — streaming UI     |
| yt-dlp             | `yt-dlp`                  | Duration fetching, playback    |
| mpv                | `mpv`                     | Video/audio player             |
| curl               | `curl`                    | RSS + thumbnail downloads      |
| python3            | `python` (stdlib only)    | XML parsing, JSON building     |
| libnotify          | `libnotify`               | `notify-send` desktop toasts   |
| util-linux         | `util-linux`              | `flock` (crawl lock)           |

```bash
# Install all at once (Arch + AUR helper like paru or yay):
paru -S rofi-blocks-git yt-dlp mpv curl python libnotify util-linux
```

---

## Installation

```bash
# 1. Choose an install location
INSTALL_DIR="${HOME}/.local/bin/rofeed"
mkdir -p "$INSTALL_DIR"

# 2. Copy scripts
cp rofeed-launch.sh   "$INSTALL_DIR/"
cp rofeed.sh          "$INSTALL_DIR/"
cp rofeed-worker.sh   "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/"*.sh

# 3. Copy Rofi theme
cp rofeed.rasi "${HOME}/.config/rofi/rofeed.rasi"

# 4. Add subscriptions (one URL per line, # for comments)
mkdir -p "${HOME}/.config/rofeed"
cat >> "${HOME}/.config/rofeed/subscriptions" << 'EOF'
# Paste your YouTube channel URLs here:
https://www.youtube.com/@SomeChannel
https://www.youtube.com/channel/UCxxxxxxxxxxxxxxxxxxxxxxxx
EOF

# 5. Run a first cache update (headless)
"$INSTALL_DIR/rofeed-launch.sh" --update

# 6. Open the feed
"$INSTALL_DIR/rofeed-launch.sh"
```

---

## File layout

```
~/.local/bin/rofeed/
  rofeed-launch.sh     ← Launcher (bind to keybind / add to app menu)
  rofeed.sh            ← rofi-blocks UI worker (invoked automatically by rofi)
  rofeed-worker.sh     ← Background crawler (invoked by --update / Force Update)

~/.config/rofi/
  rofeed.rasi          ← Rofi theme (Catppuccin Mocha, dual row heights)

~/.config/rofeed/
  subscriptions        ← One YouTube channel URL per line
  config               ← MAX_VIDEOS_PER_CHANNEL, DATE_FROM, DATE_TO

~/.cache/rofeed-feed/
  videos.tsv           ← Video cache (vid_id, title, channel, date, duration)
  settings             ← Playback settings: PLAY_MODE, RESOLUTION, SUBTITLES
  .crawler_status      ← Live crawl status (read by UI, written by worker)
  .last_update         ← Unix timestamp of last successful crawl
  .crawl.log           ← Rolling crawl log (last 500 lines kept)
  .viewmode            ← Runtime flag: "feed" | "settings" (UI-owned)

~/.cache/rofeed-channel-ids/
  <md5hash>            ← Cached UCxxx ID per URL (avoids repeated lookups)

~/.cache/rofeed-thumbs/
  <vid_id>.jpg         ← Cached mqdefault thumbnails
```

---

## Usage

### Keyboard shortcuts inside rofi
| Key               | Action                                  |
|-------------------|-----------------------------------------|
| `↑` / `↓`        | Navigate videos / settings options      |
| `Enter`           | Play selected video  OR  apply setting  |
| Type to search    | Filter the visible list                 |
| `Esc`             | Close Mi Feed                           |

### Settings menu
Select the **⚙ Ajustes** row at the top of the feed.

| Setting    | Options                            | Default  |
|------------|------------------------------------|----------|
| Play mode  | 🎬 Video + Audio / 🎵 Audio Only   | Video    |
| Resolution | 360p / 480p / 720p / 1080p         | 480p     |
| Subtitles  | ON / OFF                           | OFF      |

Settings are applied to the **next** video you play and are persisted to disk.

---

## Background cache update (headless)

```bash
# Run a one-shot update without opening rofi:
rofeed-launch.sh --update

# Watch the live log:
tail -f ~/.cache/rofeed-feed/.crawl.log
```

### Systemd user timer (recommended)

```ini
# ~/.config/systemd/user/rofeed-update.service
[Unit]
Description=rofeed — background cache update

[Service]
Type=oneshot
ExecStart=%h/.local/bin/rofeed/rofeed-worker.sh --crawl-only
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=1800
```

```ini
# ~/.config/systemd/user/rofeed-update.timer
[Unit]
Description=rofeed — run crawler every 30 min
Requires=rofeed-update.service

[Timer]
OnCalendar=*:0/30
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now rofeed-update.timer
```

---

## Row height in rofi — how it works

The theme (`rofeed.rasi`) uses a single `element` style for all rows.
Two different heights emerge naturally from whether a row carries an icon:

- **Video rows** include `"icon": "/path/to/thumb.jpg"` in their JSON.
  The `element-icon` widget renders at `@icon-size` (default 100 px) and
  the row expands to fit, plus `@element-pad-v` (10 px) top and bottom.
  Total ≈ **120 px** per video row → 4 rows comfortably fill a 1080p window.

- **Status / Settings / Section rows** have no `"icon"` field.
  rofi collapses the icon widget to zero size and the row takes its natural
  text height (≈ 28–32 px for a single line with `@compact-pad-v = 5 px`).

To fit more or fewer video rows, adjust `@icon-size` in `rofeed.rasi`.
Each 10 px reduction in icon-size gains roughly half a visible row.

---

## Rofi theme colours (Catppuccin Mocha)

| Token          | Hex       | Used for                              |
|----------------|-----------|---------------------------------------|
| `clr-base`     | `#11111b` | Window background                     |
| `clr-crust`    | `#1e1e2e` | Inputbar, message bar                 |
| `clr-surface0` | `#313244` | Selected element background           |
| `clr-sky`      | `#89dceb` | Prompt, dates, settings accent        |
| `clr-green`    | `#a6e3a1` | Durations, active resolution          |
| `clr-mauve`    | `#cba6f7` | Active selection border               |
| `clr-red`      | `#f38ba8` | "Back to feed" button                 |
| `clr-text`     | `#cdd6f4` | Titles, general text                  |
| `clr-overlay0` | `#6c7086` | Channel names, hints                  |
| `clr-peach`    | `#fab387` | Status bar while crawling, Force Upd. |

---

## Subscriptions file

```bash
# ~/.config/rofeed/subscriptions

# /channel/UCxxx URLs skip the ID-resolution HTTP request:
https://www.youtube.com/channel/UCSJ4gkVC6NrvII8umztf0Ow

# Handle (@) URLs are resolved once and cached by URL md5 hash:
https://www.youtube.com/@SomeChannel

# Comment lines and blank lines are ignored.
```

---

## Troubleshooting

**Rofi opens but shows nothing:**
Make sure `rofi-blocks-git` (not plain `rofi`) is installed and the `-modi blocks`
flag is supported.

**Empty cache after first run:**
Check `~/.cache/rofeed-feed/.crawl.log` for error details.  Common causes:
- No subscriptions file at `~/.config/rofeed/subscriptions`
- Network error fetching RSS (try `curl https://www.youtube.com/feeds/videos.xml?channel_id=UC…`)
- `yt-dlp` blocked or outdated (run `yt-dlp -U`)

**Thumbnails don't appear:**
`curl` must reach `i.ytimg.com`.  Thumbnails are downloaded during the crawl
and cached in `~/.cache/rofeed-thumbs/`.

**Durations always show `?`:**
`yt-dlp` may be rate-limited.  RSS data (title, date, channel) still works.
Run `yt-dlp --version` to verify the installation.

**Settings not persisting:**
Settings live at `~/.cache/rofeed-feed/settings`.  Verify the directory is writable.

**"Force Update" button does nothing:**
`rofeed-worker.sh` must be in the same directory as `rofeed.sh` or at
`/usr/lib/rofeed/rofeed-worker.sh`.
