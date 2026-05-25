#!/usr/bin/env bash
# =============================================================================
# rofeed-worker.sh — Mi Feed · rofi-blocks worker
# Version: 0.4.0
# =============================================================================
#
# rofi-blocks protocol:
#   STDOUT → JSON lines  →  each line updates the rofi display
#   STDIN  ← selection events  ←  rofi sends the selected item's "data" value
#
# Special invocations:
#   rofeed-worker.sh --crawl-only
#     Headless crawl (cron / systemd timer). stdout → /dev/null.
#
# ─────────────────────────────────────────────────────────────────────────────
# File layout:
#   § 1  PATHS & CONSTANTS
#   § 2  SETTINGS           (load / save / defaults — persisted to disk)
#   § 3  CRAWLER STATUS     (real-time status file written by crawler)
#   § 4  DATA LAYER         (crawler — smart incremental, polite rate-limiting)
#   § 5  UI LAYER           (JSON builders, emit functions)
#   § 6  PLAYBACK           (mpv launcher with format / subtitle logic)
#   § 7  EVENT LOOP         (stdin handler + view-mode state machine)
#   § 8  MAIN               (orchestration + entry points)
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# § 1  PATHS & CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────

readonly ROFEED_VERSION="0.4.0"

readonly CONFIG_DIR="${HOME}/.config/rofeed"
readonly SUBS="${CONFIG_DIR}/subscriptions"
readonly CONFIG_FILE="${CONFIG_DIR}/config"

readonly CACHE_DIR="${HOME}/.cache/rofeed-feed"
readonly CACHE_IDS="${HOME}/.cache/rofeed-channel-ids"
readonly CACHE_THUMBS="${HOME}/.cache/rofeed-thumbs"
readonly CACHE_FILE="${CACHE_DIR}/videos.tsv"
readonly SETTINGS_FILE="${CACHE_DIR}/settings"
readonly LAST_UPDATE_FILE="${CACHE_DIR}/.last_update"

# Real-time crawler status file.
# Format:  idle | running:N:TOTAL | done | error
# Written by run_crawler(); read by the UI to show live progress.
readonly CRAWLER_STATUS_FILE="${CACHE_DIR}/.crawler_status"

# Shared between main process and background crawler subshell via the
# filesystem. Contains either "feed" or "settings".
readonly VIEWMODE_FILE="${CACHE_DIR}/.viewmode"

# Lock file — prevents two crawlers running simultaneously.
readonly CRAWL_LOCK="${CACHE_DIR}/.crawl.lock"

# ─────────────────────────────────────────────────────────────────────────────
# § 2  SETTINGS  (playback + crawler configuration)
# ─────────────────────────────────────────────────────────────────────────────

PLAY_MODE="video"    # "video"  | "audio"
RESOLUTION="480"     # "360" | "480" | "720" | "1080"
SUBTITLES="false"    # "true" | "false"

UPDATE_INTERVAL_MIN="30"
MAX_VIDEOS_PER_CHANNEL="30"
DATE_FROM=""
DATE_TO=""

load_settings() {
    local f
    for f in "$CONFIG_FILE" "$SETTINGS_FILE"; do
        [[ -f "$f" ]] || continue
        local key val
        while IFS='=' read -r key val; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"
            val="${val%\"}"
            val="${val#\"}"
            case "$key" in
                PLAY_MODE)
                    [[ "$val" =~ ^(video|audio)$ ]]      && PLAY_MODE="$val"  ;;
                RESOLUTION)
                    [[ "$val" =~ ^(360|480|720|1080)$ ]] && RESOLUTION="$val" ;;
                SUBTITLES)
                    [[ "$val" =~ ^(true|false)$ ]]        && SUBTITLES="$val"  ;;
                UPDATE_INTERVAL_MIN)
                    [[ "$val" =~ ^[0-9]+$ ]]             && UPDATE_INTERVAL_MIN="$val" ;;
                MAX_VIDEOS_PER_CHANNEL)
                    [[ "$val" =~ ^[0-9]+$ ]]             && MAX_VIDEOS_PER_CHANNEL="$val" ;;
                DATE_FROM)
                    [[ "$val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$|^$ ]] && DATE_FROM="$val" ;;
                DATE_TO)
                    [[ "$val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$|^$ ]] && DATE_TO="$val"   ;;
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

write_default_config() {
    [[ -f "$CONFIG_FILE" ]] && return 0
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << 'EOF'
# rofeed configuration — ~/.config/rofeed/config
# All values are optional; uncomment and edit to override the defaults.

# Minutes between automatic cache refreshes when the UI opens.
# Set to 0 to always refresh on every open.
# Minimum recommended: 5
UPDATE_INTERVAL_MIN="30"

# Maximum number of videos to keep per channel. 0 = unlimited.
MAX_VIDEOS_PER_CHANNEL="30"

# Show only videos published within this range. Leave blank to disable.
# Format: YYYY-MM-DD
DATE_FROM=""
DATE_TO=""
EOF
}

settings_summary() {
    local mode_str sub_str
    [[ "$PLAY_MODE" == "audio" ]] && mode_str="🎵 Audio" || mode_str="🎬 ${RESOLUTION}p"
    [[ "$SUBTITLES" == "true" ]]  && sub_str="CC:on"     || sub_str="CC:off"
    printf '%s  %s' "$mode_str" "$sub_str"
}

# ─────────────────────────────────────────────────────────────────────────────
# § 3  CRAWLER STATUS
#
# The crawler writes its real-time state to CRAWLER_STATUS_FILE.
# The UI reads this file to build the status bar item in the feed view.
# Protocol (one line, no newline at end):
#   idle           — no crawl running
#   running:N:T    — processing channel N of T
#   done:TOTAL     — finished, TOTAL videos in cache
#   error          — crawl failed
# ─────────────────────────────────────────────────────────────────────────────

crawler_status_write() {
    printf '%s' "$1" > "$CRAWLER_STATUS_FILE"
}

# Read current crawler status → human-readable label + data token for the row.
# Outputs two lines: label \n data
crawler_status_read() {
    local raw
    raw=$(cat "$CRAWLER_STATUS_FILE" 2>/dev/null || printf 'idle')

    case "$raw" in
        idle)
            local lbl
            lbl=$(last_update_label)
            printf '⏺  %s vídeos en caché  ·  %s\n__force_update__' \
                "$(wc -l < "$CACHE_FILE" 2>/dev/null || echo 0)" "$lbl"
            ;;
        running:*:*)
            local n t
            n="${raw#running:}"; n="${n%:*}"
            t="${raw##*:}"
            printf '🔄  Actualizando…  canal %s/%s\n__force_update__' "$n" "$t"
            ;;
        done:*)
            local total lbl
            total="${raw#done:}"
            lbl=$(last_update_label)
            printf '✅  %s vídeos en caché  ·  %s\n__force_update__' "$total" "$lbl"
            ;;
        error)
            printf '⚠  Error en la última actualización  ·  pulsa para reintentar\n__force_update__'
            ;;
        *)
            printf '⏺  %s vídeos en caché\n__force_update__' \
                "$(wc -l < "$CACHE_FILE" 2>/dev/null || echo 0)"
            ;;
    esac
}

# Human-readable age of the last update.
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

# NOTE: cache_is_stale() is NOT called by the UI launcher.
# Automatic refresh is the exclusive responsibility of the systemd timer
# (--crawl-only). This function is kept for future headless tooling.
cache_is_stale() {
    [[ "$UPDATE_INTERVAL_MIN" -eq 0 ]] && return 0
    [[ -f "$LAST_UPDATE_FILE" ]] || return 0

    local last_ts now_ts elapsed_min
    last_ts=$(cat "$LAST_UPDATE_FILE" 2>/dev/null || echo 0)
    now_ts=$(date +%s)
    elapsed_min=$(( (now_ts - last_ts) / 60 ))
    (( elapsed_min >= UPDATE_INTERVAL_MIN ))
}

# ─────────────────────────────────────────────────────────────────────────────
# § 4  DATA LAYER
# ─────────────────────────────────────────────────────────────────────────────

merge_tsv() {
    cat "$1" "$2" 2>/dev/null \
        | awk -F'\t' '!seen[$1]++' \
        | sort -t$'\t' -k4 -r
}

trim_cache() {
    local tsv_file="$1"
    [[ "$MAX_VIDEOS_PER_CHANNEL" -eq 0 ]] && return 0
    python3 - "$tsv_file" "$MAX_VIDEOS_PER_CHANNEL" << 'PYEOF'
import sys
path, cap = sys.argv[1], int(sys.argv[2])
counts, kept = {}, []
try:
    with open(path) as f:
        for line in f:
            parts = line.split('\t')
            if len(parts) < 3:
                continue
            ch = parts[2]
            counts[ch] = counts.get(ch, 0) + 1
            if counts[ch] <= cap:
                kept.append(line)
except FileNotFoundError:
    pass
with open(path, 'w') as f:
    f.writelines(kept)
PYEOF
}

apply_date_filter() {
    local tsv_file="$1"
    [[ -z "$DATE_FROM" && -z "$DATE_TO" ]] && return 0
    python3 - "$tsv_file" "${DATE_FROM:-}" "${DATE_TO:-}" << 'PYEOF'
import sys
path, d_from, d_to = sys.argv[1], sys.argv[2], sys.argv[3]
kept = []
try:
    with open(path) as f:
        for line in f:
            parts = line.split('\t')
            if len(parts) < 4:
                kept.append(line)
                continue
            date_col = parts[3][:10]
            if d_from and date_col < d_from:
                continue
            if d_to and date_col > d_to:
                continue
            kept.append(line)
except FileNotFoundError:
    pass
with open(path, 'w') as f:
    f.writelines(kept)
PYEOF
}

cached_video_ids() {
    [[ -f "$CACHE_FILE" ]] || return 0
    cut -f1 "$CACHE_FILE"
}

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

fetch_rss() {
    local channel_id="$1"
    curl -s --max-time 20 \
        "https://www.youtube.com/feeds/videos.xml?channel_id=${channel_id}" \
    | python3 -c "
import sys, xml.etree.ElementTree as ET
ns = {'atom':'http://www.w3.org/2005/Atom','yt':'http://www.youtube.com/xml/schemas/2015'}
try:
    root    = ET.parse(sys.stdin).getroot()
    ch_node = root.find('atom:author/atom:name', ns)
    ch_name = ch_node.text.strip() if ch_node is not None else 'Unknown'
    for e in root.findall('atom:entry', ns):
        vid  = e.find('yt:videoId', ns).text
        titl = (e.find('atom:title', ns).text or '').replace('\t',' ')
        pub  = e.find('atom:published', ns).text[:16].replace('T',' ')
        print(f'{vid}\t{titl}\t{ch_name}\t{pub}')
except Exception:
    sys.exit(1)
" 2>/dev/null
}

fetch_duration_single() {
    local vid_id="$1"
    local raw
    raw=$(nice -n 19 yt-dlp \
        --no-playlist \
        --skip-download \
        --print "%(duration)s" \
        "https://www.youtube.com/watch?v=${vid_id}" 2>/dev/null)
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        local secs=$((raw))
        if   (( secs >= 3600 )); then
            printf '%dh %dm %ds' "$((secs/3600))" "$(( (secs%3600)/60 ))" "$((secs%60))"
        elif (( secs >= 60 ));   then
            printf '%dm %ds' "$((secs/60))" "$((secs%60))"
        else
            printf '%ds' "$secs"
        fi
    else
        printf '?'
    fi
}

# Full incremental crawl.
# Writes CRAWLER_STATUS_FILE at every step so the UI can poll it.
run_crawler() {
    exec 9>"$CRAWL_LOCK"
    if ! flock -n 9; then
        return 0   # another instance already running
    fi

    [[ -f "$SUBS" ]] || { crawler_status_write 'idle'; flock -u 9; return 0; }

    local total
    total=$(grep -cvE '^\s*(#|$)' "$SUBS" 2>/dev/null || echo 0)
    [[ "$total" -eq 0 ]] && { crawler_status_write 'idle'; flock -u 9; return 0; }

    local cached_ids_file
    cached_ids_file=$(mktemp /tmp/rofeed-cachedids-XXXX)
    cached_video_ids > "$cached_ids_file"

    local count=0
    local tmpnew
    tmpnew=$(mktemp /tmp/rofeed-new-XXXX.tsv)

    while IFS= read -r url; do
        [[ -z "$url" || "$url" == \#* ]] && continue
        count=$(( count + 1 ))

        # ── Signal: processing channel N/total ───────────────────────────────
        crawler_status_write "running:${count}:${total}"

        # ── Resolve channel ID ────────────────────────────────────────────────
        local channel_id
        if printf '%s' "$url" | grep -q '/channel/UC'; then
            channel_id=$(printf '%s' "$url" | grep -o 'UC[^/]*' | head -1)
        else
            channel_id=$(resolve_channel_id "$url")
        fi
        [[ -z "$channel_id" ]] && continue

        # ── Fetch RSS ─────────────────────────────────────────────────────────
        local rssfile
        rssfile=$(mktemp /tmp/rofeed-rss-XXXX)
        fetch_rss "$channel_id" > "$rssfile"

        # ── Diff: which IDs are new? ──────────────────────────────────────────
        local new_ids_file
        new_ids_file=$(mktemp /tmp/rofeed-newids-XXXX)
        python3 - "$rssfile" "$cached_ids_file" "$new_ids_file" << 'PYEOF'
import sys
rss_path, cached_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(cached_path) as f:
        cached = set(l.strip() for l in f if l.strip())
except FileNotFoundError:
    cached = set()
new_ids = []
try:
    with open(rss_path) as f:
        for line in f:
            vid = line.split('\t')[0].strip()
            if vid and vid not in cached:
                new_ids.append(vid)
except FileNotFoundError:
    pass
with open(out_path, 'w') as f:
    f.write('\n'.join(new_ids) + ('\n' if new_ids else ''))
PYEOF

        local new_count
        new_count=$(wc -l < "$new_ids_file" | tr -d ' ')

        if [[ "$new_count" -eq 0 ]]; then
            rm -f "$rssfile" "$new_ids_file"
            continue
        fi

        # ── Fetch durations for new IDs only ──────────────────────────────────
        local durfile vid_idx
        durfile=$(mktemp /tmp/rofeed-dur-XXXX)
        vid_idx=0
        while IFS= read -r vid_id; do
            [[ -z "$vid_id" ]] && continue
            vid_idx=$(( vid_idx + 1 ))
            # Update status to show per-video granularity
            crawler_status_write "running:${count}:${total}"
            local dur
            dur=$(fetch_duration_single "$vid_id")
            printf '%s\t%s\n' "$vid_id" "$dur" >> "$durfile"
            sleep 0.4
        done < "$new_ids_file"

        # ── Join RSS + durations → tmpnew ─────────────────────────────────────
        python3 - "$rssfile" "$new_ids_file" "$durfile" "$tmpnew" << 'PYEOF'
import sys
rss_path, new_ids_path, dur_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    with open(new_ids_path) as f:
        new_ids = set(l.strip() for l in f if l.strip())
except FileNotFoundError:
    new_ids = set()
durations = {}
try:
    with open(dur_path) as f:
        for line in f:
            parts = line.rstrip('\n').split('\t')
            if len(parts) == 2:
                durations[parts[0]] = parts[1]
except FileNotFoundError:
    pass
rows = []
try:
    with open(rss_path) as f:
        for line in f:
            parts = line.rstrip('\n').split('\t')
            if len(parts) < 4:
                continue
            vid_id = parts[0]
            if vid_id not in new_ids:
                continue
            rows.append(f'{vid_id}\t{parts[1]}\t{parts[2]}\t{parts[3]}\t{durations.get(vid_id,"?")}\n')
except FileNotFoundError:
    pass
with open(out_path, 'a') as f:
    f.writelines(rows)
PYEOF

        rm -f "$rssfile" "$new_ids_file" "$durfile"

        # ── Emit incremental feed update ──────────────────────────────────────
        local tmpmerge total_vids lines_json
        tmpmerge=$(mktemp /tmp/rofeed-merge-XXXX.tsv)
        merge_tsv "$tmpnew" "$CACHE_FILE" > "$tmpmerge"
        total_vids=$(wc -l < "$tmpmerge")
        lines_json=$(build_feed_json "$tmpmerge")
        emit_if_feed "" "$lines_json"
        rm -f "$tmpmerge"

    done < "$SUBS"

    # ── Atomic commit ─────────────────────────────────────────────────────────
    local tmpfinal
    tmpfinal=$(mktemp /tmp/rofeed-final-XXXX.tsv)
    merge_tsv "$tmpnew" "$CACHE_FILE" > "$tmpfinal"
    apply_date_filter "$tmpfinal"
    trim_cache "$tmpfinal"
    mv "$tmpfinal" "$CACHE_FILE"
    rm -f "$tmpnew" "$cached_ids_file"

    date +%s > "$LAST_UPDATE_FILE"

    local total_vids
    total_vids=$(wc -l < "$CACHE_FILE")
    crawler_status_write "done:${total_vids}"

    local lines_json
    lines_json=$(build_feed_json "$CACHE_FILE")
    emit_if_feed "" "$lines_json"

    flock -u 9
}

# ─────────────────────────────────────────────────────────────────────────────
# § 5  UI LAYER
# ─────────────────────────────────────────────────────────────────────────────

# Build the feed JSON array.
# Row 0: status bar (clickable, shows crawler state + cache size).
# Row 1…N: video entries with thumbnail.
build_feed_json() {
    local tsv_file="$1"
    local status_label status_data
    # Read two lines from crawler_status_read
    local _sr
    _sr=$(crawler_status_read)
    status_label=$(printf '%s' "$_sr" | head -1)
    status_data=$(printf '%s' "$_sr" | tail -1)

    python3 - "$tsv_file" "$CACHE_THUMBS" "$status_label" "$status_data" << 'PYEOF'
import sys, json, os, subprocess, threading

tsv_file     = sys.argv[1]
thumb_dir    = sys.argv[2]
status_label = sys.argv[3]
status_data  = sys.argv[4]

rows = []
try:
    with open(tsv_file) as f:
        for raw in f:
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

# Parallel thumbnail downloads (only missing)
def download_thumb(vid_id):
    path = os.path.join(thumb_dir, f'{vid_id}.jpg')
    if os.path.exists(path):
        return
    try:
        subprocess.run(
            ['curl', '-s', '--max-time', '10',
             f'https://i.ytimg.com/vi/{vid_id}/mqdefault.jpg', '-o', path],
            timeout=12, capture_output=True
        )
    except Exception:
        pass

threads = [threading.Thread(target=download_thumb, args=(r['vid_id'],)) for r in rows]
for t in threads: t.start()
for t in threads: t.join()

result = []

# ── Row 0: status / update bar ────────────────────────────────────────────────
# Colour the label depending on whether a crawl is running
is_running = status_data == '__force_update__' and '🔄' in status_label
lbl_color  = '#fab387' if is_running else '#a6adc8'
result.append(json.dumps({
    "text": f"<span color='{lbl_color}'>{status_label}</span>",
    "markup": True,
    "data": status_data,
}, ensure_ascii=False))

# ── Row 1: settings shortcut ──────────────────────────────────────────────────
result.append(json.dumps({
    "text": (
        "<span color='#89dceb'>⚙  Ajustes</span>"
        "  <span color='#585b70'>modo · resolución · subtítulos · intervalo</span>"
    ),
    "markup": True,
    "data": "__cfg__"
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
        "data": r['vid_id'],
    }
    if os.path.exists(thumb_path):
        entry["icon"] = thumb_path
    result.append(json.dumps(entry, ensure_ascii=False))

print(','.join(result))
PYEOF
}

# Build the settings JSON array.
# Philosophy: compact single-line rows, toggles first, selectors after.
# No icon, minimal padding handled by the .rasi settings class.
build_settings_json() {
    local last_label interval_label
    last_label=$(last_update_label)
    interval_label="${UPDATE_INTERVAL_MIN} min"
    [[ "$UPDATE_INTERVAL_MIN" -eq 0 ]] && interval_label="siempre"

    python3 - \
        "$PLAY_MODE" "$RESOLUTION" "$SUBTITLES" \
        "$last_label" "$interval_label" \
        "$UPDATE_INTERVAL_MIN" \
        "$MAX_VIDEOS_PER_CHANNEL" \
        "${DATE_FROM:-}" "${DATE_TO:-}" \
        << 'PYEOF'
import sys, json

play_mode, resolution, subtitles   = sys.argv[1], sys.argv[2], sys.argv[3]
last_label, intv_label, interval   = sys.argv[4], sys.argv[5], sys.argv[6]
max_vids, date_from, date_to       = sys.argv[7], sys.argv[8], sys.argv[9]

e = []

def row(text, data, *, active=False):
    color = '#cdd6f4' if active else '#a6adc8'
    check = '  ✓' if active else ''
    return {"text": f"<span color='{color}'>{text}{check}</span>",
            "markup": True, "data": data}

def section(label):
    return {"text": f"<span color='#45475a' size='small'>── {label} ──</span>",
            "markup": True, "data": "__noop__"}

# ── Navigation ────────────────────────────────────────────────────────────────
e.append({"text": "<span color='#f38ba8'>←  Volver al Feed</span>",
           "markup": True, "data": "__back__"})

# ── Toggles (first, most-used) ────────────────────────────────────────────────
e.append(section("REPRODUCCIÓN"))

mode_label = "🎵  Audio Only" if play_mode == "audio" else "🎬  Video + Audio"
mode_color = "#cba6f7" if play_mode == "audio" else "#89dceb"
e.append({"text": f"<span color='{mode_color}'>{mode_label}</span>",
           "markup": True, "data": "__toggle_mode__"})

sub_on    = subtitles == "true"
sub_color = "#a6e3a1" if sub_on else "#6c7086"
sub_lbl   = "💬  Subtítulos: ON" if sub_on else "💬  Subtítulos: OFF"
e.append({"text": f"<span color='{sub_color}'>{sub_lbl}</span>",
           "markup": True, "data": "__toggle_subs__"})

# ── Resolution (compact selector, all on visible rows) ────────────────────────
e.append(section("RESOLUCIÓN"))
for res in ["360", "480", "720", "1080"]:
    active = res == resolution
    color  = "#a6e3a1" if active else "#6c7086"
    check  = "  ✓" if active else ""
    e.append({"text": f"<span color='{color}'>  {res}p{check}</span>",
               "markup": True, "data": f"__res_{res}__"})

# ── Update interval ───────────────────────────────────────────────────────────
e.append(section("INTERVALO DE ACTUALIZACIÓN"))
for val, label in [("0","Siempre"),("5","5 min"),("10","10 min"),
                   ("15","15 min"),("30","30 min"),("60","1 h"),("180","3 h")]:
    active = val == interval
    color  = "#a6e3a1" if active else "#6c7086"
    check  = "  ✓" if active else ""
    e.append({"text": f"<span color='{color}'>  {label}{check}</span>",
               "markup": True, "data": f"__intv_{val}__"})

# ── Forzar actualización ──────────────────────────────────────────────────────
e.append(section("CACHÉ"))
cap_label = f"{max_vids} por canal" if max_vids != "0" else "sin límite"
df_label  = date_from if date_from else "—"
dt_label  = date_to   if date_to   else "—"
e.append({"text": (
    f"<span color='#6c7086'>  Máx {cap_label}  ·  "
    f"Desde {df_label} → {dt_label}  ·  edita config para cambiar</span>"),
    "markup": True, "data": "__noop__"})

e.append({"text": "<span color='#fab387'>🔄  Forzar actualización ahora</span>",
           "markup": True, "data": "__force_update__"})

print(','.join(json.dumps(x, ensure_ascii=False) for x in e))
PYEOF
}

json_str() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

emit_feed() {
    local message="$1" lines_json="$2"
    load_settings
    local summary msg_esc sum_esc
    summary=$(settings_summary)
    # message is now empty string when called from crawler (status is in row 0)
    if [[ -z "$message" ]]; then
        msg_esc=$(json_str "$(settings_summary)")
        printf '{"prompt":"🎬 Mi Feed","message":"%s","event format":"{{data}}","lines":[%s]}\n' \
            "$msg_esc" "$lines_json"
    else
        msg_esc=$(json_str "$message")
        sum_esc=$(json_str "$summary")
        printf '{"prompt":"🎬 Mi Feed","message":"%s  ·  %s","event format":"{{data}}","lines":[%s]}\n' \
            "$msg_esc" "$sum_esc" "$lines_json"
    fi
}

emit_settings() {
    local lines_json
    lines_json=$(build_settings_json)
    local last_esc intv_esc
    last_esc=$(json_str "$(last_update_label)")
    intv_esc=$(json_str "${UPDATE_INTERVAL_MIN} min")
    printf '{"prompt":"⚙  Ajustes","message":"%s  ·  intervalo %s","event format":"{{data}}","lines":[%s]}\n' \
        "$last_esc" "$intv_esc" "$lines_json"
}

emit_if_feed() {
    local message="$1" lines_json="$2"
    local current_mode
    current_mode=$(cat "$VIEWMODE_FILE" 2>/dev/null || printf 'feed')
    [[ "$current_mode" == "feed" ]] || return 0
    emit_feed "$message" "$lines_json"
}

# ─────────────────────────────────────────────────────────────────────────────
# § 6  PLAYBACK
# ─────────────────────────────────────────────────────────────────────────────

launch_mpv() {
    local vid_id="$1"
    local url="https://www.youtube.com/watch?v=${vid_id}"
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

    local title=""
    [[ -f "$CACHE_FILE" ]] && title=$(grep "^${vid_id}"$'\t' "$CACHE_FILE" 2>/dev/null \
                                      | cut -f2 | head -1)
    local mode_label
    [[ "$PLAY_MODE" == "audio" ]] && mode_label="🎵 Audio Only" || mode_label="🎬 ${RESOLUTION}p"

    notify-send -a "Mi Feed" -i "mpv" "▶ ${mode_label}" "${title:-$vid_id}" -t 3000 2>/dev/null || true
    nohup mpv "${args[@]}" "$url" >/dev/null 2>&1 &
}

# ─────────────────────────────────────────────────────────────────────────────
# § 7  EVENT LOOP
# ─────────────────────────────────────────────────────────────────────────────
#
# State machine: VIEW_MODE ∈ { feed, settings }
#
# Events:
#   __cfg__           → settings view
#   __back__          → feed view
#   __force_update__  → immediate crawl + back to feed
#   __toggle_mode__   → video ↔ audio
#   __res_NNN__       → set resolution
#   __intv_NNN__      → set update interval (persists to config)
#   __toggle_subs__   → subtitles on/off
#   __noop__          → re-emit current view (separator rows)
#   [A-Za-z0-9_-]{11} → launch mpv
# ─────────────────────────────────────────────────────────────────────────────

save_interval() {
    local val="$1"
    mkdir -p "$CONFIG_DIR"
    if grep -q '^UPDATE_INTERVAL_MIN=' "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s/^UPDATE_INTERVAL_MIN=.*/UPDATE_INTERVAL_MIN=\"${val}\"/" "$CONFIG_FILE"
    else
        printf '\nUPDATE_INTERVAL_MIN="%s"\n' "$val" >> "$CONFIG_FILE"
    fi
    UPDATE_INTERVAL_MIN="$val"
}

_emit_current_feed() {
    local lines_json total_vids lbl
    lines_json=$(build_feed_json "${CACHE_FILE:-/dev/null}")
    if [[ -f "$CACHE_FILE" && -s "$CACHE_FILE" ]]; then
        emit_feed "" "$lines_json"
    else
        emit_feed "⏳ Sin caché — actualizando…" "$lines_json"
    fi
}

handle_event() {
    local event="$1"

    case "$event" in

        __cfg__)
            printf 'settings' > "$VIEWMODE_FILE"
            emit_settings
            ;;

        __back__)
            printf 'feed' > "$VIEWMODE_FILE"
            _emit_current_feed
            ;;

        __force_update__)
            # Kick off crawler if not already running, then go back to feed
            # so the user sees live status updates in row 0.
            rm -f "$LAST_UPDATE_FILE"
            crawler_status_write 'running:0:?'
            printf 'feed' > "$VIEWMODE_FILE"
            _emit_current_feed
            if [[ -z "${CRAWLER_PID:-}" ]] || ! kill -0 "$CRAWLER_PID" 2>/dev/null; then
                (run_crawler) &
                CRAWLER_PID=$!
            fi
            ;;

        __toggle_mode__)
            [[ "$PLAY_MODE" == "video" ]] && PLAY_MODE="audio" || PLAY_MODE="video"
            save_settings; emit_settings
            ;;

        __res_*__)
            local res="${event#__res_}"; res="${res%__}"
            [[ "$res" =~ ^(360|480|720|1080)$ ]] && { RESOLUTION="$res"; save_settings; }
            emit_settings
            ;;

        __intv_*__)
            local intv="${event#__intv_}"; intv="${intv%__}"
            [[ "$intv" =~ ^(0|5|10|15|30|60|180)$ ]] && save_interval "$intv"
            emit_settings
            ;;

        __toggle_subs__)
            [[ "$SUBTITLES" == "true" ]] && SUBTITLES="false" || SUBTITLES="true"
            save_settings; emit_settings
            ;;

        __noop__)
            # Re-emit to avoid rofi hanging; check current view
            local cur_mode
            cur_mode=$(cat "$VIEWMODE_FILE" 2>/dev/null || printf 'feed')
            if [[ "$cur_mode" == "settings" ]]; then
                emit_settings
            else
                _emit_current_feed
            fi
            ;;

        *)
            if printf '%s' "$event" | grep -qE '^[A-Za-z0-9_-]{11}$'; then
                launch_mpv "$event"
            fi
            ;;

    esac
}

run_event_loop() {
    while IFS= read -r event; do
        [[ -n "$event" ]] && handle_event "$event"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# § 8  MAIN
# ─────────────────────────────────────────────────────────────────────────────

cleanup() {
    [[ -n "${CRAWLER_PID:-}" ]] && kill "$CRAWLER_PID" 2>/dev/null || true
    wait "${CRAWLER_PID:-}" 2>/dev/null || true
    # Only reset status to idle if we are the session that wrote it.
    # (The systemd crawl-only mode manages its own status.)
    local cur_status
    cur_status=$(cat "$CRAWLER_STATUS_FILE" 2>/dev/null || printf '')
    [[ "$cur_status" == running:* ]] && crawler_status_write 'idle'
    rm -f "$VIEWMODE_FILE"
}

main() {
    mkdir -p "$CACHE_DIR" "$CACHE_IDS" "$CACHE_THUMBS" "$CONFIG_DIR"
    write_default_config
    load_settings
    printf 'feed' > "$VIEWMODE_FILE"
    trap cleanup EXIT INT TERM

    # Ensure status file exists so the first build_feed_json call succeeds.
    # The crawler (systemd timer / --crawl-only) owns this file; we only
    # initialise it here if it has never been written.
    [[ -f "$CRAWLER_STATUS_FILE" ]] || crawler_status_write 'idle'

    # Render from existing cache — no automatic crawl.
    # Updates are driven exclusively by the systemd timer (--crawl-only) or
    # by the user pressing "Forzar actualización" in the UI.
    local lines_json
    if [[ -f "$CACHE_FILE" && -s "$CACHE_FILE" ]]; then
        lines_json=$(build_feed_json "$CACHE_FILE")
        emit_feed "" "$lines_json"
    else
        lines_json=$(build_feed_json /dev/null)
        emit_feed "⏳ Sin caché — usa 'Forzar actualización' o activa el timer" "$lines_json"
    fi

    CRAWLER_PID=""
    run_event_loop
}

# ── Entry points ───────────────────────────────────────────────────────────────
case "${1:-}" in
    --crawl-only)
        mkdir -p "$CACHE_DIR" "$CACHE_IDS" "$CACHE_THUMBS" "$CONFIG_DIR"
        write_default_config
        load_settings
        [[ -f "$CRAWLER_STATUS_FILE" ]] || crawler_status_write 'idle'
        exec 1>/dev/null
        run_crawler
        exit 0
        ;;
    --version)
        printf 'rofeed %s\n' "$ROFEED_VERSION"
        exit 0
        ;;
    "")
        main
        ;;
    *)
        printf 'Usage: rofeed-worker.sh [--crawl-only|--version]\n' >&2
        exit 1
        ;;
esac
