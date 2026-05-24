#!/usr/bin/env bash
# =============================================================================
# rofeed-worker.sh — Mi Feed · rofi-blocks worker
# =============================================================================
#
# rofi-blocks protocol:
#   STDOUT → JSON lines  →  each line updates the rofi display
#   STDIN  ← selection events  ←  rofi sends the selected item's "data" value
#
# Special invocation:
#   rofeed-worker.sh --crawl-only
#     Runs the crawler without launching a UI (for cron / systemd timers).
#     stdout is silenced; only the TSV cache is updated.
#
# ─────────────────────────────────────────────────────────────────────────────
# File layout:
#   § 1  PATHS & CONSTANTS
#   § 2  SETTINGS           (load / save / defaults — persisted to disk)
#   § 3  DATA LAYER         (crawler — structured for future service extraction)
#   § 4  UI LAYER           (JSON builders, emit functions)
#   § 5  PLAYBACK           (mpv launcher with format / subtitle logic)
#   § 6  EVENT LOOP         (stdin handler + view-mode state machine)
#   § 7  MAIN               (orchestration + --crawl-only entry point)
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# § 1  PATHS & CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────

readonly SUBS="${HOME}/.config/rofeed/subscriptions"
readonly CACHE_DIR="${HOME}/.cache/rofeed-feed"
readonly CACHE_IDS="${HOME}/.cache/rofeed-channel-ids"
readonly CACHE_THUMBS="${HOME}/.cache/rofeed-thumbs"
readonly CACHE_FILE="${CACHE_DIR}/videos.tsv"
readonly SETTINGS_FILE="${CACHE_DIR}/settings"
# Shared between main process and background crawler subshell via the filesystem.
# Contains either "feed" or "settings" — controls whether crawler emits updates.
readonly VIEWMODE_FILE="${CACHE_DIR}/.viewmode"

# ─────────────────────────────────────────────────────────────────────────────
# § 2  SETTINGS
# ─────────────────────────────────────────────────────────────────────────────

# Runtime variables — overridden by load_settings on startup and before playback.
PLAY_MODE="video"    # "video"  | "audio"
RESOLUTION="480"     # "360" | "480" | "720" | "1080"
SUBTITLES="false"    # "true" | "false"

# Read persisted settings from disk into the global variables above.
load_settings() {
    [[ -f "$SETTINGS_FILE" ]] || return 0
    local key val
    while IFS='=' read -r key val; do
        # Strip surrounding quotes written by save_settings
        val="${val%\"}"
        val="${val#\"}"
        case "$key" in
            PLAY_MODE)
                [[ "$val" =~ ^(video|audio)$ ]]      && PLAY_MODE="$val"  ;;
            RESOLUTION)
                [[ "$val" =~ ^(360|480|720|1080)$ ]] && RESOLUTION="$val" ;;
            SUBTITLES)
                [[ "$val" =~ ^(true|false)$ ]]        && SUBTITLES="$val"  ;;
        esac
    done < "$SETTINGS_FILE"
}

# Persist current globals to disk. Called after every user settings change.
save_settings() {
    mkdir -p "$CACHE_DIR"
    printf 'PLAY_MODE="%s"\nRESOLUTION="%s"\nSUBTITLES="%s"\n' \
        "$PLAY_MODE" "$RESOLUTION" "$SUBTITLES" \
        > "$SETTINGS_FILE"
}

# One-liner shown in the message bar while browsing the feed.
settings_summary() {
    local mode_str sub_str
    if [[ "$PLAY_MODE" == "audio" ]]; then
        mode_str="🎵 Audio Only"
    else
        mode_str="🎬 ${RESOLUTION}p"
    fi
    [[ "$SUBTITLES" == "true" ]] && sub_str="CC:on" || sub_str="CC:off"
    printf '%s  %s' "$mode_str" "$sub_str"
}

# ─────────────────────────────────────────────────────────────────────────────
# § 3  DATA LAYER
#
# These functions are self-contained and do not touch the UI layer directly.
# run_crawler() calls emit_if_feed() for progress updates, which is the only
# coupling to the UI. To extract the crawler into a standalone service:
#   1. Remove the emit_if_feed() calls from run_crawler().
#   2. Replace them with:  touch "${CACHE_DIR}/.update_ready"
#   3. Add a file-watcher in the UI that reads the flag and re-emits.
# ─────────────────────────────────────────────────────────────────────────────

# Merge two TSV files: deduplicate by video ID (col 1), sort by date (col 4) desc.
merge_tsv() {
    cat "$1" "$2" 2>/dev/null \
        | awk -F'\t' '!seen[$1]++' \
        | sort -t$'\t' -k4 -r
}

# Resolve a YouTube channel URL → channel ID (UCxxxxxxx).
# Results are cached by URL hash to avoid repeated HTTP lookups.
resolve_channel_id() {
    local url="$1"
    local hash cachefile
    hash=$(printf '%s' "$url" | md5sum | cut -d' ' -f1)
    cachefile="${CACHE_IDS}/${hash}"

    if [[ -f "$cachefile" ]]; then
        cat "$cachefile"
        return 0
    fi

    local id
    id=$(curl -s --max-time 15 "$url" \
        | grep -o '"externalId":"[^"]*"' \
        | head -1 | cut -d'"' -f4)

    if [[ -n "$id" ]]; then
        printf '%s' "$id" > "$cachefile"
        printf '%s' "$id"
    fi
}

# Fetch latest video metadata for a channel via YouTube's Atom RSS feed.
# Outputs TSV: vid_id <TAB> title <TAB> channel_name <TAB> published_date
fetch_rss() {
    local channel_id="$1"
    curl -s --max-time 20 \
        "https://www.youtube.com/feeds/videos.xml?channel_id=${channel_id}" \
    | python3 -c "
import sys, xml.etree.ElementTree as ET
ns = {
    'atom': 'http://www.w3.org/2005/Atom',
    'yt':   'http://www.youtube.com/xml/schemas/2015',
}
try:
    root     = ET.parse(sys.stdin).getroot()
    ch_node  = root.find('atom:author/atom:name', ns)
    ch_name  = ch_node.text.strip() if ch_node is not None else 'Unknown'
    for entry in root.findall('atom:entry', ns):
        vid  = entry.find('yt:videoId', ns).text
        titl = (entry.find('atom:title', ns).text or '').replace('\t', ' ')
        pub  = entry.find('atom:published', ns).text[:16].replace('T', ' ')
        print(f'{vid}\t{titl}\t{ch_name}\t{pub}')
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# Fetch video durations for the latest 15 videos on a channel page via yt-dlp.
# Outputs TSV: vid_id <TAB> human_duration (e.g. "12m 34s")
# Runs at nice level 19 to avoid competing with the user session.
fetch_durations() {
    local url="$1"
    nice -n 19 yt-dlp \
        --flat-playlist \
        --playlist-end 15 \
        --print-json \
        "${url}/videos" 2>/dev/null \
    | jq -r '
        [
          .id,
          (.duration
           | if . != null then (. | floor
               | if   . >= 3600 then "\(. / 3600 | floor)h \(. % 3600 / 60 | floor)m \(. % 60)s"
                 elif . >= 60   then "\(. / 60 | floor)m \(. % 60)s"
                 else               "\(.)s"
                 end)
             else "?" end)
        ] | join("\t")
    ' 2>/dev/null
}

# Full crawl: iterate subscriptions, fetch RSS + durations, merge into cache.
# Emits incremental progress updates to the feed view while running.
run_crawler() {
    [[ -f "$SUBS" ]] || return 0

    local total count
    total=$(grep -cve '^\s*#' -e '^\s*$' "$SUBS" 2>/dev/null || echo 0)
    [[ "$total" -eq 0 ]] && return 0

    count=0
    local tmpnew
    tmpnew=$(mktemp /tmp/rofeed-new-XXXX.tsv)

    while IFS= read -r url; do
        [[ -z "$url" || "$url" == \#* ]] && continue
        count=$((count + 1))

        # Resolve channel ID — direct /channel/UC* URLs skip the HTTP lookup
        local channel_id
        if printf '%s' "$url" | grep -q '/channel/UC'; then
            channel_id=$(printf '%s' "$url" | grep -o 'UC[^/]*' | head -1)
        else
            channel_id=$(resolve_channel_id "$url")
        fi
        [[ -z "$channel_id" ]] && continue

        # Fetch RSS metadata and yt-dlp durations concurrently
        local rssfile durfile
        rssfile=$(mktemp /tmp/rofeed-rss-XXXX)
        durfile=$(mktemp /tmp/rofeed-dur-XXXX)
        fetch_rss "$channel_id" > "$rssfile" &
        fetch_durations "$url"  > "$durfile" &
        wait

        # Join RSS entries with their durations
        while IFS=$'\t' read -r vid_id title channel_name published; do
            [[ -z "$vid_id" ]] && continue
            local duration
            duration=$(grep "^${vid_id}"$'\t' "$durfile" | cut -f2)
            [[ -z "$duration" ]] && duration="?"
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$vid_id" "$title" "$channel_name" "$published" "$duration" \
                >> "$tmpnew"
        done < "$rssfile"
        rm -f "$rssfile" "$durfile"

        # Emit incremental merged feed — skipped if user is in settings view
        local tmpmerge total_vids lines_json
        tmpmerge=$(mktemp /tmp/rofeed-merge-XXXX.tsv)
        merge_tsv "$tmpnew" "$CACHE_FILE" > "$tmpmerge"
        total_vids=$(wc -l < "$tmpmerge")
        lines_json=$(build_feed_json "$tmpmerge")
        emit_if_feed "🔄 Canal ${count}/${total} — ${total_vids} vídeos" "$lines_json"
        rm -f "$tmpmerge"

    done < "$SUBS"

    # Phase 3: atomically persist the final merged cache (mv is atomic on same fs)
    local tmpfinal
    tmpfinal=$(mktemp /tmp/rofeed-final-XXXX.tsv)
    merge_tsv "$tmpnew" "$CACHE_FILE" > "$tmpfinal"
    mv "$tmpfinal" "$CACHE_FILE"
    rm -f "$tmpnew"

    local total_vids lines_json
    total_vids=$(wc -l < "$CACHE_FILE")
    lines_json=$(build_feed_json "$CACHE_FILE")
    emit_if_feed "✅ Feed actualizado — ${total_vids} vídeos" "$lines_json"
}

# ─────────────────────────────────────────────────────────────────────────────
# § 4  UI LAYER
# ─────────────────────────────────────────────────────────────────────────────

# Build the rofi-blocks "lines" JSON array for the FEED view.
# Always prepends a ⚙ Settings entry so the user can reach configuration.
# Downloads missing thumbnails in parallel before building the result.
build_feed_json() {
    local tsv_file="$1"
    python3 - "$tsv_file" "$CACHE_THUMBS" << 'PYEOF'
import sys, json, os, subprocess, threading

tsv_file  = sys.argv[1]
thumb_dir = sys.argv[2]

# ── Parse TSV ──────────────────────────────────────────────────────────────────
rows = []
try:
    with open(tsv_file) as f:
        for raw in f:
            parts = raw.rstrip('\n').split('\t')
            if len(parts) < 4:
                continue
            rows.append({
                'vid_id':   parts[0],
                'title':    parts[1][:58],
                'channel':  parts[2][:32],
                'date':     parts[3],
                'duration': parts[4] if len(parts) > 4 else '?',
            })
except (FileNotFoundError, OSError):
    pass

# ── Parallel thumbnail downloads ───────────────────────────────────────────────
def download_thumb(vid_id):
    path = os.path.join(thumb_dir, f'{vid_id}.jpg')
    if os.path.exists(path):
        return
    url = f'https://i.ytimg.com/vi/{vid_id}/mqdefault.jpg'
    try:
        subprocess.run(
            ['curl', '-s', '--max-time', '10', url, '-o', path],
            timeout=12, capture_output=True
        )
    except Exception:
        pass

threads = [
    threading.Thread(target=download_thumb, args=(r['vid_id'],))
    for r in rows
]
for t in threads: t.start()
for t in threads: t.join()

# ── Build JSON entries ─────────────────────────────────────────────────────────
result = []

# Settings gear — always first in the list
result.append(json.dumps({
    "text": (
        "<span color='#89dceb'>⚙  Ajustes de reproducción</span>\n"
        "<span color='#585b70'>Modo  ·  Resolución  ·  Subtítulos</span>"
    ),
    "markup": True,
    "data": "__cfg__"
}, ensure_ascii=False))

# Video entries
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
        "data": r['vid_id'],
    }
    if os.path.exists(thumb_path):
        entry["icon"] = thumb_path
    result.append(json.dumps(entry, ensure_ascii=False))

print(','.join(result))
PYEOF
}

# Build the rofi-blocks "lines" JSON array for the SETTINGS view.
# Accepts current settings as argv so it works correctly from the background
# subshell (which cannot share bash globals with the main process).
build_settings_json() {
    python3 - "$PLAY_MODE" "$RESOLUTION" "$SUBTITLES" << 'PYEOF'
import sys, json

play_mode  = sys.argv[1]   # "video" | "audio"
resolution = sys.argv[2]   # "360" | "480" | "720" | "1080"
subtitles  = sys.argv[3]   # "true"  | "false"

entries = []

# ── Back to feed ───────────────────────────────────────────────────────────────
entries.append({
    "text": "<span color='#f38ba8' size='large'>  ←  Volver al Feed</span>",
    "markup": True,
    "data": "__back__"
})

# ── Play mode toggle ───────────────────────────────────────────────────────────
if play_mode == "audio":
    mode_label = "🎵  Audio Only"
    mode_hint  = "Pulsa para cambiar a  🎬 Video + Audio"
    mode_color = "#cba6f7"
else:
    mode_label = "🎬  Video + Audio"
    mode_hint  = "Pulsa para cambiar a  🎵 Audio Only"
    mode_color = "#89dceb"

entries.append({
    "text": (
        "<span color='#6c7086'>MODO DE REPRODUCCIÓN</span>\n"
        f"<span color='{mode_color}' size='large'>{mode_label}</span>\n"
        f"<span color='#585b70'>{mode_hint}</span>"
    ),
    "markup": True,
    "data": "__toggle_mode__"
})

# ── Resolution selector (4 options, active one highlighted) ───────────────────
entries.append({
    "text": "<span color='#6c7086'>RESOLUCIÓN MÁXIMA</span>",
    "markup": True,
    "data": "__noop__"
})

for res in ["360", "480", "720", "1080"]:
    is_active = (res == resolution)
    check     = "  ✓" if is_active else ""
    color     = "#a6e3a1" if is_active else "#585b70"
    prefix    = "▶  " if is_active else "   "
    entries.append({
        "text": (
            f"<span color='{color}' size='large'>{prefix}{res}p{check}</span>"
        ),
        "markup": True,
        "data": f"__res_{res}__"
    })

# ── Subtitles toggle ───────────────────────────────────────────────────────────
if subtitles == "true":
    sub_label = "💬  Subtítulos: ON"
    sub_hint  = "Pulsa para desactivar"
    sub_color = "#a6e3a1"
else:
    sub_label = "💬  Subtítulos: OFF"
    sub_hint  = "Pulsa para activar"
    sub_color = "#585b70"

entries.append({
    "text": (
        "<span color='#6c7086'>SUBTÍTULOS</span>\n"
        f"<span color='{sub_color}' size='large'>{sub_label}</span>\n"
        f"<span color='#585b70'>{sub_hint}</span>"
    ),
    "markup": True,
    "data": "__toggle_subs__"
})

print(','.join(json.dumps(e, ensure_ascii=False) for e in entries))
PYEOF
}

# Minimal JSON string escaping for values embedded in printf-built JSON.
# Only handles backslashes and double-quotes — sufficient for our message strings.
json_str() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Emit a FEED view update to rofi (writes one JSON line to stdout).
# Shows the current settings summary in the message bar.
emit_feed() {
    local message="$1" lines_json="$2"
    # Re-read settings so the summary is always current (safe from subshell too)
    load_settings
    local summary msg_esc sum_esc
    summary=$(settings_summary)
    msg_esc=$(json_str "$message")
    sum_esc=$(json_str "$summary")
    printf '{"prompt":"🎬 Mi Feed","message":"%s  ·  ⚙ %s","event format":"{{data}}","lines":[%s]}\n' \
        "$msg_esc" "$sum_esc" "$lines_json"
}

# Emit a SETTINGS view update to rofi.
emit_settings() {
    local lines_json
    lines_json=$(build_settings_json)
    printf '{"prompt":"⚙  Ajustes","message":"Elige modo, resolución y subtítulos — pulsa ← para volver","event format":"{{data}}","lines":[%s]}\n' \
        "$lines_json"
}

# Emit a feed update ONLY when the user is currently on the feed view.
# Called from the background crawler subshell, which cannot read bash globals —
# so we check the shared VIEWMODE_FILE on disk instead.
emit_if_feed() {
    local message="$1" lines_json="$2"
    local current_mode
    current_mode=$(cat "$VIEWMODE_FILE" 2>/dev/null || printf 'feed')
    [[ "$current_mode" == "feed" ]] || return 0
    emit_feed "$message" "$lines_json"
}

# ─────────────────────────────────────────────────────────────────────────────
# § 5  PLAYBACK
# ─────────────────────────────────────────────────────────────────────────────

# Launch mpv for the given video ID, applying current playback settings.
# Reads settings fresh from disk so changes made during a session take effect
# immediately on the next video played.
launch_mpv() {
    local vid_id="$1"
    local url="https://www.youtube.com/watch?v=${vid_id}"

    # Always reload from disk — the user may have changed settings this session
    load_settings

    # ── yt-dlp format string ──────────────────────────────────────────────────
    # Audio-only: grab the best available audio stream, no video container.
    # Video mode: prefer MP4+M4A at or below the chosen height; fall back
    #             gracefully through combined formats down to "best".
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

    # Audio-only: suppress the video renderer and album-art display
    if [[ "$PLAY_MODE" == "audio" ]]; then
        args+=("--no-video" "--audio-display=no")
    fi

    # Subtitles: request auto-generated subs in Spanish and English.
    # write-auto-subs tells yt-dlp to fetch the subtitle track;
    # sub-auto=fuzzy tells mpv to attach any subtitle file it finds.
    if [[ "$SUBTITLES" == "true" ]]; then
        args+=(
            "--sub-auto=fuzzy"
            "--ytdl-raw-options-append=write-auto-subs="
            "--ytdl-raw-options-append=sub-langs=es.*,en.*"
        )
    fi

    # Best-effort title lookup for the notification
    local title=""
    if [[ -f "$CACHE_FILE" ]]; then
        title=$(grep "^${vid_id}"$'\t' "$CACHE_FILE" 2>/dev/null \
                | cut -f2 | head -1)
    fi

    local mode_label
    [[ "$PLAY_MODE" == "audio" ]] \
        && mode_label="🎵 Audio Only" \
        || mode_label="🎬 ${RESOLUTION}p"

    notify-send \
        -a "Mi Feed" \
        -i "mpv" \
        "▶ ${mode_label}" \
        "${title:-$vid_id}" \
        -t 3000 2>/dev/null || true

    # nohup detaches mpv from this shell so it survives rofi closing
    nohup mpv "${args[@]}" "$url" >/dev/null 2>&1 &
}

# ─────────────────────────────────────────────────────────────────────────────
# § 6  EVENT LOOP
# ─────────────────────────────────────────────────────────────────────────────
#
# State machine: VIEW_MODE ∈ { feed, settings }
# The current mode is tracked in $VIEWMODE_FILE so the background crawler
# subshell can check it without sharing bash globals with this process.
#
# Event dispatch table:
#   __cfg__           → switch to settings view
#   __back__          → switch back to feed view
#   __toggle_mode__   → cycle PLAY_MODE: video ↔ audio
#   __res_NNN__       → set RESOLUTION to NNN (360|480|720|1080)
#   __toggle_subs__   → toggle SUBTITLES: true ↔ false
#   __noop__          → intentionally ignored (separator rows)
#   [A-Za-z0-9_-]{11} → YouTube video ID — launch mpv
# ─────────────────────────────────────────────────────────────────────────────

handle_event() {
    local event="$1"

    case "$event" in

        # ── Enter settings view ───────────────────────────────────────────────
        __cfg__)
            printf 'settings' > "$VIEWMODE_FILE"
            emit_settings
            ;;

        # ── Return to feed view ───────────────────────────────────────────────
        __back__)
            printf 'feed' > "$VIEWMODE_FILE"
            local lines_json total_vids
            lines_json=$(build_feed_json "${CACHE_FILE:-/dev/null}")
            if [[ -f "$CACHE_FILE" && -s "$CACHE_FILE" ]]; then
                total_vids=$(wc -l < "$CACHE_FILE")
                emit_feed "📦 ${total_vids} vídeos" "$lines_json"
            else
                emit_feed "⏳ Sin cache — actualizando..." "$lines_json"
            fi
            ;;

        # ── Toggle play mode: video ↔ audio ───────────────────────────────────
        __toggle_mode__)
            [[ "$PLAY_MODE" == "video" ]] && PLAY_MODE="audio" || PLAY_MODE="video"
            save_settings
            emit_settings
            ;;

        # ── Set resolution (matches __res_360__, __res_480__, etc.) ───────────
        __res_*__)
            local res="${event#__res_}"    # strip leading  __res_
            res="${res%__}"               # strip trailing __
            if [[ "$res" =~ ^(360|480|720|1080)$ ]]; then
                RESOLUTION="$res"
                save_settings
            fi
            emit_settings
            ;;

        # ── Toggle subtitles: on ↔ off ────────────────────────────────────────
        __toggle_subs__)
            [[ "$SUBTITLES" == "true" ]] && SUBTITLES="false" || SUBTITLES="true"
            save_settings
            emit_settings
            ;;

        # ── Intentional no-op (separator/header rows in settings) ─────────────
        __noop__)
            # Re-emit current view so rofi does not hang on a non-event
            emit_settings
            ;;

        # ── Video ID: 11 alphanumeric chars → launch playback ─────────────────
        *)
            if printf '%s' "$event" | grep -qE '^[A-Za-z0-9_-]{11}$'; then
                launch_mpv "$event"
            fi
            ;;

    esac
}

# Block on stdin, dispatching each line to handle_event.
# Exits cleanly when rofi closes (stdin reaches EOF).
run_event_loop() {
    while IFS= read -r event; do
        [[ -n "$event" ]] && handle_event "$event"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# § 7  MAIN
# ─────────────────────────────────────────────────────────────────────────────

cleanup() {
    # Kill the background crawler if it is still running
    [[ -n "${CRAWLER_PID:-}" ]] && kill "$CRAWLER_PID" 2>/dev/null || true
    wait "${CRAWLER_PID:-}" 2>/dev/null || true
    # Remove the view-mode flag so stale state never leaks to a future session
    rm -f "$VIEWMODE_FILE"
}

main() {
    mkdir -p "$CACHE_DIR" "$CACHE_IDS" "$CACHE_THUMBS"
    load_settings
    printf 'feed' > "$VIEWMODE_FILE"
    trap cleanup EXIT INT TERM

    # ── Phase 1: immediate display from existing cache ────────────────────────
    # build_feed_json always prepends the ⚙ settings entry, even on empty cache.
    local lines_json
    if [[ -f "$CACHE_FILE" && -s "$CACHE_FILE" ]]; then
        local total_vids
        total_vids=$(wc -l < "$CACHE_FILE")
        lines_json=$(build_feed_json "$CACHE_FILE")
        emit_feed "📦 ${total_vids} vídeos — actualizando..." "$lines_json"
    else
        # First run — cache empty. Show settings entry + spinner message.
        lines_json=$(build_feed_json /dev/null)
        emit_feed "⏳ Cargando feed por primera vez..." "$lines_json"
    fi

    # ── Phase 2 & 3: background crawl — non-blocking, writes to cache ─────────
    # The subshell inherits all functions and current variable values.
    # It communicates back to rofi exclusively through emit_if_feed() → stdout.
    (run_crawler) &
    CRAWLER_PID=$!

    # ── Phase 4: event loop — blocks until rofi closes (EOF on stdin) ─────────
    run_event_loop

    # cleanup() is called automatically via the EXIT trap
}

# ── Entry point ────────────────────────────────────────────────────────────────
# --crawl-only: headless mode for cron/systemd. stdout → /dev/null, only the
#               TSV cache is updated. UI emit calls become no-ops.
if [[ "${1:-}" == "--crawl-only" ]]; then
    mkdir -p "$CACHE_DIR" "$CACHE_IDS" "$CACHE_THUMBS"
    load_settings
    exec 1>/dev/null   # Silence stdout — no rofi session to write to
    run_crawler
    exit 0
fi

main
