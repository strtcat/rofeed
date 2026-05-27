#!/usr/bin/env bash
# =============================================================================
# rofeed.sh — Mi Feed · rofi-blocks UI Worker
# Version: 0.6.0
# =============================================================================
#
# PURPOSE
#   This script IS the rofi-blocks worker process (passed to -blocks-wrap).
#   It is the only process that writes to stdout (→ rofi) and reads from stdin
#   (← rofi selection events).
#
#   Responsibilities:
#     • Read the local cache files and render them as rofi-blocks JSON
#     • Manage the view state machine (feed ↔ settings)
#     • Launch mpv for playback
#     • Trigger rofeed-worker.sh --crawl-only on demand ("Force update")
#     • Poll CRAWLER_STATUS_FILE and push live status updates to rofi
#
#   This script contains ZERO network calls, ZERO yt-dlp calls, and
#   ZERO cache-writing logic.  All of that lives exclusively in
#   rofeed-worker.sh.
#
# ROFI-BLOCKS PROTOCOL
#   STDOUT → JSON objects, one per line, each updates the rofi display
#   STDIN  ← "data" value of the selected row
#
# CRAWLER STATUS FILE PROTOCOL  (~/.cache/rofeed-feed/.crawler_status)
#   idle           — no crawl running
#   running:N:T    — processing channel N of T
#   done:TOTAL     — just finished; TOTAL videos now in cache
#   error:MSG      — crawl encountered a fatal error
#
# INVOCATION
#   Called by the launcher (a thin wrapper that calls rofi):
#     rofi -modi blocks -show blocks -blocks-wrap /path/to/rofeed.sh -theme …
#
#   CLI flags (for the launcher wrapper, not for rofi-blocks):
#     --update     Delegate to rofeed-worker.sh --crawl-only
#     --version    Print version and exit
#     --help       Print help and exit
#
# FILE LAYOUT
#   § 1  PATHS & CONSTANTS
#   § 2  SETTINGS          (load / save / defaults)
#   § 3  STATUS HELPERS    (read CRAWLER_STATUS_FILE → human label)
#   § 4  UI LAYER          (JSON builders, emit functions)
#   § 5  PLAYBACK          (mpv launcher)
#   § 6  EVENT LOOP        (stdin handler + view-mode state machine)
#   § 7  MAIN              (entry point for rofi-blocks)
# =============================================================================

set -uo pipefail

readonly ROFEED_VERSION="0.6.0"

# ─────────────────────────────────────────────────────────────────────────────
# § 1  PATHS & CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────

readonly CONFIG_DIR="${HOME}/.config/rofeed"
readonly CONFIG_FILE="${CONFIG_DIR}/config"

readonly CACHE_DIR="${HOME}/.cache/rofeed-feed"
readonly CACHE_THUMBS="${HOME}/.cache/rofeed-thumbs"
readonly CACHE_FILE="${CACHE_DIR}/videos.tsv"
readonly SETTINGS_FILE="${CACHE_DIR}/settings"
readonly LAST_UPDATE_FILE="${CACHE_DIR}/.last_update"
readonly CRAWLER_STATUS_FILE="${CACHE_DIR}/.crawler_status"

# Runtime view-mode flag — written exclusively by this process.
# Values: "feed" | "settings"
readonly VIEWMODE_FILE="${CACHE_DIR}/.viewmode"

# Locate rofeed-worker.sh relative to this script, then system fallback.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_find_worker() {
    local candidates=(
        "${SCRIPT_DIR}/rofeed-worker.sh"
        "/usr/lib/rofeed/rofeed-worker.sh"
    )
    local f
    for f in "${candidates[@]}"; do
        [[ -f "$f" && -x "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# § 2  SETTINGS  (playback preferences — UI-owned, persisted to SETTINGS_FILE)
# ─────────────────────────────────────────────────────────────────────────────

PLAY_MODE="video"   # "video" | "audio"
RESOLUTION="480"    # "360"   | "480" | "720" | "1080"
SUBTITLES="false"   # "true"  | "false"

load_settings() {
    local f key val
    for f in "$CONFIG_FILE" "$SETTINGS_FILE"; do
        [[ -f "$f" ]] || continue
        while IFS='=' read -r key val; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${key// /}" ]]           && continue
            key="${key#"${key%%[![:space:]]*}"}" ; key="${key%"${key##*[![:space:]]}"}"
            val="${val#"${val%%[![:space:]]*}"}" ; val="${val%"${val##*[![:space:]]}"}"
            val="${val%\"}" ; val="${val#\"}" ; val="${val%\'}" ; val="${val#\'}"
            case "$key" in
                PLAY_MODE)   [[ "$val" =~ ^(video|audio)$      ]] && PLAY_MODE="$val"   ;;
                RESOLUTION)  [[ "$val" =~ ^(360|480|720|1080)$ ]] && RESOLUTION="$val"  ;;
                SUBTITLES)   [[ "$val" =~ ^(true|false)$        ]] && SUBTITLES="$val"   ;;
            esac
        done < "$f"
    done
}

save_settings() {
    mkdir -p "$CACHE_DIR"
    printf 'PLAY_MODE="%s"\nRESOLUTION="%s"\nSUBTITLES="%s"\n' \
        "$PLAY_MODE" "$RESOLUTION" "$SUBTITLES" \
        > "$SETTINGS_FILE"
}

settings_summary() {
    local mode_str sub_str
    [[ "$PLAY_MODE" == "audio" ]] && mode_str="🎵 Audio" || mode_str="🎬 ${RESOLUTION}p"
    [[ "$SUBTITLES" == "true"  ]] && sub_str="CC:on"      || sub_str="CC:off"
    printf '%s  %s' "$mode_str" "$sub_str"
}

# ─────────────────────────────────────────────────────────────────────────────
# § 3  STATUS HELPERS  (read-only — worker writes, UI reads)
# ─────────────────────────────────────────────────────────────────────────────

# Human-readable age of last successful update.
last_update_label() {
    [[ -f "$LAST_UPDATE_FILE" ]] || { printf 'nunca actualizado'; return; }
    local last_ts now_ts diff_s diff_m diff_h
    last_ts=$(cat "$LAST_UPDATE_FILE" 2>/dev/null || echo 0)
    now_ts=$(date +%s)
    diff_s=$(( now_ts - last_ts ))
    diff_m=$(( diff_s / 60 ))
    diff_h=$(( diff_m / 60 ))
    if   (( diff_m == 0 )); then printf 'actualizado ahora mismo'
    elif (( diff_h == 0 )); then printf 'actualizado hace %d min'  "$diff_m"
    elif (( diff_h < 24 )); then printf 'actualizado hace %d h'    "$diff_h"
    else                         printf 'actualizado hace %d días' "$((diff_h/24))"
    fi
}

# Read CRAWLER_STATUS_FILE and return two lines:
#   line 1 → human-readable status label (for the status row in the feed)
#   line 2 → data token for that row (always __force_update__ so clicking
#             the status bar re-triggers the crawler)
crawler_status_read() {
    local raw
    raw=$(cat "$CRAWLER_STATUS_FILE" 2>/dev/null || printf 'idle')

    local cached_count
    cached_count=$(wc -l < "$CACHE_FILE" 2>/dev/null | tr -d ' ') || cached_count=0

    case "$raw" in
        idle)
            printf '⏺  %s vídeos en caché  ·  %s\n__force_update__' \
                "$cached_count" "$(last_update_label)"
            ;;
        running:*:*)
            local n="${raw#running:}"; n="${n%:*}"
            local t="${raw##*:}"
            printf '🔄  Actualizando…  canal %s/%s  —  %s vídeos en caché\n__force_update__' \
                "$n" "$t" "$cached_count"
            ;;
        done:*)
            local total="${raw#done:}"
            printf '✅  %s vídeos en caché  ·  %s\n__force_update__' \
                "$total" "$(last_update_label)"
            ;;
        error:*)
            local msg="${raw#error:}"
            printf '⚠  Error: %s  ·  pulsa para reintentar\n__force_update__' "$msg"
            ;;
        error)
            printf '⚠  Error en la última actualización  ·  pulsa para reintentar\n__force_update__'
            ;;
        *)
            printf '⏺  %s vídeos en caché\n__force_update__' "$cached_count"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# § 4  UI LAYER
# ─────────────────────────────────────────────────────────────────────────────

# Escape a string for embedding in a JSON double-quoted value.
json_str() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# ── Feed view ─────────────────────────────────────────────────────────────────
#
# Row layout:
#   [0] Status bar  — shows cache count + crawl state; data=__force_update__
#   [1] Settings    — shortcut to settings view;       data=__cfg__
#   [2…N] Videos    — one row per video with thumbnail; data=vid_id
#
# Each video row carries the CSS class "video-row" in its "urgent" field
# (rofi-blocks passes extra fields through; we use the "icon" field for the
# thumb path and rely on the .rasi to size it correctly).
#
# Text-only rows (status, settings) carry NO "icon" field so the icon cell
# collapses and the row takes its natural single-line height.
build_feed_json() {
    local tsv_file="$1"

    local _sr status_label status_data
    _sr=$(crawler_status_read)
    status_label=$(printf '%s' "$_sr" | head -1)
    status_data=$(printf '%s' "$_sr" | tail -1)

    python3 - "$tsv_file" "$CACHE_THUMBS" "$status_label" "$status_data" << 'PYEOF'
import sys, json, os

tsv_file     = sys.argv[1]
thumb_dir    = sys.argv[2]
status_label = sys.argv[3]
status_data  = sys.argv[4]

rows = []
try:
    with open(tsv_file) as fh:
        for raw in fh:
            parts = raw.rstrip('\n').split('\t')
            if len(parts) < 4:
                continue
            rows.append({
                'vid_id':   parts[0],
                'title':    parts[1][:60],
                'channel':  parts[2][:34],
                'date':     parts[3],
                'duration': parts[4] if len(parts) > 4 else '?',
            })
except (FileNotFoundError, OSError):
    pass

result = []

# ── Row 0: status / update bar ────────────────────────────────────────────────
is_running = '🔄' in status_label
lbl_color  = '#fab387' if is_running else '#a6adc8'
result.append(json.dumps({
    "text":   f"<span color='{lbl_color}'>{status_label}</span>",
    "markup": True,
    "data":   status_data,
}, ensure_ascii=False))

# ── Row 1: settings shortcut ──────────────────────────────────────────────────
result.append(json.dumps({
    "text": (
        "<span color='#89dceb'>⚙  Ajustes</span>"
        "  <span color='#585b70'>modo · resolución · subtítulos</span>"
    ),
    "markup": True,
    "data":   "__cfg__",
}, ensure_ascii=False))

# ── Video rows ────────────────────────────────────────────────────────────────
for r in rows:
    thumb_path = os.path.join(thumb_dir, f"{r['vid_id']}.jpg")
    entry = {
        "text": (
            f"<span color='#89dceb'>{r['date']}</span>"
            f"  <span color='#a6e3a1'>{r['duration']}</span>\n"
            f"<span color='#cdd6f4'>{r['title']}</span>\n"
            f"<span color='#6c7086'>— {r['channel']}</span>"
        ),
        "markup": True,
        "data":   r['vid_id'],
    }
    # Only include "icon" when the thumbnail actually exists on disk.
    # rofi-blocks sizes the row to fit the icon; omitting it collapses
    # the icon cell and gives text-only rows their natural compact height.
    if os.path.exists(thumb_path):
        entry["icon"] = thumb_path
    result.append(json.dumps(entry, ensure_ascii=False))

print(','.join(result))
PYEOF
}

# ── Settings view ─────────────────────────────────────────────────────────────
#
# All rows are text-only (no "icon" field) so they render at compact height.
build_settings_json() {
    local max_vids date_from date_to
    # Read crawler config values directly from config file (read-only here)
    max_vids="30" ; date_from="" ; date_to=""
    if [[ -f "$CONFIG_FILE" ]]; then
        local key val
        while IFS='=' read -r key val; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            key="${key#"${key%%[![:space:]]*}"}" ; key="${key%"${key##*[![:space:]]}"}"
            val="${val#"${val%%[![:space:]]*}"}" ; val="${val%"${val##*[![:space:]]}"}"
            val="${val%\"}" ; val="${val#\"}"
            case "$key" in
                MAX_VIDEOS_PER_CHANNEL) max_vids="$val"    ;;
                DATE_FROM)              date_from="$val"   ;;
                DATE_TO)                date_to="$val"     ;;
            esac
        done < "$CONFIG_FILE"
    fi

    python3 - \
        "$PLAY_MODE" "$RESOLUTION" "$SUBTITLES" \
        "${max_vids:-30}" \
        "${date_from:-}" "${date_to:-}" \
        << 'PYEOF'
import sys, json

play_mode, resolution, subtitles = sys.argv[1], sys.argv[2], sys.argv[3]
max_vids, date_from, date_to     = sys.argv[4], sys.argv[5], sys.argv[6]

def row(text, data):
    return json.dumps({"text": text, "markup": True, "data": data}, ensure_ascii=False)

def section(label):
    return row(
        f"<span color='#45475a' size='small'>── {label} ──</span>",
        "__noop__"
    )

items = []

# ── Navigation ────────────────────────────────────────────────────────────────
items.append(row("<span color='#f38ba8'>←  Volver al Feed</span>", "__back__"))

# ── Playback mode toggle ──────────────────────────────────────────────────────
items.append(section("REPRODUCCIÓN"))
mode_label = "🎵  Audio Only" if play_mode == "audio" else "🎬  Video + Audio"
mode_color = "#cba6f7"        if play_mode == "audio" else "#89dceb"
items.append(row(f"<span color='{mode_color}'>{mode_label}</span>", "__toggle_mode__"))

sub_on    = subtitles == "true"
sub_color = "#a6e3a1" if sub_on else "#6c7086"
sub_lbl   = "💬  Subtítulos: ON" if sub_on else "💬  Subtítulos: OFF"
items.append(row(f"<span color='{sub_color}'>{sub_lbl}</span>", "__toggle_subs__"))

# ── Resolution selector ───────────────────────────────────────────────────────
items.append(section("RESOLUCIÓN"))
for res in ("360", "480", "720", "1080"):
    active = res == resolution
    color  = "#a6e3a1" if active else "#6c7086"
    check  = "  ✓"    if active else ""
    items.append(row(f"<span color='{color}'>  {res}p{check}</span>", f"__res_{res}__"))

# ── Cache info ────────────────────────────────────────────────────────────────
items.append(section("CACHÉ"))
cap_label = f"{max_vids} por canal" if max_vids != "0" else "sin límite"
df_label  = date_from if date_from else "—"
dt_label  = date_to   if date_to   else "—"
items.append(row(
    f"<span color='#6c7086'>  Máx {cap_label}  ·  "
    f"Desde {df_label} → {dt_label}  ·  edita config para cambiar</span>",
    "__noop__"
))

# ── Force update ──────────────────────────────────────────────────────────────
items.append(row(
    "<span color='#fab387'>🔄  Forzar actualización ahora</span>",
    "__force_update__"
))

print(','.join(items))
PYEOF
}

# ── Emit helpers ──────────────────────────────────────────────────────────────

emit_feed() {
    local message="$1" lines_json="$2"
    local msg_esc
    msg_esc=$(json_str "$(settings_summary)")
    if [[ -z "$message" ]]; then
        printf '{"prompt":"🎬 Mi Feed","message":"%s","event format":"{{data}}","lines":[%s]}\n' \
            "$msg_esc" "$lines_json"
    else
        local extra_esc
        extra_esc=$(json_str "$message")
        printf '{"prompt":"🎬 Mi Feed","message":"%s  ·  %s","event format":"{{data}}","lines":[%s]}\n' \
            "$extra_esc" "$msg_esc" "$lines_json"
    fi
}

emit_settings() {
    local lines_json last_esc
    lines_json=$(build_settings_json)
    last_esc=$(json_str "$(last_update_label)")
    printf '{"prompt":"⚙  Ajustes","message":"%s","event format":"{{data}}","lines":[%s]}\n' \
        "$last_esc" "$lines_json"
}

_emit_current_feed() {
    local lines_json
    lines_json=$(build_feed_json "${CACHE_FILE}")
    if [[ -f "$CACHE_FILE" && -s "$CACHE_FILE" ]]; then
        emit_feed "" "$lines_json"
    else
        emit_feed "⏳ Sin caché — usa 'Forzar actualización' o activa el timer" "$lines_json"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# § 5  PLAYBACK
# ─────────────────────────────────────────────────────────────────────────────

launch_mpv() {
    local vid_id="$1"
    local url="https://www.youtube.com/watch?v=${vid_id}"

    # Re-read settings in case they changed this session
    load_settings

    local fmt
    if [[ "$PLAY_MODE" == "audio" ]]; then
        fmt="bestaudio/best"
    else
        fmt="bestvideo[height<=${RESOLUTION}][ext=mp4]+bestaudio[ext=m4a]"
        fmt+="/bestvideo[height<=${RESOLUTION}]+bestaudio"
        fmt+="/best[height<=${RESOLUTION}]"
        fmt+="/best"
    fi

    local -a args=(
        "--ytdl-format=${fmt}"
        "--force-window=immediate"
        "--title=MiFeed · ${vid_id}"
        "--cache=yes"
    )

    [[ "$PLAY_MODE" == "audio" ]] && args+=("--no-video" "--audio-display=no")

    if [[ "$SUBTITLES" == "true" ]]; then
        args+=(
            "--sub-auto=fuzzy"
            "--ytdl-raw-options-append=write-auto-subs="
            "--ytdl-raw-options-append=sub-langs=es.*,en.*"
        )
    fi

    # Look up the title in the cache for the desktop notification
    local title=""
    [[ -f "$CACHE_FILE" ]] && \
        title=$(grep "^${vid_id}"$'\t' "$CACHE_FILE" 2>/dev/null | cut -f2 | head -1)

    local mode_label
    [[ "$PLAY_MODE" == "audio" ]] && mode_label="🎵 Audio Only" \
                                  || mode_label="🎬 ${RESOLUTION}p"

    notify-send -a "Mi Feed" -i "mpv" \
        "▶ ${mode_label}" "${title:-$vid_id}" -t 3000 2>/dev/null || true

    nohup mpv "${args[@]}" "$url" >/dev/null 2>&1 &
}

# ─────────────────────────────────────────────────────────────────────────────
# § 6  EVENT LOOP
# ─────────────────────────────────────────────────────────────────────────────
#
# State machine: VIEW_MODE ∈ { feed, settings }
#
# Recognised data tokens from rofi:
#   __cfg__           → switch to settings view
#   __back__          → switch to feed view
#   __force_update__  → spawn rofeed-worker.sh --crawl-only; stay on feed
#   __toggle_mode__   → video ↔ audio
#   __res_NNN__       → set resolution to NNN
#   __toggle_subs__   → subtitles on/off
#   __noop__          → section separator selected; re-emit current view
#   [A-Za-z0-9_-]{11} → YouTube video ID → launch mpv
#
# Live-update mechanism (read -t 2 poll):
#   When rofi has no event for 2 s we get a timeout (ret > 128).
#   On timeout we check CRAWLER_STATUS_FILE and push a fresh JSON frame
#   if a crawl is running or has just finished.
#   IMPORTANT: only THIS process writes to stdout.
#   rofeed-worker.sh runs in a background subshell and only touches files.
# ─────────────────────────────────────────────────────────────────────────────

# PID of a background worker subshell started by __force_update__.
# Kept so we can avoid double-starting.
CRAWLER_PID=""

handle_event() {
    local event="$1"

    case "$event" in

        __cfg__)
            printf 'settings' > "$VIEWMODE_FILE"
            load_settings
            emit_settings
            ;;

        __back__)
            printf 'feed' > "$VIEWMODE_FILE"
            _emit_current_feed
            ;;

        __force_update__)
            # Only spawn a new worker if one is not already running.
            if [[ -n "$CRAWLER_PID" ]] && kill -0 "$CRAWLER_PID" 2>/dev/null; then
                # Already running — just stay on feed so the user sees progress.
                printf 'feed' > "$VIEWMODE_FILE"
                _emit_current_feed
                return 0
            fi

            local worker
            worker=$(_find_worker) || {
                emit_feed "⚠ rofeed-worker.sh no encontrado" \
                    "$(build_feed_json "${CACHE_FILE}")"
                return 0
            }

            printf 'feed' > "$VIEWMODE_FILE"
            # Pre-write a "running" status so the UI shows feedback immediately
            # (the worker will overwrite this within milliseconds)
            printf 'running:0:?' > "$CRAWLER_STATUS_FILE"
            _emit_current_feed

            # Spawn the worker as a fully detached background process.
            # It communicates only through the status file.
            ( "$worker" --crawl-only ) &
            CRAWLER_PID=$!
            ;;

        __toggle_mode__)
            [[ "$PLAY_MODE" == "video" ]] && PLAY_MODE="audio" || PLAY_MODE="video"
            save_settings
            emit_settings
            ;;

        __res_*__)
            local res="${event#__res_}"; res="${res%__}"
            [[ "$res" =~ ^(360|480|720|1080)$ ]] && { RESOLUTION="$res"; save_settings; }
            emit_settings
            ;;

        __toggle_subs__)
            [[ "$SUBTITLES" == "true" ]] && SUBTITLES="false" || SUBTITLES="true"
            save_settings
            emit_settings
            ;;

        __noop__)
            local cur_mode
            cur_mode=$(cat "$VIEWMODE_FILE" 2>/dev/null || printf 'feed')
            if [[ "$cur_mode" == "settings" ]]; then
                load_settings; emit_settings
            else
                _emit_current_feed
            fi
            ;;

        *)
            # 11-character YouTube video ID
            if printf '%s' "$event" | grep -qE '^[A-Za-z0-9_-]{11}$'; then
                launch_mpv "$event"
            fi
            ;;

    esac
}

run_event_loop() {
    local event ret
    while true; do
        # Block up to 2 s for a rofi selection event.
        #   ret == 0        → got an event; process it.
        #   ret > 128       → timeout; poll crawler status.
        #   ret 1..128      → EOF (rofi closed); exit cleanly.
        IFS= read -r -t 2 event; ret=$?

        if (( ret == 0 )); then
            [[ -n "$event" ]] && handle_event "$event"

        elif (( ret > 128 )); then
            # Timeout: push a live-update frame if a crawl is running/done.
            local cur_status cur_mode
            cur_status=$(cat "$CRAWLER_STATUS_FILE" 2>/dev/null || printf 'idle')
            cur_mode=$(cat   "$VIEWMODE_FILE"       2>/dev/null || printf 'feed')

            if [[ "$cur_mode" == "feed" ]]; then
                case "$cur_status" in
                    running:*)
                        # Crawl in progress — refresh the status bar
                        emit_feed "" "$(build_feed_json "${CACHE_FILE}")"
                        ;;
                    done:*)
                        # Crawl just finished — one final refresh, then mark idle
                        emit_feed "" "$(build_feed_json "${CACHE_FILE}")"
                        printf 'idle' > "$CRAWLER_STATUS_FILE"
                        ;;
                esac
            fi

        else
            # EOF: rofi window closed
            break
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# § 7  MAIN
# ─────────────────────────────────────────────────────────────────────────────

cleanup() {
    # If we started a background crawler, leave it running (it's detached).
    # Just clean up the view-mode file.
    rm -f "$VIEWMODE_FILE"

    # If the crawler was still marked "running" when we exited and we own
    # that process, reset the status so future UI sessions start clean.
    if [[ -n "$CRAWLER_PID" ]] && ! kill -0 "$CRAWLER_PID" 2>/dev/null; then
        local cur_status
        cur_status=$(cat "$CRAWLER_STATUS_FILE" 2>/dev/null || printf '')
        [[ "$cur_status" == running:* ]] && printf 'idle' > "$CRAWLER_STATUS_FILE"
    fi
}

main() {
    mkdir -p "$CACHE_DIR" "$CACHE_THUMBS" "$CONFIG_DIR"
    load_settings

    printf 'feed' > "$VIEWMODE_FILE"
    trap cleanup EXIT INT TERM

    # Initialise status file only if the worker hasn't written one yet.
    [[ -f "$CRAWLER_STATUS_FILE" ]] || printf 'idle' > "$CRAWLER_STATUS_FILE"

    # Initial render — purely from disk cache, zero network activity.
    local lines_json
    if [[ -f "$CACHE_FILE" && -s "$CACHE_FILE" ]]; then
        lines_json=$(build_feed_json "$CACHE_FILE")
        emit_feed "" "$lines_json"
    else
        lines_json=$(build_feed_json /dev/null)
        emit_feed "⏳ Sin caché — usa 'Forzar actualización' o activa el timer" "$lines_json"
    fi

    run_event_loop
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI flag handling
# These flags are intercepted by the thin launcher wrapper; if rofeed.sh is
# called directly (e.g. for testing) they still work correctly.
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
    --version|-V)
        printf 'rofeed %s\n' "$ROFEED_VERSION"
        exit 0
        ;;
    --help|-h)
        cat << HELP
rofeed.sh ${ROFEED_VERSION} — rofi-blocks UI worker for Mi Feed

USAGE
  Called automatically by rofi via -blocks-wrap.
  Do not invoke directly unless testing.

  rofeed.sh --version    Print version
  rofeed.sh --help       Show this help

  For launching the feed browser, use the rofeed launcher script or:
    rofi -modi blocks -show blocks -blocks-wrap /path/to/rofeed.sh \\
         -theme /path/to/rofeed.rasi -markup-rows
HELP
        exit 0
        ;;
    "")
        main
        ;;
    *)
        printf 'rofeed.sh: unknown option: %s\n' "$1" >&2
        exit 1
        ;;
esac
