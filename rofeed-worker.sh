#!/usr/bin/env bash
# =============================================================================
# rofeed-worker.sh — Mi Feed · rofi-blocks worker
# Version: 0.3.0
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
#   § 3  DATA LAYER         (crawler — smart incremental, polite rate-limiting)
#   § 4  UI LAYER           (JSON builders, emit functions)
#   § 5  PLAYBACK           (mpv launcher with format / subtitle logic)
#   § 6  EVENT LOOP         (stdin handler + view-mode state machine)
#   § 7  MAIN               (orchestration + entry points)
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# § 1  PATHS & CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────

readonly ROFEED_VERSION="0.3.0"

readonly CONFIG_DIR="${HOME}/.config/rofeed"
readonly SUBS="${CONFIG_DIR}/subscriptions"
readonly CONFIG_FILE="${CONFIG_DIR}/config"

readonly CACHE_DIR="${HOME}/.cache/rofeed-feed"
readonly CACHE_IDS="${HOME}/.cache/rofeed-channel-ids"
readonly CACHE_THUMBS="${HOME}/.cache/rofeed-thumbs"
readonly CACHE_FILE="${CACHE_DIR}/videos.tsv"
readonly SETTINGS_FILE="${CACHE_DIR}/settings"
readonly LAST_UPDATE_FILE="${CACHE_DIR}/.last_update"

# Shared between main process and background crawler subshell via the
# filesystem. Contains either "feed" or "settings".
readonly VIEWMODE_FILE="${CACHE_DIR}/.viewmode"

# Lock file — prevents two crawlers running simultaneously (e.g. timer fires
# while user opens the UI).
readonly CRAWL_LOCK="${CACHE_DIR}/.crawl.lock"

# ─────────────────────────────────────────────────────────────────────────────
# § 2  SETTINGS  (playback + crawler configuration)
# ─────────────────────────────────────────────────────────────────────────────

# ── Playback defaults ─────────────────────────────────────────────────────────
PLAY_MODE="video"    # "video"  | "audio"
RESOLUTION="480"     # "360" | "480" | "720" | "1080"
SUBTITLES="false"    # "true" | "false"

# ── Crawler / feed defaults ───────────────────────────────────────────────────
# UPDATE_INTERVAL_MIN: minutes between automatic refreshes when the UI opens.
#   Set to 0 to always refresh on open.
UPDATE_INTERVAL_MIN="30"

# MAX_VIDEOS_PER_CHANNEL: how many videos to keep per channel in the TSV cache.
#   The YouTube Atom feed always returns the last 15; this cap applies to the
#   cache trim after merge (set to 0 = unlimited).
MAX_VIDEOS_PER_CHANNEL="30"

# DATE_FROM / DATE_TO: optional ISO-8601 date filters (YYYY-MM-DD).
#   Leave empty to keep all fetched videos.
DATE_FROM=""
DATE_TO=""

# ── Load all persisted settings from disk ─────────────────────────────────────
load_settings() {
    local f
    # Load user config first (crawler settings live here)
    for f in "$CONFIG_FILE" "$SETTINGS_FILE"; do
        [[ -f "$f" ]] || continue
        local key val
        while IFS='=' read -r key val; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue   # skip comments
            # Strip surrounding whitespace and quotes
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

# Persist playback settings (only) to ~/.cache/rofeed-feed/settings.
# Crawler/feed settings are read-only from ~/.config/rofeed/config.
save_settings() {
    mkdir -p "$CACHE_DIR"
    printf 'PLAY_MODE="%s"\nRESOLUTION="%s"\nSUBTITLES="%s"\n' \
        "$PLAY_MODE" "$RESOLUTION" "$SUBTITLES" \
        > "$SETTINGS_FILE"
}

# Write a well-commented default config if none exists yet.
write_default_config() {
    [[ -f "$CONFIG_FILE" ]] && return 0
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << 'EOF'
# rofeed configuration — ~/.config/rofeed/config
# All values are optional; uncomment and edit to override the defaults.

# ── Update interval ────────────────────────────────────────────────────────────
# Minutes between automatic cache refreshes when the UI opens.
# Set to 0 to always refresh on every open.
# Minimum recommended: 5  (YouTube Atom feeds update at most every few minutes)
UPDATE_INTERVAL_MIN="30"

# ── Cache size ─────────────────────────────────────────────────────────────────
# Maximum number of videos to keep per channel.
# 0 = unlimited (the cache will grow indefinitely).
MAX_VIDEOS_PER_CHANNEL="30"

# ── Date filter (optional) ─────────────────────────────────────────────────────
# Show only videos published within this range.  Leave blank to disable.
# Format: YYYY-MM-DD
DATE_FROM=""
DATE_TO=""
EOF
}

# One-liner shown in the message bar while browsing the feed.
settings_summary() {
    local mode_str sub_str
    if [[ "$PLAY_MODE" == "audio" ]]; then
        mode_str="🎵 Audio"
    else
        mode_str="🎬 ${RESOLUTION}p"
    fi
    [[ "$SUBTITLES" == "true" ]] && sub_str="CC:on" || sub_str="CC:off"
    printf '%s  %s' "$mode_str" "$sub_str"
}

# ─────────────────────────────────────────────────────────────────────────────
# § 3  DATA LAYER
#
# Design goals:
#   • Incremental — only fetch durations for video IDs not already cached.
#   • Polite — one channel at a time; yt-dlp runs at nice 19.
#   • No yt-dlp playlist scraping — durations are fetched per-ID via the
#     oEmbed / yt-dlp single-video path, which is much lighter than a full
#     playlist crawl and avoids playlist-end limits entirely.
#   • RSS-first — the Atom feed is the source of truth for new video IDs.
#     yt-dlp is only called for IDs whose duration is unknown ("?") in cache.
# ─────────────────────────────────────────────────────────────────────────────

# Merge two TSV files: deduplicate by video ID (col 1), sort by date (col 4)
# descending.  Accepts /dev/null for a missing file.
merge_tsv() {
    cat "$1" "$2" 2>/dev/null \
        | awk -F'\t' '!seen[$1]++' \
        | sort -t$'\t' -k4 -r
}

# Trim the merged cache: keep at most MAX_VIDEOS_PER_CHANNEL rows per channel.
# If MAX_VIDEOS_PER_CHANNEL == 0 the file is returned unchanged.
trim_cache() {
    local tsv_file="$1"
    [[ "$MAX_VIDEOS_PER_CHANNEL" -eq 0 ]] && return 0
    python3 - "$tsv_file" "$MAX_VIDEOS_PER_CHANNEL" << 'PYEOF'
import sys

path    = sys.argv[1]
cap     = int(sys.argv[2])
counts  = {}
kept    = []

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

# Apply optional date filters (DATE_FROM / DATE_TO) to a TSV file in-place.
# Column 4 (index 3) is the publication date (YYYY-MM-DD HH:MM).
apply_date_filter() {
    local tsv_file="$1"
    [[ -z "$DATE_FROM" && -z "$DATE_TO" ]] && return 0
    python3 - "$tsv_file" "${DATE_FROM:-}" "${DATE_TO:-}" << 'PYEOF'
import sys

path    = sys.argv[1]
d_from  = sys.argv[2]   # "" or "YYYY-MM-DD"
d_to    = sys.argv[3]   # "" or "YYYY-MM-DD"
kept    = []

try:
    with open(path) as f:
        for line in f:
            parts = line.split('\t')
            if len(parts) < 4:
                kept.append(line)
                continue
            date_col = parts[3][:10]   # "YYYY-MM-DD"
            if d_from and date_col < d_from:
                continue
            if d_to   and date_col > d_to:
                continue
            kept.append(line)
except FileNotFoundError:
    pass

with open(path, 'w') as f:
    f.writelines(kept)
PYEOF
}

# Return the set of video IDs already present in the cache (one per line).
cached_video_ids() {
    [[ -f "$CACHE_FILE" ]] || return 0
    cut -f1 "$CACHE_FILE"
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
# The feed returns the 15 most recent videos — no pagination, no yt-dlp needed.
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

# Fetch the duration for a single video ID using yt-dlp.
# This approach is much lighter than a full playlist scrape: one HTTP request
# per video, only issued for IDs whose duration is still unknown ("?").
# Returns a human string like "1h 23m 45s", "12m 34s", "45s", or "?".
# Runs at nice 19 to avoid competing with the interactive session.
fetch_duration_single() {
    local vid_id="$1"
    local url="https://www.youtube.com/watch?v=${vid_id}"
    local raw
    raw=$(nice -n 19 yt-dlp \
        --no-playlist \
        --skip-download \
        --print "%(duration)s" \
        "$url" 2>/dev/null)

    # yt-dlp prints the duration in seconds (integer) or "NA" / empty
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        local secs=$((raw))
        if   (( secs >= 3600 )); then
            printf '%dh %dm %ds' "$((secs/3600))" "$(( (secs%3600)/60 ))" "$((secs%60))"
        elif (( secs >= 60 )); then
            printf '%dm %ds' "$((secs/60))" "$((secs%60))"
        else
            printf '%ds' "$secs"
        fi
    else
        printf '?'
    fi
}

# Full crawl: iterate subscriptions, fetch RSS, resolve new IDs, fetch
# durations only for entries not already cached, then merge.
# Emits incremental progress updates to the feed view while running.
run_crawler() {
    # Acquire an exclusive lock to prevent concurrent crawls.
    # Uses a FD-based flock so the lock is released if the process dies.
    exec 9>"$CRAWL_LOCK"
    if ! flock -n 9; then
        # Another crawl is already running — nothing to do.
        return 0
    fi

    [[ -f "$SUBS" ]] || { flock -u 9; return 0; }

    local total count
    total=$(grep -cvE '^\s*(#|$)' "$SUBS" 2>/dev/null || echo 0)
    [[ "$total" -eq 0 ]] && { flock -u 9; return 0; }

    # Build a fast lookup set of already-cached video IDs.
    # We write them to a temp file so the Python join below can use it.
    local cached_ids_file
    cached_ids_file=$(mktemp /tmp/rofeed-cachedids-XXXX)
    cached_video_ids > "$cached_ids_file"

    count=0
    local tmpnew
    tmpnew=$(mktemp /tmp/rofeed-new-XXXX.tsv)

    while IFS= read -r url; do
        [[ -z "$url" || "$url" == \#* ]] && continue
        count=$((count + 1))

        # ── Resolve channel ID ────────────────────────────────────────────────
        local channel_id
        if printf '%s' "$url" | grep -q '/channel/UC'; then
            channel_id=$(printf '%s' "$url" | grep -o 'UC[^/]*' | head -1)
        else
            channel_id=$(resolve_channel_id "$url")
        fi
        [[ -z "$channel_id" ]] && continue

        # ── Fetch RSS (cheap, no yt-dlp) ──────────────────────────────────────
        local rssfile
        rssfile=$(mktemp /tmp/rofeed-rss-XXXX)
        fetch_rss "$channel_id" > "$rssfile"

        # ── Determine which IDs are NEW (not in cache) ────────────────────────
        # Python set-diff is fast even for large caches.
        local new_ids_file
        new_ids_file=$(mktemp /tmp/rofeed-newids-XXXX)
        python3 - "$rssfile" "$cached_ids_file" "$new_ids_file" << 'PYEOF'
import sys

rss_path    = sys.argv[1]   # TSV: vid_id \t title \t channel \t date
cached_path = sys.argv[2]   # plain text: one vid_id per line
out_path    = sys.argv[3]   # output: new vid_ids one per line

try:
    with open(cached_path) as f:
        cached = set(line.strip() for line in f if line.strip())
except FileNotFoundError:
    cached = set()

new_ids = []
try:
    with open(rss_path) as f:
        for line in f:
            vid_id = line.split('\t')[0].strip()
            if vid_id and vid_id not in cached:
                new_ids.append(vid_id)
except FileNotFoundError:
    pass

with open(out_path, 'w') as f:
    f.write('\n'.join(new_ids) + ('\n' if new_ids else ''))
PYEOF

        local new_count
        new_count=$(wc -l < "$new_ids_file" | tr -d ' ')

        if [[ "$new_count" -eq 0 ]]; then
            # Nothing new from this channel — skip yt-dlp entirely.
            rm -f "$rssfile" "$new_ids_file"
            continue
        fi

        # ── Fetch durations only for new IDs ──────────────────────────────────
        # We run requests sequentially with a small polite delay to avoid
        # hammering YouTube.  yt-dlp --print is a single lightweight request
        # per video (no playlist scrape, no format enumeration).
        local durfile
        durfile=$(mktemp /tmp/rofeed-dur-XXXX)

        while IFS= read -r vid_id; do
            [[ -z "$vid_id" ]] && continue
            local dur
            dur=$(fetch_duration_single "$vid_id")
            printf '%s\t%s\n' "$vid_id" "$dur" >> "$durfile"
            # Brief pause — polite, and YouTube Atom is unauthenticated so
            # there is no personal quota, but rapid fire can trigger 429s.
            sleep 0.4
        done < "$new_ids_file"

        # ── Join RSS with durations for new entries only ──────────────────────
        # Entries already in cache are kept as-is via merge_tsv below.
        python3 - "$rssfile" "$new_ids_file" "$durfile" "$tmpnew" << 'PYEOF'
import sys

rss_path    = sys.argv[1]
new_ids_path= sys.argv[2]
dur_path    = sys.argv[3]
out_path    = sys.argv[4]

try:
    with open(new_ids_path) as f:
        new_ids = set(line.strip() for line in f if line.strip())
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
            dur = durations.get(vid_id, '?')
            rows.append(f'{vid_id}\t{parts[1]}\t{parts[2]}\t{parts[3]}\t{dur}\n')
except FileNotFoundError:
    pass

with open(out_path, 'a') as f:
    f.writelines(rows)
PYEOF

        rm -f "$rssfile" "$new_ids_file" "$durfile"

        # ── Emit incremental progress ─────────────────────────────────────────
        local tmpmerge total_vids lines_json
        tmpmerge=$(mktemp /tmp/rofeed-merge-XXXX.tsv)
        merge_tsv "$tmpnew" "$CACHE_FILE" > "$tmpmerge"
        total_vids=$(wc -l < "$tmpmerge")
        lines_json=$(build_feed_json "$tmpmerge")
        emit_if_feed "🔄 Canal ${count}/${total}  (+${new_count} nuevos) — ${total_vids} vídeos" \
            "$lines_json"
        rm -f "$tmpmerge"

    done < "$SUBS"

    # ── Atomic cache update ───────────────────────────────────────────────────
    local tmpfinal
    tmpfinal=$(mktemp /tmp/rofeed-final-XXXX.tsv)
    merge_tsv "$tmpnew" "$CACHE_FILE" > "$tmpfinal"
    apply_date_filter "$tmpfinal"
    trim_cache "$tmpfinal"
    mv "$tmpfinal" "$CACHE_FILE"
    rm -f "$tmpnew" "$cached_ids_file"

    # Record the timestamp of this successful crawl.
    date +%s > "$LAST_UPDATE_FILE"

    local total_vids lines_json
    total_vids=$(wc -l < "$CACHE_FILE")
    lines_json=$(build_feed_json "$CACHE_FILE")
    emit_if_feed "✅ Actualizado — ${total_vids} vídeos" "$lines_json"

    flock -u 9
}

# ─────────────────────────────────────────────────────────────────────────────
# Check whether a crawl is needed based on the last-update timestamp and the
# configured UPDATE_INTERVAL_MIN setting.
# Returns 0 (true) if a crawl should run, 1 if the cache is still fresh.
# ─────────────────────────────────────────────────────────────────────────────
cache_is_stale() {
    # UPDATE_INTERVAL_MIN=0 means "always refresh"
    [[ "$UPDATE_INTERVAL_MIN" -eq 0 ]] && return 0

    [[ -f "$LAST_UPDATE_FILE" ]] || return 0   # never updated → stale

    local last_ts now_ts elapsed_min
    last_ts=$(cat "$LAST_UPDATE_FILE" 2>/dev/null || echo 0)
    now_ts=$(date +%s)
    elapsed_min=$(( (now_ts - last_ts) / 60 ))

    (( elapsed_min >= UPDATE_INTERVAL_MIN ))
}

# Human-readable age of the last update (e.g. "hace 12 min", "hace 2 h").
last_update_label() {
    [[ -f "$LAST_UPDATE_FILE" ]] || { printf 'nunca'; return; }
    local last_ts now_ts diff_s diff_m diff_h
    last_ts=$(cat "$LAST_UPDATE_FILE" 2>/dev/null || echo 0)
    now_ts=$(date +%s)
    diff_s=$(( now_ts - last_ts ))
    diff_m=$(( diff_s / 60 ))
    diff_h=$(( diff_m / 60 ))

    if   (( diff_m == 0 ));  then printf 'ahora mismo'
    elif (( diff_h == 0 ));  then printf 'hace %d min'  "$diff_m"
    elif (( diff_h < 24 ));  then printf 'hace %d h'    "$diff_h"
    else                          printf 'hace %d días'  "$((diff_h/24))"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# § 4  UI LAYER
# ─────────────────────────────────────────────────────────────────────────────

# Build the rofi-blocks "lines" JSON array for the FEED view.
# Always prepends a ⚙ Settings entry so the user can reach configuration.
# Downloads missing thumbnails in parallel (curl, fire-and-forget style).
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
                'title':    parts[1][:60],
                'channel':  parts[2][:34],
                'date':     parts[3],
                'duration': parts[4] if len(parts) > 4 else '?',
            })
except (FileNotFoundError, OSError):
    pass

# ── Parallel thumbnail downloads (only for missing files) ─────────────────────
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

threads = [threading.Thread(target=download_thumb, args=(r['vid_id'],))
           for r in rows]
for t in threads: t.start()
for t in threads: t.join()

# ── Build JSON entries ─────────────────────────────────────────────────────────
result = []

# Settings gear — always first
result.append(json.dumps({
    "text": (
        "<span color='#89dceb'>⚙  Ajustes</span>\n"
        "<span color='#585b70'>Reproducción · Feed · Última actualización</span>"
    ),
    "markup": True,
    "data": "__cfg__"
}, ensure_ascii=False))

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
# Passes all relevant settings as argv so it works correctly from the
# background subshell (which cannot share bash globals with the main process).
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

play_mode   = sys.argv[1]
resolution  = sys.argv[2]
subtitles   = sys.argv[3]
last_label  = sys.argv[4]
intv_label  = sys.argv[5]
interval    = sys.argv[6]
max_vids    = sys.argv[7]
date_from   = sys.argv[8]
date_to     = sys.argv[9]

entries = []

# ── Back ───────────────────────────────────────────────────────────────────────
entries.append({
    "text": "<span color='#f38ba8' size='large'>  ←  Volver al Feed</span>",
    "markup": True,
    "data": "__back__"
})

# ── Force refresh ──────────────────────────────────────────────────────────────
entries.append({
    "text": (
        "<span color='#6c7086'>ACTUALIZACIÓN</span>\n"
        f"<span color='#fab387' size='large'>🔄  Forzar actualización ahora</span>\n"
        f"<span color='#585b70'>Última: {last_label}  ·  Intervalo: {intv_label}</span>"
    ),
    "markup": True,
    "data": "__force_update__"
})

# ── Update interval selector ───────────────────────────────────────────────────
entries.append({
    "text": "<span color='#6c7086'>INTERVALO DE ACTUALIZACIÓN</span>",
    "markup": True,
    "data": "__noop__"
})

for val, label in [("0","Siempre"),("5","5 min"),("10","10 min"),
                   ("15","15 min"),("30","30 min"),("60","1 h"),("180","3 h")]:
    active = (val == interval)
    color  = "#a6e3a1" if active else "#585b70"
    check  = "  ✓" if active else ""
    prefix = "▶  " if active else "   "
    entries.append({
        "text": f"<span color='{color}' size='large'>{prefix}{label}{check}</span>",
        "markup": True,
        "data": f"__intv_{val}__"
    })

# ── Playback section ───────────────────────────────────────────────────────────
entries.append({
    "text": "<span color='#6c7086'>MODO DE REPRODUCCIÓN</span>",
    "markup": True,
    "data": "__noop__"
})

mode_label = "🎵  Audio Only" if play_mode == "audio" else "🎬  Video + Audio"
mode_hint  = ("Pulsa para cambiar a  🎬 Video + Audio"
              if play_mode == "audio"
              else "Pulsa para cambiar a  🎵 Audio Only")
mode_color = "#cba6f7" if play_mode == "audio" else "#89dceb"

entries.append({
    "text": (
        f"<span color='{mode_color}' size='large'>{mode_label}</span>\n"
        f"<span color='#585b70'>{mode_hint}</span>"
    ),
    "markup": True,
    "data": "__toggle_mode__"
})

# ── Resolution selector ────────────────────────────────────────────────────────
entries.append({
    "text": "<span color='#6c7086'>RESOLUCIÓN MÁXIMA</span>",
    "markup": True,
    "data": "__noop__"
})

for res in ["360", "480", "720", "1080"]:
    active = (res == resolution)
    color  = "#a6e3a1" if active else "#585b70"
    check  = "  ✓" if active else ""
    prefix = "▶  " if active else "   "
    entries.append({
        "text": f"<span color='{color}' size='large'>{prefix}{res}p{check}</span>",
        "markup": True,
        "data": f"__res_{res}__"
    })

# ── Subtitles ──────────────────────────────────────────────────────────────────
sub_label = "💬  Subtítulos: ON"  if subtitles == "true" else "💬  Subtítulos: OFF"
sub_hint  = "Pulsa para desactivar" if subtitles == "true" else "Pulsa para activar"
sub_color = "#a6e3a1" if subtitles == "true" else "#585b70"

entries.append({
    "text": (
        "<span color='#6c7086'>SUBTÍTULOS</span>\n"
        f"<span color='{sub_color}' size='large'>{sub_label}</span>\n"
        f"<span color='#585b70'>{sub_hint}</span>"
    ),
    "markup": True,
    "data": "__toggle_subs__"
})

# ── Cache info ─────────────────────────────────────────────────────────────────
cap_label = f"{max_vids} por canal" if max_vids != "0" else "sin límite"
df_label  = date_from if date_from else "—"
dt_label  = date_to   if date_to   else "—"

entries.append({
    "text": (
        "<span color='#6c7086'>CACHÉ  /  FILTRO DE FECHAS</span>\n"
        f"<span color='#a6adc8'>Máx {cap_label}  ·  Desde {df_label}  →  {dt_label}</span>\n"
        f"<span color='#585b70'>Edita ~/.config/rofeed/config para cambiar</span>"
    ),
    "markup": True,
    "data": "__noop__"
})

print(','.join(json.dumps(e, ensure_ascii=False) for e in entries))
PYEOF
}

# Minimal JSON string escaping for values embedded in printf-built JSON.
json_str() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Emit a FEED view update to rofi (one JSON line → stdout).
emit_feed() {
    local message="$1" lines_json="$2"
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
    local last_label intv_label
    last_label=$(json_str "$(last_update_label)")
    intv_label=$(json_str "${UPDATE_INTERVAL_MIN} min")
    printf '{"prompt":"⚙  Ajustes","message":"Última actualización: %s  ·  Intervalo: %s  ·  ← para volver","event format":"{{data}}","lines":[%s]}\n' \
        "$last_label" "$intv_label" "$lines_json"
}

# Emit a feed update ONLY when the user is on the feed view.
# Called from the background crawler subshell — reads VIEWMODE_FILE (disk)
# instead of bash globals.
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

launch_mpv() {
    local vid_id="$1"
    local url="https://www.youtube.com/watch?v=${vid_id}"

    # Always reload — the user may have changed settings this session.
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
    [[ "$PLAY_MODE" == "audio" ]] \
        && mode_label="🎵 Audio Only" \
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
# Event dispatch table:
#   __cfg__           → switch to settings view
#   __back__          → switch back to feed view
#   __force_update__  → trigger an immediate crawl in the background
#   __toggle_mode__   → cycle PLAY_MODE: video ↔ audio
#   __res_NNN__       → set RESOLUTION to NNN
#   __intv_NNN__      → set UPDATE_INTERVAL_MIN to NNN (writes to config)
#   __toggle_subs__   → toggle SUBTITLES
#   __noop__          → intentional no-op (separator rows)
#   [A-Za-z0-9_-]{11} → YouTube video ID → launch mpv
# ─────────────────────────────────────────────────────────────────────────────

# Update UPDATE_INTERVAL_MIN in the config file (or append if missing).
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

handle_event() {
    local event="$1"

    case "$event" in

        __cfg__)
            printf 'settings' > "$VIEWMODE_FILE"
            emit_settings
            ;;

        __back__)
            printf 'feed' > "$VIEWMODE_FILE"
            local lines_json total_vids
            lines_json=$(build_feed_json "${CACHE_FILE:-/dev/null}")
            if [[ -f "$CACHE_FILE" && -s "$CACHE_FILE" ]]; then
                total_vids=$(wc -l < "$CACHE_FILE")
                local lbl
                lbl=$(last_update_label)
                emit_feed "📦 ${total_vids} vídeos  ·  ${lbl}" "$lines_json"
            else
                emit_feed "⏳ Sin caché — actualizando..." "$lines_json"
            fi
            ;;

        __force_update__)
            # Invalidate the last-update timestamp so cache_is_stale() returns
            # true, then kick off a background crawl.
            rm -f "$LAST_UPDATE_FILE"
            emit_settings
            if [[ -z "${CRAWLER_PID:-}" ]] || ! kill -0 "$CRAWLER_PID" 2>/dev/null; then
                (run_crawler) &
                CRAWLER_PID=$!
            fi
            ;;

        __toggle_mode__)
            [[ "$PLAY_MODE" == "video" ]] && PLAY_MODE="audio" || PLAY_MODE="video"
            save_settings
            emit_settings
            ;;

        __res_*__)
            local res="${event#__res_}"
            res="${res%__}"
            if [[ "$res" =~ ^(360|480|720|1080)$ ]]; then
                RESOLUTION="$res"
                save_settings
            fi
            emit_settings
            ;;

        __intv_*__)
            local intv="${event#__intv_}"
            intv="${intv%__}"
            if [[ "$intv" =~ ^(0|5|10|15|30|60|180)$ ]]; then
                save_interval "$intv"
            fi
            emit_settings
            ;;

        __toggle_subs__)
            [[ "$SUBTITLES" == "true" ]] && SUBTITLES="false" || SUBTITLES="true"
            save_settings
            emit_settings
            ;;

        __noop__)
            emit_settings
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
# § 7  MAIN
# ─────────────────────────────────────────────────────────────────────────────

cleanup() {
    [[ -n "${CRAWLER_PID:-}" ]] && kill "$CRAWLER_PID" 2>/dev/null || true
    wait "${CRAWLER_PID:-}" 2>/dev/null || true
    rm -f "$VIEWMODE_FILE"
}

main() {
    mkdir -p "$CACHE_DIR" "$CACHE_IDS" "$CACHE_THUMBS" "$CONFIG_DIR"
    write_default_config
    load_settings
    printf 'feed' > "$VIEWMODE_FILE"
    trap cleanup EXIT INT TERM

    # ── Phase 1: immediate display from existing cache ────────────────────────
    local lines_json
    if [[ -f "$CACHE_FILE" && -s "$CACHE_FILE" ]]; then
        local total_vids lbl
        total_vids=$(wc -l < "$CACHE_FILE")
        lbl=$(last_update_label)
        lines_json=$(build_feed_json "$CACHE_FILE")
        emit_feed "📦 ${total_vids} vídeos  ·  ${lbl}" "$lines_json"
    else
        lines_json=$(build_feed_json /dev/null)
        emit_feed "⏳ Cargando feed por primera vez..." "$lines_json"
    fi

    # ── Phase 2: conditional background crawl ─────────────────────────────────
    # Only runs if the cache is stale or missing.  The user can force a refresh
    # via __force_update__ from the settings view.
    CRAWLER_PID=""
    if cache_is_stale; then
        (run_crawler) &
        CRAWLER_PID=$!
    fi

    # ── Phase 3: event loop ───────────────────────────────────────────────────
    run_event_loop
}

# ── Entry points ───────────────────────────────────────────────────────────────
case "${1:-}" in
    --crawl-only)
        # Headless mode for cron/systemd — stdout silenced, only TSV updated.
        mkdir -p "$CACHE_DIR" "$CACHE_IDS" "$CACHE_THUMBS" "$CONFIG_DIR"
        write_default_config
        load_settings
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
