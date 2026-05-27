#!/usr/bin/env bash
# =============================================================================
# rofeed-launch.sh — Mi Feed · Launcher
# Version: 0.6.0
# =============================================================================
#
# Thin entry point.  Validates dependencies, handles CLI flags, then either:
#   (a) Opens the interactive feed browser (rofi + rofeed.sh as blocks worker)
#   (b) Runs a headless cache update (delegates to rofeed-worker.sh --crawl-only)
#
# USAGE
#   rofeed-launch.sh             Open the interactive feed browser
#   rofeed-launch.sh --update    Headless cache crawl (systemd timer / cron)
#   rofeed-launch.sh --version   Print version and exit
#   rofeed-launch.sh --help      Show this message
#
# INSTALLATION (manual)
#   1. Place all three scripts in the same directory, e.g. ~/.local/bin/rofeed/
#        rofeed-launch.sh   ← this file (bind this to a keybind)
#        rofeed.sh          ← rofi-blocks UI worker
#        rofeed-worker.sh   ← background crawler
#   2. Place rofeed.rasi in ~/.config/rofi/
#   3. chmod +x rofeed-launch.sh rofeed.sh rofeed-worker.sh
#   4. Run: ./rofeed-launch.sh
#
# SYSTEM-WIDE INSTALLATION (AUR / pacman)
#   /usr/bin/rofeed              ← this file (renamed)
#   /usr/lib/rofeed/rofeed.sh
#   /usr/lib/rofeed/rofeed-worker.sh
#   /usr/share/rofeed/rofeed.rasi
# =============================================================================

set -euo pipefail

readonly ROFEED_VERSION="0.6.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Locate companion scripts ───────────────────────────────────────────────────
_find_ui() {
    local candidates=(
        "${SCRIPT_DIR}/rofeed.sh"
        "/usr/lib/rofeed/rofeed.sh"
    )
    local f
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

_find_worker() {
    local candidates=(
        "${SCRIPT_DIR}/rofeed-worker.sh"
        "/usr/lib/rofeed/rofeed-worker.sh"
    )
    local f
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
    local f
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
  rofeed-launch.sh              Open the Rofi feed browser
  rofeed-launch.sh --update     Update cache headlessly (calls rofeed-worker.sh --crawl-only)
  rofeed-launch.sh --version    Print version
  rofeed-launch.sh --help       Show this help

FILES
  Subscriptions  : ~/.config/rofeed/subscriptions
                   One channel URL per line; lines starting with # are ignored.
  Feed config    : ~/.config/rofeed/config
                   MAX_VIDEOS_PER_CHANNEL, DATE_FROM, DATE_TO
  Playback cfg   : ~/.cache/rofeed-feed/settings  (managed by the UI ⚙ panel)
  Rofi theme     : ~/.config/rofi/rofeed.rasi

COMPONENTS
  rofeed-launch.sh   This launcher (keybind target / systemd ExecStart for --update)
  rofeed.sh          rofi-blocks UI worker (called automatically by rofi)
  rofeed-worker.sh   Background crawler (called by --update / Force Update button)

DEPENDENCIES
  rofi (rofi-blocks-git)  yt-dlp  mpv  curl  python3  flock

AUTOMATIC UPDATES (systemd user timer — see rofeed-update.service / .timer)
  systemctl --user daemon-reload
  systemctl --user enable --now rofeed-update.timer
HELP
        exit 0
        ;;

    "")
        : # fall through to launch
        ;;

    *)
        printf 'Unknown option: %s\nTry: rofeed-launch.sh --help\n' "$1" >&2
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

UI=$(_find_ui) || {
    printf 'ERROR: rofeed.sh (UI worker) not found.\n' >&2
    printf '  Expected at: %s/rofeed.sh\n' "$SCRIPT_DIR" >&2
    printf '  Or at:       /usr/lib/rofeed/rofeed.sh\n' >&2
    exit 1
}

if [[ ! -x "$UI" ]]; then
    printf 'ERROR: rofeed.sh is not executable.\n' >&2
    printf '  Run: chmod +x "%s"\n' "$UI" >&2
    exit 1
fi

# Verify the worker exists too (needed for Force Update inside the UI)
_find_worker >/dev/null || {
    printf 'WARNING: rofeed-worker.sh not found — "Force Update" will not work.\n' >&2
}

# ── Launch ─────────────────────────────────────────────────────────────────────
THEME=$(_find_theme) || {
    printf 'WARNING: rofeed.rasi not found — using rofi default theme.\n' >&2
    exec rofi \
        -modi blocks \
        -show blocks \
        -blocks-wrap "$UI" \
        -markup-rows
}

exec rofi \
    -modi blocks \
    -show blocks \
    -blocks-wrap "$UI" \
    -theme "$THEME" \
    -markup-rows
