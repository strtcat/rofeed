#!/usr/bin/env bash
# =============================================================================
# rofeed-worker.sh — Mi Feed · Background Crawler
# Version: 0.6.0
# =============================================================================
#
# PURPOSE
#   Pure data worker.  No rofi-blocks protocol, no stdout UI output, no mpv.
#   Fetches YouTube RSS feeds, resolves durations, downloads thumbnails, and
#   writes / merges the local TSV cache.  Communicates with the UI exclusively
#   through filesystem files:
#
#     CRAWLER_STATUS_FILE   one-line status string (read by rofeed.sh)
#     CACHE_FILE            videos.tsv             (read by rofeed.sh)
#     LAST_UPDATE_FILE      unix timestamp          (read by rofeed.sh)
#
# CRAWLER STATUS PROTOCOL
#   idle           — no crawl running / not started yet
#   running:N:T    — processing channel N of T
#   done:TOTAL     — finished successfully, TOTAL lines in cache
#   error:MSG      — crawl aborted with error message MSG
#
# USAGE
#   rofeed-worker.sh [--crawl-only | --version | --help]
#
#   --crawl-only   Headless crawl (called by systemd timer or rofeed.sh).
#                  All stdout is suppressed; status goes to CRAWLER_STATUS_FILE.
#   --version      Print version string and exit.
#   --help         Print this help and exit.
#
# FILE LAYOUT
#   § 1  PATHS & CONSTANTS
#   § 2  SETTINGS          (read from config + persisted settings)
#   § 3  STATUS HELPERS    (read/write CRAWLER_STATUS_FILE)
#   § 4  DATA LAYER        (RSS, duration, thumbnail, cache)
#   § 5  MAIN / ENTRY
# =============================================================================

set -uo pipefail
# NOTE: intentionally NOT using set -e here.  Several sub-commands (curl,
# yt-dlp) are expected to fail occasionally (rate limits, network) and we
# want to continue rather than abort the whole crawl.  Individual error
# paths are handled explicitly.

# ─────────────────────────────────────────────────────────────────────────────
# § 1  PATHS & CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────

readonly ROFEED_WORKER_VERSION="0.6.0"

readonly CONFIG_DIR="${HOME}/.config/rofeed"
readonly SUBS="${CONFIG_DIR}/subscriptions"
readonly CONFIG_FILE="${CONFIG_DIR}/config"

readonly CACHE_DIR="${HOME}/.cache/rofeed-feed"
readonly CACHE_IDS="${HOME}/.cache/rofeed-channel-ids"
readonly CACHE_THUMBS="${HOME}/.cache/rofeed-thumbs"
readonly CACHE_FILE="${CACHE_DIR}/videos.tsv"
readonly SETTINGS_FILE="${CACHE_DIR}/settings"
readonly LAST_UPDATE_FILE="${CACHE_DIR}/.last_update"
readonly CRAWLER_STATUS_FILE="${CACHE_DIR}/.crawler_status"
readonly CRAWL_LOCK="${CACHE_DIR}/.crawl.lock"
readonly CRAWL_LOG="${CACHE_DIR}/.crawl.log"

# ─────────────────────────────────────────────────────────────────────────────
# § 2  SETTINGS
# ─────────────────────────────────────────────────────────────────────────────

MAX_VIDEOS_PER_CHANNEL="30"
DATE_FROM=""
DATE_TO=""

load_settings() {
    local f key val
    for f in "$CONFIG_FILE" "$SETTINGS_FILE"; do
        [[ -f "$f" ]] || continue
        while IFS='=' read -r key val; do
            # Skip comment lines and blank keys
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${key// /}" ]]           && continue
            # Trim whitespace
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"
            # Strip surrounding quotes
            val="${val%\"}" ; val="${val#\"}"
            val="${val%\'}" ; val="${val#\'}"
            case "$key" in
                MAX_VIDEOS_PER_CHANNEL)
                    [[ "$val" =~ ^[0-9]+$ ]] && MAX_VIDEOS_PER_CHANNEL="$val" ;;
                DATE_FROM)
                    [[ "$val" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})?$ ]] && DATE_FROM="$val" ;;
                DATE_TO)
                    [[ "$val" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})?$ ]] && DATE_TO="$val"   ;;
            esac
        done < "$f"
    done
}

write_default_config() {
    [[ -f "$CONFIG_FILE" ]] && return 0
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << 'EOF'
# rofeed configuration — ~/.config/rofeed/config
# Changes take effect on the next crawl run.

# Maximum number of videos to keep per channel. 0 = unlimited.
MAX_VIDEOS_PER_CHANNEL="30"

# Show only videos whose publication date falls within this range.
# Leave blank to disable. Format: YYYY-MM-DD
DATE_FROM=""
DATE_TO=""
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# § 3  STATUS HELPERS
# ─────────────────────────────────────────────────────────────────────────────

status_write() {
    # Write atomically via a temp file so the UI never reads a partial line.
    local tmp
    tmp=$(mktemp "${CACHE_DIR}/.status_tmp_XXXX") || return 1
    printf '%s' "$1" > "$tmp"
    mv "$tmp" "$CRAWLER_STATUS_FILE"
}

log_msg() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$CRAWL_LOG"
}

# ─────────────────────────────────────────────────────────────────────────────
# § 4  DATA LAYER
# ─────────────────────────────────────────────────────────────────────────────

# ── Cache helpers ─────────────────────────────────────────────────────────────

# Ensure the TSV cache file exists (even if empty) so all readers can open it.
ensure_cache_file() {
    if [[ ! -f "$CACHE_FILE" ]]; then
        touch "$CACHE_FILE"
        log_msg "Created empty cache file: $CACHE_FILE"
    fi
}

# Read current video IDs from cache → one ID per line.
# Returns nothing (empty output) when cache is absent or empty.
cached_video_ids() {
    [[ -f "$CACHE_FILE" && -s "$CACHE_FILE" ]] || return 0
    cut -f1 "$CACHE_FILE"
}

# Merge two TSV files, deduplicate on column 1, sort newest-first on column 4.
# Gracefully handles missing files — a missing file is treated as empty.
merge_tsv() {
    local file_a="$1" file_b="$2"
    {
        [[ -f "$file_a" && -s "$file_a" ]] && cat "$file_a"
        [[ -f "$file_b" && -s "$file_b" ]] && cat "$file_b"
    } | awk -F'\t' '!seen[$1]++' \
      | sort -t$'\t' -k4 -r
}

# Keep at most MAX_VIDEOS_PER_CHANNEL entries per channel.
trim_cache() {
    local tsv_file="$1"
    [[ ! -f "$tsv_file" ]] && return 0
    [[ "$MAX_VIDEOS_PER_CHANNEL" == "0" ]] && return 0
    python3 - "$tsv_file" "$MAX_VIDEOS_PER_CHANNEL" << 'PYEOF'
import sys
path, cap = sys.argv[1], int(sys.argv[2])
counts, kept = {}, []
try:
    with open(path) as fh:
        for line in fh:
            parts = line.split('\t')
            if len(parts) < 3:
                continue
            ch = parts[2]
            counts[ch] = counts.get(ch, 0) + 1
            if counts[ch] <= cap:
                kept.append(line)
except FileNotFoundError:
    pass
with open(path, 'w') as fh:
    fh.writelines(kept)
PYEOF
}

# Filter rows outside the configured date range.
apply_date_filter() {
    local tsv_file="$1"
    [[ ! -f "$tsv_file" ]]                     && return 0
    [[ -z "$DATE_FROM" && -z "$DATE_TO" ]]     && return 0
    python3 - "$tsv_file" "${DATE_FROM:-}" "${DATE_TO:-}" << 'PYEOF'
import sys
path, d_from, d_to = sys.argv[1], sys.argv[2], sys.argv[3]
kept = []
try:
    with open(path) as fh:
        for line in fh:
            parts = line.split('\t')
            if len(parts) < 4:
                kept.append(line); continue
            date_col = parts[3][:10]
            if d_from and date_col < d_from: continue
            if d_to   and date_col > d_to:   continue
            kept.append(line)
except FileNotFoundError:
    pass
with open(path, 'w') as fh:
    fh.writelines(kept)
PYEOF
}

# ── Network helpers ───────────────────────────────────────────────────────────

# Resolve a channel @handle or /c/ URL to a UCxxx channel ID.
# Result is cached in CACHE_IDS by URL hash to avoid repeated HTTP requests.
resolve_channel_id() {
    local url="$1"
    local hash cachefile
    hash=$(printf '%s' "$url" | md5sum | cut -d' ' -f1)
    cachefile="${CACHE_IDS}/${hash}"

    if [[ -f "$cachefile" && -s "$cachefile" ]]; then
        cat "$cachefile"
        return 0
    fi

    log_msg "Resolving channel ID for: $url"
    local id
    id=$(curl -s --max-time 15 "$url" \
        | grep -o '"externalId":"[^"]*"' \
        | head -1 | cut -d'"' -f4)

    if [[ -n "$id" ]]; then
        printf '%s' "$id" > "$cachefile"
        printf '%s' "$id"
        log_msg "  → resolved to: $id"
    else
        log_msg "  → FAILED to resolve channel ID (URL: $url)"
    fi
}

# Fetch YouTube RSS feed for a channel ID.
# Outputs TSV lines: vid_id \t title \t channel_name \t published_date
fetch_rss() {
    local channel_id="$1"
    local rss_url="https://www.youtube.com/feeds/videos.xml?channel_id=${channel_id}"
    log_msg "  Fetching RSS: $rss_url"

    curl -s --max-time 20 "$rss_url" \
    | python3 -c "
import sys, xml.etree.ElementTree as ET
ns = {
    'atom': 'http://www.w3.org/2005/Atom',
    'yt':   'http://www.youtube.com/xml/schemas/2015',
}
try:
    root    = ET.parse(sys.stdin).getroot()
    ch_node = root.find('atom:author/atom:name', ns)
    ch_name = ch_node.text.strip() if ch_node is not None else 'Unknown'
    for entry in root.findall('atom:entry', ns):
        vid_node  = entry.find('yt:videoId', ns)
        titl_node = entry.find('atom:title', ns)
        pub_node  = entry.find('atom:published', ns)
        if vid_node is None or pub_node is None:
            continue
        vid  = vid_node.text.strip()
        titl = (titl_node.text or '').replace('\t', ' ').strip() if titl_node is not None else ''
        pub  = pub_node.text[:16].replace('T', ' ')
        if vid:
            print(f'{vid}\t{titl}\t{ch_name}\t{pub}')
except Exception as exc:
    import traceback
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)
" 2>>"$CRAWL_LOG"
}

# Fetch the duration of a single video via yt-dlp.
# Returns a human-readable string like "12m 34s" or "?" on failure.
fetch_duration_single() {
    local vid_id="$1"
    local raw
    raw=$(nice -n 19 yt-dlp \
        --no-playlist \
        --skip-download \
        --print "%(duration)s" \
        -- "https://www.youtube.com/watch?v=${vid_id}" 2>/dev/null) || true

    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        local secs=$(( raw ))
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

# Download thumbnails for a list of video IDs (parallel, skips existing).
download_thumbnails() {
    local ids_file="$1"   # path to file containing one vid_id per line

    [[ ! -f "$ids_file" || ! -s "$ids_file" ]] && return 0

    python3 - "$ids_file" "$CACHE_THUMBS" "$CRAWL_LOG" << 'PYEOF'
import sys, os, subprocess, threading

ids_file, thumb_dir, log_file = sys.argv[1], sys.argv[2], sys.argv[3]

def log(msg):
    try:
        with open(log_file, 'a') as lf:
            lf.write(msg + '\n')
    except OSError:
        pass

def download_thumb(vid_id):
    path = os.path.join(thumb_dir, f'{vid_id}.jpg')
    if os.path.exists(path):
        return
    url = f'https://i.ytimg.com/vi/{vid_id}/mqdefault.jpg'
    try:
        result = subprocess.run(
            ['curl', '-s', '--max-time', '10', url, '-o', path],
            timeout=12, capture_output=True
        )
        if result.returncode != 0:
            log(f'  Thumb download failed for {vid_id}: curl exit {result.returncode}')
    except Exception as exc:
        log(f'  Thumb download exception for {vid_id}: {exc}')

try:
    with open(ids_file) as f:
        ids = [l.strip() for l in f if l.strip()]
except FileNotFoundError:
    ids = []

threads = [threading.Thread(target=download_thumb, args=(vid_id,)) for vid_id in ids]
for t in threads: t.start()
for t in threads: t.join()
log(f'  Downloaded/verified thumbnails for {len(ids)} video(s).')
PYEOF
}

# ── Main crawl ────────────────────────────────────────────────────────────────

run_crawler() {
    # ── Lock: only one crawler at a time ─────────────────────────────────────
    exec 9>"$CRAWL_LOCK"
    if ! flock -n 9; then
        log_msg "run_crawler: another instance already running (lock held). Exiting."
        return 0
    fi

    log_msg "========== Crawl started =========="

    # ── Guard: subscriptions file must exist and be non-empty ────────────────
    if [[ ! -f "$SUBS" ]]; then
        log_msg "No subscriptions file found at: $SUBS — nothing to do."
        status_write 'idle'
        flock -u 9; return 0
    fi

    local total
    total=$(grep -cvE '^\s*(#|$)' "$SUBS" 2>/dev/null || true)
    total="${total:-0}"
    if [[ "$total" -eq 0 ]]; then
        log_msg "Subscriptions file is empty or all lines are comments."
        status_write 'idle'
        flock -u 9; return 0
    fi

    # ── Ensure cache file exists so readers never get ENOENT ─────────────────
    ensure_cache_file

    # ── Build the set of already-cached video IDs ─────────────────────────────
    # On a fresh install this file will be empty — that is correct and intentional.
    # The diff logic treats an empty cached set as "everything is new".
    local cached_ids_file
    cached_ids_file=$(mktemp /tmp/rofeed-cachedids-XXXX)
    cached_video_ids > "$cached_ids_file"
    local cached_count
    cached_count=$(wc -l < "$cached_ids_file" | tr -d ' ')
    log_msg "Starting incremental crawl. Cached IDs: $cached_count  |  Channels: $total"

    # ── Accumulate new rows here; committed atomically at the end ─────────────
    local tmpnew
    tmpnew=$(mktemp /tmp/rofeed-new-XXXX.tsv)

    # ── All new video IDs collected across all channels (for thumb download) ──
    local all_new_ids_file
    all_new_ids_file=$(mktemp /tmp/rofeed-allnewids-XXXX)

    local count=0

    while IFS= read -r url; do
        # Skip blank lines and comments
        [[ -z "$url" || "$url" =~ ^[[:space:]]*# ]] && continue
        count=$(( count + 1 ))

        status_write "running:${count}:${total}"
        log_msg "Channel $count/$total: $url"

        # ── Resolve channel ID ────────────────────────────────────────────────
        local channel_id=""
        if printf '%s' "$url" | grep -q '/channel/UC'; then
            # Direct /channel/UCxxx URL — extract inline without HTTP request
            channel_id=$(printf '%s' "$url" | grep -oE 'UC[A-Za-z0-9_-]{22}' | head -1)
        else
            channel_id=$(resolve_channel_id "$url")
        fi

        if [[ -z "$channel_id" ]]; then
            log_msg "  Could not resolve channel ID — skipping."
            continue
        fi

        # ── Fetch RSS feed ────────────────────────────────────────────────────
        local rssfile
        rssfile=$(mktemp /tmp/rofeed-rss-XXXX)
        fetch_rss "$channel_id" > "$rssfile"

        local rss_line_count
        rss_line_count=$(wc -l < "$rssfile" | tr -d ' ')
        log_msg "  RSS returned $rss_line_count entries."

        if [[ "$rss_line_count" -eq 0 ]]; then
            log_msg "  Empty RSS feed — skipping channel."
            rm -f "$rssfile"
            continue
        fi

        # ── Diff: determine which video IDs are new ───────────────────────────
        # This Python block is the core of the incremental logic.
        # On a fresh/empty cache, cached_ids_file is empty → cached = set() →
        # ALL videos from RSS are treated as new.  This is the correct behaviour.
        local new_ids_file
        new_ids_file=$(mktemp /tmp/rofeed-newids-XXXX)

        python3 - "$rssfile" "$cached_ids_file" "$new_ids_file" << 'PYEOF'
import sys

rss_path    = sys.argv[1]
cached_path = sys.argv[2]
out_path    = sys.argv[3]

# Load already-cached IDs.  FileNotFoundError or empty file → empty set.
cached = set()
try:
    with open(cached_path) as fh:
        for line in fh:
            vid = line.strip()
            if vid:
                cached.add(vid)
except FileNotFoundError:
    pass  # fresh install — treat everything as new

# Walk the RSS file and collect IDs not yet in cache.
new_ids = []
try:
    with open(rss_path) as fh:
        for line in fh:
            parts = line.split('\t')
            if not parts:
                continue
            vid = parts[0].strip()
            if vid and vid not in cached:
                new_ids.append(vid)
except FileNotFoundError:
    pass  # RSS fetch failed — nothing to add

with open(out_path, 'w') as fh:
    if new_ids:
        fh.write('\n'.join(new_ids) + '\n')
    # Deliberately write empty file (zero bytes) when nothing is new.
    # The shell checks `wc -l` which correctly returns 0 for an empty file.
PYEOF

        local new_count
        new_count=$(wc -l < "$new_ids_file" | tr -d ' ')
        log_msg "  New videos to fetch: $new_count"

        if [[ "$new_count" -eq 0 ]]; then
            log_msg "  No new videos for this channel."
            rm -f "$rssfile" "$new_ids_file"
            continue
        fi

        # Append new IDs to the global list for thumbnail batch download later
        cat "$new_ids_file" >> "$all_new_ids_file"

        # ── Fetch durations for new video IDs ─────────────────────────────────
        local durfile
        durfile=$(mktemp /tmp/rofeed-dur-XXXX)

        local vid_num=0
        while IFS= read -r vid_id; do
            [[ -z "$vid_id" ]] && continue
            vid_num=$(( vid_num + 1 ))
            log_msg "    Duration $vid_num/$new_count: $vid_id"
            local dur
            dur=$(fetch_duration_single "$vid_id")
            printf '%s\t%s\n' "$vid_id" "$dur" >> "$durfile"
            # Polite delay between yt-dlp calls to avoid rate-limiting
            sleep 0.4
        done < "$new_ids_file"

        # ── Join RSS data + durations → append to tmpnew ─────────────────────
        python3 - "$rssfile" "$new_ids_file" "$durfile" "$tmpnew" << 'PYEOF'
import sys

rss_path     = sys.argv[1]
new_ids_path = sys.argv[2]
dur_path     = sys.argv[3]
out_path     = sys.argv[4]

# IDs we want to include in this batch
new_ids = set()
try:
    with open(new_ids_path) as fh:
        for line in fh:
            vid = line.strip()
            if vid:
                new_ids.add(vid)
except FileNotFoundError:
    pass

# Duration lookup table (vid_id → human string)
durations = {}
try:
    with open(dur_path) as fh:
        for line in fh:
            parts = line.rstrip('\n').split('\t')
            if len(parts) == 2 and parts[0]:
                durations[parts[0]] = parts[1]
except FileNotFoundError:
    pass

# Build output rows preserving RSS order for this channel
rows = []
try:
    with open(rss_path) as fh:
        for line in fh:
            parts = line.rstrip('\n').split('\t')
            if len(parts) < 4:
                continue
            vid_id = parts[0].strip()
            if not vid_id or vid_id not in new_ids:
                continue
            title   = parts[1]
            channel = parts[2]
            date    = parts[3]
            dur     = durations.get(vid_id, '?')
            rows.append(f'{vid_id}\t{title}\t{channel}\t{date}\t{dur}\n')
except FileNotFoundError:
    pass

# Append to the accumulator file (created by mktemp, initially empty)
with open(out_path, 'a') as fh:
    fh.writelines(rows)
PYEOF

        rm -f "$rssfile" "$new_ids_file" "$durfile"

    done < "$SUBS"

    # ── Download thumbnails for ALL new videos in one parallel batch ──────────
    log_msg "Downloading thumbnails for new videos…"
    download_thumbnails "$all_new_ids_file"

    # ── Atomic commit ─────────────────────────────────────────────────────────
    # Merge new rows with existing cache, apply filters, cap per channel,
    # then atomically replace the cache file.
    local tmpfinal
    tmpfinal=$(mktemp /tmp/rofeed-final-XXXX.tsv)

    merge_tsv "$tmpnew" "$CACHE_FILE" > "$tmpfinal"
    apply_date_filter "$tmpfinal"
    trim_cache        "$tmpfinal"

    mv "$tmpfinal" "$CACHE_FILE"
    rm -f "$tmpnew" "$cached_ids_file" "$all_new_ids_file"

    # Record timestamp of successful update
    date +%s > "$LAST_UPDATE_FILE"

    local total_vids
    total_vids=$(wc -l < "$CACHE_FILE" | tr -d ' ')
    total_vids="${total_vids:-0}"

    status_write "done:${total_vids}"
    log_msg "Crawl finished. Total videos in cache: $total_vids"
    log_msg "========== Crawl done =========="

    flock -u 9
}

# ─────────────────────────────────────────────────────────────────────────────
# § 5  MAIN / ENTRY POINTS
# ─────────────────────────────────────────────────────────────────────────────

_setup_dirs() {
    mkdir -p "$CACHE_DIR" "$CACHE_IDS" "$CACHE_THUMBS" "$CONFIG_DIR"
    # Rotate log: keep only the last 500 lines to avoid unbounded growth
    if [[ -f "$CRAWL_LOG" ]]; then
        local lines
        lines=$(wc -l < "$CRAWL_LOG" | tr -d ' ')
        if (( lines > 500 )); then
            local tmp_log
            tmp_log=$(mktemp "${CACHE_DIR}/.log_tmp_XXXX")
            tail -400 "$CRAWL_LOG" > "$tmp_log" && mv "$tmp_log" "$CRAWL_LOG"
        fi
    fi
}

case "${1:-}" in

    --crawl-only)
        _setup_dirs
        write_default_config
        load_settings
        # Ensure status file exists before writing to it
        [[ -f "$CRAWLER_STATUS_FILE" ]] || status_write 'idle'
        # Suppress all stdout (the UI reads files, not our stdout)
        exec 1>/dev/null
        run_crawler
        exit 0
        ;;

    --version|-V)
        printf 'rofeed-worker %s\n' "$ROFEED_WORKER_VERSION"
        exit 0
        ;;

    --help|-h)
        cat << HELP
rofeed-worker ${ROFEED_WORKER_VERSION} — background crawler for rofeed

USAGE
  rofeed-worker.sh --crawl-only   Fetch new videos and update local cache
  rofeed-worker.sh --version      Print version
  rofeed-worker.sh --help         Show this help

FILES WRITTEN
  ${CACHE_FILE}
  ${LAST_UPDATE_FILE}
  ${CRAWLER_STATUS_FILE}
  ${CRAWL_LOG}
HELP
        exit 0
        ;;

    "")
        printf 'rofeed-worker.sh: no mode given. Use --crawl-only.\n' >&2
        printf 'Try: rofeed-worker.sh --help\n' >&2
        exit 1
        ;;

    *)
        printf 'rofeed-worker.sh: unknown option: %s\n' "$1" >&2
        printf 'Try: rofeed-worker.sh --help\n' >&2
        exit 1
        ;;

esac
