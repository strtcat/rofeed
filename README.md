# rofeed — YouTube Subscription Feed in Rofi

A lightweight, keyboard-driven YouTube subscription feed browser for Linux.
Fetches your channels' RSS feeds, caches them locally, and lets you browse
and play videos via mpv — all inside a Rofi pop-up.

```
┌──────────────────────────────────────────────────────────────┐
│ 🎬 Mi Feed                         Buscar...                 │
│ 🎬 480p  CC:off                                              │
├──────────────────────────────────────────────────────────────┤
│ ✅  312 vídeos en caché  ·  actualizado hace 3 min           │
│ ⚙  Ajustes   modo · resolución · subtítulos · intervalo      │
│ ┌──────────┐  2025-01-20 14:32   8m 42s                      │
│ │ thumbnail│  My favourite video title                        │
│ └──────────┘  — Channel Name                                 │
│  ...                                                          │
└──────────────────────────────────────────────────────────────┘
```

---

## Features

- Browse YouTube subscriptions in a fast Rofi interface with thumbnail previews
- Play in **video mode** (with resolution selector: 360p / 480p / 720p / 1080p) or **audio-only** mode
- Optional **subtitle** support (auto-subs, es/en priority)
- **Incremental cache**: only fetches new videos on each update — polite rate-limiting with `sleep 0.4` between yt-dlp calls
- **Live crawl progress**: the status bar updates every ~2 seconds while a crawl runs (`🔄 Actualizando… canal 3/12`)
- Background updates via **systemd user timer** (headless, every 30 min by default)
- Per-channel video cap and optional **date range filter** (configurable in `~/.config/rofeed/config`)
- Settings panel accessible from inside the UI (⚙ row)
- Notifications via `notify-send` when playback starts

---

## Dependencies

| Tool | Required | Notes |
|---|---|---|
| `rofi` + `rofi-blocks` plugin | **yes** | AUR: `rofi-blocks-git` |
| `mpv` | **yes** | playback |
| `yt-dlp` | **yes** | duration fetch + mpv format string |
| `curl` | **yes** | RSS + thumbnail downloads |
| `python3` | **yes** | XML parsing, JSON building, cache ops |
| `flock` | **yes** | prevents concurrent crawls (`util-linux`) |
| `notify-send` | optional | playback notifications |

---

## Installation

### Manual (recommended for personal use)

```bash
# 1. Create install directory
mkdir -p ~/.local/bin/rofeed

# 2. Copy the two scripts
cp rofeed.sh     ~/.local/bin/rofeed/
cp rofeed-worker.sh ~/.local/bin/rofeed/

# 3. Make them executable
chmod +x ~/.local/bin/rofeed/rofeed.sh ~/.local/bin/rofeed/rofeed-worker.sh

# 4. Install the Rofi theme
mkdir -p ~/.config/rofi
cp rofeed.rasi ~/.config/rofi/

# 5. (Optional) Add to PATH
echo 'export PATH="$HOME/.local/bin/rofeed:$PATH"' >> ~/.bashrc
```

### System-wide (Pacman / AUR packaging)

The launcher looks for files in these fallback locations automatically:

| File | Path |
|---|---|
| `rofeed-worker.sh` | `/usr/lib/rofeed/rofeed-worker.sh` |
| `rofeed.rasi` | `/usr/share/rofeed/rofeed.rasi` |
| Launcher | `/usr/bin/rofeed` |

---

## Quick Start

```bash
# First run — opens the UI (empty cache)
rofeed.sh

# Add subscriptions (one URL per line, # lines are comments)
nano ~/.config/rofeed/subscriptions

# Force an immediate cache update from the UI:
#   → open rofeed, click the status bar row or ⚙ Ajustes → Forzar actualización

# Or update headlessly from the terminal:
rofeed.sh --update
```

---

## Subscriptions file

`~/.config/rofeed/subscriptions` — one channel URL per line.

```
# My subscriptions
https://www.youtube.com/@LinusTechTips
https://www.youtube.com/channel/UCVls1GmFKf6WlTraIb_IaJg
https://www.youtube.com/@3blue1brown
# https://www.youtube.com/@paused  ← commented out
```

Supported URL formats:
- `https://www.youtube.com/@handle`
- `https://www.youtube.com/channel/UCxxxxxxxxxxxxxxxx` (channel ID resolved from URL and cached)
- Any URL whose page contains `"externalId":"UCxxx"` in the HTML

---

## Configuration

`~/.config/rofeed/config` is written on first run with defaults. Edit it to
customise behaviour; changes take effect next time rofeed opens or `--update` runs.

```bash
# Minutes between background refresh cycles (systemd timer interval).
# Set to 0 to always refresh when opening the UI.
# Minimum recommended: 5 (YouTube throttles RSS feeds server-side).
UPDATE_INTERVAL_MIN="30"

# Maximum videos to keep per channel. 0 = unlimited.
MAX_VIDEOS_PER_CHANNEL="30"

# Only show videos within this date range. Leave blank to disable.
# Format: YYYY-MM-DD
DATE_FROM=""
DATE_TO=""
```

Playback settings (mode, resolution, subtitles) are managed by the in-app ⚙ panel
and saved to `~/.cache/rofeed-feed/settings`.

---

## Systemd user timer (background updates)

Install the timer so the cache is always fresh when you open the UI:

```bash
# Create the service unit
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/rofeed-update.service << 'EOF'
[Unit]
Description=Mi Feed — background cache update

[Service]
Type=oneshot
ExecStart=%h/.local/bin/rofeed/rofeed.sh --update
EOF

# Create the timer unit (runs every 30 min, persistent across sleep/reboot)
cat > ~/.config/systemd/user/rofeed-update.timer << 'EOF'
[Unit]
Description=Mi Feed — run crawler every 30 min

[Timer]
OnCalendar=*:0/30
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Enable and start
systemctl --user daemon-reload
systemctl --user enable --now rofeed-update.timer

# Check status
systemctl --user status rofeed-update.timer
```

> **Note:** When the timer runs, the crawler writes its status to
> `~/.cache/rofeed-feed/.crawler_status`. If the UI is open at the same time,
> the live status bar updates automatically (polled every ~2 s).

---

## File layout

```
~/.config/rofeed/
├── config              Main configuration
└── subscriptions       Channel URLs (one per line)

~/.cache/rofeed-feed/
├── videos.tsv          Main video cache (tab-separated: id, title, channel, date, duration)
├── settings            Playback settings (managed by UI)
├── .last_update        Unix timestamp of last successful crawl
├── .crawler_status     Real-time crawler state (read by UI polling loop)
├── .crawl.lock         flock file — prevents concurrent crawlers
└── .viewmode           Current UI view: "feed" or "settings"

~/.cache/rofeed-channel-ids/
└── <md5>.txt           Resolved UCxxxxxx IDs (one file per channel URL, cached forever)

~/.cache/rofeed-thumbs/
└── <vid_id>.jpg        mqdefault thumbnails (downloaded in parallel on first display)
```

---

## Usage

```
rofeed.sh               Open the interactive feed browser
rofeed.sh --update      Headless cache crawl only (for systemd / cron)
rofeed.sh --version     Print version and exit
rofeed.sh --help        Show help
```

### Inside the UI

| Action | Result |
|---|---|
| **Enter** on a video | Launch mpv |
| **Enter** on the status bar row | Force cache update |
| **Enter** on ⚙ Ajustes | Open settings panel |
| Type in the search bar | Filter videos by title / channel |
| **Esc** | Close |

### Settings panel

| Option | Values |
|---|---|
| Mode | 🎬 Video + Audio / 🎵 Audio Only |
| Subtitles | ON / OFF |
| Resolution | 360p / 480p / 720p / 1080p |
| Update interval | Always / 5 min / 10 min / 15 min / 30 min / 1 h / 3 h |
| Forzar actualización | Starts an immediate crawl |

---

## How the live crawl progress works

When you trigger "Forzar actualización":

1. The main process writes `running:0:?` to `.crawler_status` and immediately renders the feed (showing `🔄 Actualizando… canal 0/?`).
2. A background subshell starts `run_crawler`. As it processes each channel it updates `.crawler_status` → `running:1:12`, `running:2:12`, etc.
3. The event loop uses `read -t 2` — it wakes up every 2 seconds even when rofi sends no events. On each timeout it reads `.crawler_status` and, if a crawl is running, pushes a fresh JSON update to rofi (updating the status bar in real time).
4. Only the **main process** writes to stdout. The crawler subshell never touches stdout, eliminating any race conditions.
5. When the crawl finishes (status becomes `done:N`), the next poll emits the final feed and resets the status to `idle`.

---

## Troubleshooting

**No videos appear after `--update`**
- Check `~/.config/rofeed/subscriptions` exists and has non-commented URLs.
- Run `rofeed.sh --update` in a terminal and look for errors.

**"rofi-blocks not found" / rofi opens without the feed**
- Install `rofi-blocks-git` from the AUR: `paru -S rofi-blocks-git`

**Thumbnails don't load**
- Requires `curl` to be in PATH and network access to `i.ytimg.com`.
- Thumbnails are cached in `~/.cache/rofeed-thumbs/` on first display.

**Crawl takes a long time**
- Duration fetching uses `yt-dlp` per new video with a 0.4 s delay between calls (to be polite to YouTube). This is intentional.
- Only *new* videos (not already in cache) require a yt-dlp call.

**`rofeed-worker.sh not found`**
- Make sure both scripts are in the same directory, or that `rofeed-worker.sh` exists at `/usr/lib/rofeed/rofeed-worker.sh`.

---

## Version history

| Version | Changes |
|---|---|
| 0.5.0 | Fix live crawl progress: `read -t 2` polling loop replaces blocking stdin read; crawler subshell no longer writes to stdout (eliminates race condition) |
| 0.4.0 | Incremental cache (only new videos fetched); settings panel; date filter; systemd timer |
| 0.3.0 | Initial public release |
