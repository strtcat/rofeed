#!/usr/bin/env bash
# =============================================================================
# rofeed.sh — Mi Feed · Launcher
# Version: 0.3.0
# =============================================================================
# Thin entry point. Validates dependencies, handles CLI flags, launches
# rofi-blocks.
#
# Usage:
#   rofeed.sh             Open the interactive feed browser
#   rofeed.sh --update    Headless cache crawl only (systemd timer / cron)
#   rofeed.sh --version   Print version and exit
#   rofeed.sh --help      Show this message
#
# Installation (manual):
#   1. Place rofeed.sh and rofeed-worker.sh in the same directory
#      (e.g. ~/.local/bin/rofeed/).
#   2. Place rofeed.rasi in ~/.config/rofi/
#   3. chmod +x rofeed.sh rofeed-worker.sh
#   4. Run: ./rofeed.sh
#
# For AUR / Pacman packaging the files install to:
#   /usr/lib/rofeed/rofeed-worker.sh
#   /usr/share/rofeed/rofeed.rasi
#   /usr/bin/rofeed  (this file, renamed)
# =============================================================================

set -euo pipefail

readonly ROFEED_VERSION="0.3.0"

# ── Locate companion files ─────────────────────────────────────────────────────
# Support both personal installation (same directory) and system installation
# (/usr/lib/rofeed/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_find_worker() {
    local candidates=(
        "${SCRIPT_DIR}/rofeed-worker.sh"
        "/usr/lib/rofeed/rofeed-worker.sh"
    )
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

_find_theme() {
    local candidates=(
        "${HOME}/.config/rofi/rofeed.rasi"
        "/usr/share/rofeed/rofeed.rasi"
        "${SCRIPT_DIR}/rofeed.rasi"
    )
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

# ── CLI flags ──────────────────────────────────────────────────────────────────
case "${1:-}" in

    --update)
        WORKER=$(_find_worker) || {
            printf 'ERROR: rofeed-worker.sh not found.\n' >&2; exit 1
        }
        exec "$WORKER" --crawl-only
        ;;

    --version|-V)
        printf 'rofeed %s\n' "$ROFEED_VERSION"
        exit 0
        ;;

    --help|-h)
        cat << HELP
rofeed ${ROFEED_VERSION} — YouTube subscription feed browser

USAGE
  rofeed.sh              Open the Rofi feed browser
  rofeed.sh --update     Update cache (headless, for cron/systemd)
  rofeed.sh --version    Print version
  rofeed.sh --help       Show this help

CONFIGURATION
  Subscriptions  : ~/.config/rofeed/subscriptions
                   One channel URL per line; lines starting with # are ignored.
  Feed config    : ~/.config/rofeed/config
                   UPDATE_INTERVAL_MIN, MAX_VIDEOS_PER_CHANNEL, DATE_FROM/TO
  Playback cfg   : ~/.cache/rofeed-feed/settings  (managed by the UI)
  Rofi theme     : ~/.config/rofi/rofeed.rasi

DEPENDENCIES
  rofi (rofi-blocks-git)  yt-dlp  mpv  curl  jq  python3  flock

SYSTEMD TIMER (per-user)
  ~/.config/systemd/user/rofeed-update.service
    [Service]
    ExecStart=/path/to/rofeed.sh --update

  ~/.config/systemd/user/rofeed-update.timer
    [Timer]
    OnCalendar=*:0/30
    Persistent=true

  systemctl --user enable --now rofeed-update.timer
HELP
        exit 0
        ;;

    "")
        : # fall through to launch
        ;;

    *)
        printf 'Unknown option: %s\nTry: rofeed.sh --help\n' "$1" >&2
        exit 1
        ;;

esac

# ── Dependency checks ──────────────────────────────────────────────────────────
_require() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'ERROR: required dependency "%s" not found in PATH.\n' "$1" >&2
        exit 1
    }
}
_require rofi
_require yt-dlp
_require mpv
_require curl
_require python3
_require flock

WORKER=$(_find_worker) || {
    printf 'ERROR: rofeed-worker.sh not found.\n' >&2
    printf '  Expected at: %s/rofeed-worker.sh\n' "$SCRIPT_DIR" >&2
    printf '  Or at:       /usr/lib/rofeed/rofeed-worker.sh\n' >&2
    exit 1
}

if [[ ! -x "$WORKER" ]]; then
    printf 'ERROR: rofeed-worker.sh is not executable.\n' >&2
    printf '  Run: chmod +x "%s"\n' "$WORKER" >&2
    exit 1
fi

# ── Launch ─────────────────────────────────────────────────────────────────────
THEME=$(_find_theme) || {
    printf 'WARNING: rofeed.rasi not found — using rofi default theme.\n' >&2
    exec rofi -modi blocks -show blocks -blocks-wrap "$WORKER" -markup-rows
}

exec rofi \
    -modi blocks \
    -show blocks \
    -blocks-wrap "$WORKER" \
    -theme "$THEME" \
    -markup-rows
