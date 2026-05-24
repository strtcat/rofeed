# Mi Feed — YouTube Subscription Browser

A fast, keyboard-driven YouTube subscription feed for the Linux desktop.
Uses `rofi-blocks-git` as the UI, `yt-dlp` + YouTube RSS for data, and `mpv` for playback.
The local cache is the primary source of truth; background scraping is always non-blocking.

```
┌─────────────────────────────────────────────────────────────────┐
│ 🎬 Mi Feed          📦 312 vídeos — actualizando...  · 🎬 480p CC:off │
├─────────────────────────────────────────────────────────────────┤
│  ⚙  Ajustes de reproducción                                     │
│     Modo  ·  Resolución  ·  Subtítulos                          │
├──────────────┬──────────────────────────────────────────────────┤
│  [thumbnail] │ 2025-07-10  12m 34s                              │
│              │ Video title truncated to ~58 chars               │
│              │ — Channel Name                                   │
├──────────────┼──────────────────────────────────────────────────┤
│  [thumbnail] │ 2025-07-09  1h 2m 8s                             │
│  ...         │ ...                                              │
└──────────────┴──────────────────────────────────────────────────┘
```

---

## Dependencies

| Package            | Arch package              | Purpose                        |
|--------------------|---------------------------|--------------------------------|
| rofi-blocks-git    | AUR: `rofi-blocks-git`    | rofi plugin — streaming UI     |
| yt-dlp             | `yt-dlp`                  | Duration fetching, playback    |
| mpv                | `mpv`                     | Video/audio player             |
| curl               | `curl`                    | RSS + thumbnail downloads      |
| jq                 | `jq`                      | JSON parsing for yt-dlp output |
| python3            | `python` (stdlib only)    | XML parsing, JSON building     |
| libnotify          | `libnotify`               | `notify-send` desktop toasts   |

```bash
# Install all at once (Arch + AUR helper like paru or yay):
paru -S rofi-blocks-git yt-dlp mpv curl jq python libnotify
```

---

## Installation

```bash
# 1. Choose an install location
INSTALL_DIR="${HOME}/.local/bin/rofeed"
mkdir -p "$INSTALL_DIR"

# 2. Copy scripts
cp rofeed.sh         "$INSTALL_DIR/"
cp rofeed-worker.sh  "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/rofeed.sh" "$INSTALL_DIR/rofeed-worker.sh"

# 3. Copy Rofi theme
cp rofeed.rasi "${HOME}/.config/rofi/rofeed.rasi"

# 4. Add subscriptions (one URL per line, # for comments)
mkdir -p "${HOME}/.config/rofeed"
cat >> "${HOME}/.config/rofeed/subscriptions" << 'EOF'
# Paste your YouTube channel URLs here:
https://www.youtube.com/@SomeChannel
https://www.youtube.com/channel/UCxxxxxxxxxxxxxxxxxxxxxxxx
EOF

# 5. Run it
"$INSTALL_DIR/rofeed.sh"
```

---

## File layout

```
~/.local/bin/rofeed/
  rofeed.sh           ← Launcher (call this from keybind / menu)
  rofeed-worker.sh    ← rofi-blocks worker (auto-invoked by launcher)

~/.config/rofi/
  rofeed.rasi         ← Rofi theme (Catppuccin Mocha)

~/.config/rofeed/
  subscriptions        ← One YouTube URL per line

~/.cache/rofeed-feed/
  videos.tsv           ← Persistent video cache (vid_id, title, channel, date, duration)
  settings             ← Playback settings (PLAY_MODE, RESOLUTION, SUBTITLES)
  .viewmode            ← Runtime flag: "feed" | "settings" (auto-managed)

~/.cache/rofeed-channel-ids/
  <md5hash>            ← Cached channel ID per URL (avoids repeated lookups)

~/.cache/rofeed-thumbs/
  <vid_id>.jpg         ← Cached mqdefault thumbnails
```

---

## Usage

### Keyboard shortcuts inside rofi
| Key                    | Action                                   |
|------------------------|------------------------------------------|
| `↑` / `↓`             | Navigate videos / settings options       |
| `Enter`                | Play selected video  OR  apply setting   |
| `Ctrl+Enter`           | (rofi default) select without closing    |
| Type to search         | Filter the visible list                  |
| `Esc`                  | Close Mi Feed                            |

### Settings menu
Select the **⚙ Ajustes de reproducción** row at the top of the feed.

| Setting        | Options                          | Default   |
|----------------|----------------------------------|-----------|
| Play mode      | 🎬 Video + Audio / 🎵 Audio Only | Video     |
| Resolution     | 360p / 480p / 720p / 1080p       | 480p      |
| Subtitles      | ON / OFF                         | OFF       |

Settings are applied to the **next** video you play and are persisted to disk
so they survive restarts.

### Audio-only mode
Switch to **🎵 Audio Only** in settings. `mpv` will launch with `--no-video`,
making it ideal for podcasts, music or background listening without the window.

---

## Background cache update (headless)

Run the crawler without opening rofi — useful to keep the cache warm:

```bash
rofeed.sh --update
```

### Systemd user timer (recommended)

Update every 30 minutes automatically:

```ini
# ~/.config/systemd/user/rofeed-update.service
[Unit]
Description=Mi Feed — background cache update

[Service]
Type=oneshot
ExecStart=%h/.local/bin/rofeed/rofeed.sh --update
```

```ini
# ~/.config/systemd/user/rofeed-update.timer
[Unit]
Description=Mi Feed — run crawler every 30 min

[Timer]
OnCalendar=*:0/30
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl --user enable --now rofeed-update.timer
```

---

## Architecture

```
rofeed.sh                 (launcher)
  └── rofi-blocks ──────── rofeed-worker.sh    (rofi-blocks worker process)
                                │
                    ┌───────────┴───────────┐
                    │                       │
               § 3 DATA LAYER          § 4 UI LAYER
               run_crawler()           build_feed_json()
               fetch_rss()             build_settings_json()
               fetch_durations()       emit_feed()
               resolve_channel_id()    emit_settings()
               merge_tsv()             emit_if_feed()
                    │                       │
               (background             (stdout → rofi)
                subshell)
                    │
               § 5 PLAYBACK            § 6 EVENT LOOP
               launch_mpv()            handle_event()
                    │                  run_event_loop()
                    │                       │
                  nohup               (stdin ← rofi)
                  mpv &
```

**Separation of concerns:**
- **Data layer** (`§ 3`): Pure I/O — RSS, yt-dlp, disk cache. No UI calls except `emit_if_feed`.
- **UI layer** (`§ 4`): Builds JSON for rofi-blocks. No network calls.
- **Playback** (`§ 5`): Translates settings → mpv flags. Fires and forgets.
- **Event loop** (`§ 6`): Thin state machine — routes events to the right handler.

**Future service extraction:**
To run the crawler as a standalone systemd service independent of the UI:
1. Remove `emit_if_feed()` calls in `run_crawler()`.
2. Replace each with `touch "${CACHE_DIR}/.update_ready"`.
3. Add an `inotifywait` watcher in the UI that re-emits the feed when the flag appears.

---

## Rofi theme colours (Catppuccin Mocha)

| Token       | Hex       | Used for                              |
|-------------|-----------|---------------------------------------|
| `clr-base`  | `#11111b` | Window background                     |
| `clr-crust` | `#1e1e2e` | Inputbar, message bar, scrollbar      |
| `clr-surface0` | `#313244` | Selected element background        |
| `clr-sky`   | `#89dceb` | Prompt, dates, accent bar on selected |
| `clr-green` | `#a6e3a1` | Durations, active resolution          |
| `clr-mauve` | `#cba6f7` | Active selection border               |
| `clr-red`   | `#f38ba8` | "Back to feed" button                 |
| `clr-text`  | `#cdd6f4` | Titles, general text                  |
| `clr-overlay0` | `#6c7086` | Channel names, hints               |

---

## Subscriptions file format

```bash
# ~/.config/rofeed/subscriptions

# Direct /channel/UCxxx URLs skip the ID-resolution HTTP request:
https://www.youtube.com/channel/UCSJ4gkVC6NrvII8umztf0Ow

# Handle URLs are resolved once and cached by URL hash:
https://www.youtube.com/@SomeChannel

# Comment lines and blank lines are ignored.
```

---

## Troubleshooting

**Rofi opens but shows nothing:**
Make sure `rofi-blocks-git` (not just `rofi`) is installed. The `-modi blocks` flag requires the blocks plugin.

**Thumbnails don't appear:**
Check that `curl` can reach `i.ytimg.com`. Thumbnails are downloaded on first display and cached in `~/.cache/rofeed-thumbs/`.

**Durations always show `?`:**
`yt-dlp` may be blocked or rate-limited. The RSS feed still works — only durations are missing. Run `yt-dlp --version` to verify it is installed and up to date.

**mpv doesn't open:**
Check that `mpv` is installed and that `yt-dlp` is accessible to mpv (`mpv --ytdl-format=...`). mpv uses yt-dlp internally via `--script-opts=ytdl_hook-ytdl_path=yt-dlp` by default on modern builds.

**Settings not persisting:**
The settings file lives at `~/.cache/rofeed-feed/settings`. Check that the directory is writable.
