#!/usr/bin/env bash
# =============================================================================
# rofeed.sh — Mi Feed · Launcher
# =============================================================================
# Thin entry point. Validates paths, handles CLI flags, launches rofi-blocks.
#
# Usage:
#   rofeed.sh             → Open the interactive feed browser
#   rofeed.sh --update    → Run background cache crawl only (no UI)
#                            Useful for: systemd timer / cron
#   rofeed.sh --help      → Show this message
#
# Installation:
#   1. Place rofeed.sh and rofeed-worker.sh in the same directory.
#   2. Place rofeed.rasi in ~/.config/rofi/
#   3. chmod +x rofeed.sh rofeed-worker.sh
#   4. Run: ./rofeed.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="${SCRIPT_DIR}/rofeed-worker.sh"
THEME="${HOME}/.config/rofi/rofeed.rasi"

# ── CLI flags ──────────────────────────────────────────────────────────────────
case "${1:-}" in
    --update)
        # Headless crawl mode: update cache without opening rofi.
        # The worker handles this flag internally.
        exec "$WORKER" --crawl-only
        ;;

    --help|-h)
        cat << 'HELP'
rofeed — YouTube subscription feed browser

  rofeed.sh            Open the Rofi feed browser
  rofeed.sh --update   Update cache in background (no UI, for cron/systemd)
  rofeed.sh --help     Show this help

Config files:
  Subscriptions : ~/.config/rofeed/subscriptions
  Cache dir     : ~/.cache/rofeed-feed/
  Playback cfg  : ~/.cache/rofeed-feed/settings
  Rofi theme    : ~/.config/rofi/rofeed.rasi

Dependencies:
  rofi (rofi-blocks-git), yt-dlp, mpv, curl, jq, python3

Systemd timer example (~/.config/systemd/user/rofeed-update.service):
  [Service]
  ExecStart=/path/to/rofeed.sh --update

Systemd timer (~/.config/systemd/user/rofeed-update.timer):
  [Timer]
  OnCalendar=*:0/30
  Persistent=true
HELP
        exit 0
        ;;
esac

# ── Sanity checks ──────────────────────────────────────────────────────────────
if [[ ! -f "$WORKER" ]]; then
    echo "ERROR: rofeed-worker.sh not found at: $WORKER" >&2
    echo "  Both rofeed.sh and rofeed-worker.sh must be in the same directory." >&2
    exit 1
fi

if [[ ! -x "$WORKER" ]]; then
    echo "ERROR: rofeed-worker.sh is not executable. Run: chmod +x '$WORKER'" >&2
    exit 1
fi

if ! command -v rofi >/dev/null 2>&1; then
    echo "ERROR: rofi not found in PATH." >&2
    exit 1
fi

if [[ ! -f "$THEME" ]]; then
    echo "WARNING: Rofi theme not found at $THEME" >&2
    echo "  Copy rofeed.rasi to ~/.config/rofi/ for proper styling." >&2
    # Continue anyway; rofi will use its default theme
    exec rofi -modi blocks -show blocks -blocks-wrap "$WORKER" -markup-rows
fi

# ── Launch rofi-blocks ─────────────────────────────────────────────────────────
exec rofi \
    -modi blocks \
    -show blocks \
    -blocks-wrap "$WORKER" \
    -theme "$THEME" \
    -markup-rows
