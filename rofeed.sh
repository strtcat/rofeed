#!/bin/bash

SUBS="$HOME/.config/rofeed/subscriptions"
CACHE_IDS="$HOME/.cache/rofeed-channel-ids"
CACHE_THUMBS="$HOME/.cache/rofeed-thumbs"
CACHE_FEED="$HOME/.cache/rofeed-feed"
CACHE_FILE="$CACHE_FEED/videos.tsv"

mkdir -p "$CACHE_IDS" "$CACHE_THUMBS" "$CACHE_FEED"

WRAPPER=$(mktemp /tmp/rofeed-wrap-XXXX.sh)

cat > "$WRAPPER" << EOF
#!/bin/bash
SUBS="$SUBS"
CACHE_IDS="$CACHE_IDS"
CACHE_THUMBS="$CACHE_THUMBS"
CACHE_FILE="$CACHE_FILE"
EOF

cat >> "$WRAPPER" << 'EOF'

build_lines_json() {
    local tsv_file="$1"
    python3 - "$tsv_file" "$CACHE_THUMBS" << 'PYEOF'
import sys, json, os, subprocess, threading

tsv_file  = sys.argv[1]
thumb_dir = sys.argv[2]

lines = []
with open(tsv_file) as f:
    for raw in f:
        parts = raw.rstrip('\n').split('\t')
        if len(parts) < 4:
            continue
        vid_id   = parts[0]
        title    = parts[1][:55]
        channel  = parts[2][:30]
        date     = parts[3]
        duration = parts[4] if len(parts) > 4 else '?'
        lines.append((vid_id, title, channel, date, duration))

def download_thumb(vid_id):
    path = os.path.join(thumb_dir, f'{vid_id}.jpg')
    if not os.path.exists(path):
        url = f'https://i.ytimg.com/vi/{vid_id}/mqdefault.jpg'
        try:
            subprocess.run(['curl', '-s', url, '-o', path],
                           timeout=10, capture_output=True)
        except Exception:
            pass

threads = [threading.Thread(target=download_thumb, args=(v,)) for v,*_ in lines]
for t in threads: t.start()
for t in threads: t.join()

result = []
for vid_id, title, channel, date, duration in lines:
    thumb = os.path.join(thumb_dir, f'{vid_id}.jpg')
    if not os.path.exists(thumb):
        thumb = ''
    text = (
        f"<span color='#89dceb'>{date}</span>"
        f"  <span color='#a6e3a1'>{duration}</span>\n"
        f"<span color='#cdd6f4'>{title}</span>\n"
        f"<span color='#6c7086'>— {channel}</span>"
    )
    entry = {"text": text, "markup": True, "data": vid_id}
    if thumb:
        entry["icon"] = thumb
    result.append(json.dumps(entry, ensure_ascii=False))

print(','.join(result))
PYEOF
}

emit() {
    local message="$1" lines_json="$2"
    # event format simplificado: solo devuelve el data directamente
    printf '{"prompt":"🎬 Mi Feed", "message":"%s", "event format":"{{data}}", "lines":[%s]}\n' \
        "$message" "$lines_json"
}

merge_tsv() {
    cat "$1" "$2" 2>/dev/null \
        | awk -F'\t' '!seen[$1]++' \
        | sort -t$'\t' -k4 -r
}

resolve_id() {
    local url="$1"
    local cachefile="$CACHE_IDS/$(echo "$url" | md5sum | cut -d' ' -f1)"
    if [ -f "$cachefile" ]; then cat "$cachefile"; return; fi
    local id
    id=$(curl -s "$url" \
        | grep -o '"externalId":"[^"]*"' \
        | head -1 | cut -d'"' -f4)
    if [ -n "$id" ]; then
        echo "$id" > "$cachefile"
        echo "$id"
    fi
}

fetch_rss() {
    local channel_id="$1"
    curl -s "https://www.youtube.com/feeds/videos.xml?channel_id=${channel_id}" | \
    python3 -c "
import sys, xml.etree.ElementTree as ET
ns = {'atom':'http://www.w3.org/2005/Atom',
      'yt':'http://www.youtube.com/xml/schemas/2015'}
try:
    root = ET.parse(sys.stdin).getroot()
    ch   = root.find('atom:author/atom:name', ns)
    ch_name = ch.text if ch is not None else ''
    for e in root.findall('atom:entry', ns):
        vid  = e.find('yt:videoId', ns).text
        titl = e.find('atom:title', ns).text
        pub  = e.find('atom:published', ns).text[:16].replace('T',' ')
        print(f'{vid}\t{titl}\t{ch_name}\t{pub}')
except: sys.exit(1)
" 2>/dev/null
}

fetch_durations() {
    local url="$1"
    nice -n 19 yt-dlp --flat-playlist --playlist-end 15 --print-json \
        "${url}/videos" 2>/dev/null | \
    jq -r '[.id, (.duration | if . != null then (. | floor |
        if . >= 3600
        then ((. / 3600 | floor | tostring) + "h "
            + (. % 3600 / 60 | floor | tostring) + "m "
            + (. % 60 | tostring) + "s")
        elif . >= 60
        then ((. / 60 | floor | tostring) + "m "
            + (. % 60 | tostring) + "s")
        else ((. | tostring) + "s")
        end) else "?" end)] | join("\t")' 2>/dev/null
}

# ── Fase 1: cache inmediata ───────────────────────────────────────────────────
if [ -f "$CACHE_FILE" ] && [ -s "$CACHE_FILE" ]; then
    lines_json=$(build_lines_json "$CACHE_FILE")
    emit "📦 Cache — actualizando en background..." "$lines_json"
else
    emit "⏳ Cargando feed por primera vez..." ""
fi

# ── Encapsulamos las Fases 2 y 3 en segundo plano ─────────────────────────────
(
# ── Fase 2: actualizar canal por canal ───────────────────────────────────────
TOTAL=$(grep -cve '^\s*#' -e '^\s*$' "$SUBS" 2>/dev/null || echo 0)
COUNT=0
TMPNEW=$(mktemp /tmp/rofeed-new-XXXX.tsv)

while IFS= read -r url; do
    [[ -z "$url" || "$url" == \#* ]] && continue
    COUNT=$((COUNT + 1))

    if echo "$url" | grep -q '/channel/UC'; then
        channel_id=$(echo "$url" | grep -o 'UC[^/]*' | head -1)
    else
        channel_id=$(resolve_id "$url")
    fi
    [ -z "$channel_id" ] && continue

    RSSFILE=$(mktemp /tmp/rofeed-rss-XXXX)
    DURFILE=$(mktemp /tmp/rofeed-dur-XXXX)
    fetch_rss "$channel_id" > "$RSSFILE" &
    fetch_durations "$url"  > "$DURFILE" &
    wait

    while IFS=$'\t' read -r vid_id title channel_name published; do
        [ -z "$vid_id" ] && continue
        duration=$(grep "^${vid_id}"$'\t' "$DURFILE" | cut -f2)
        [ -z "$duration" ] && duration="?"
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$vid_id" "$title" "$channel_name" "$published" "$duration" \
            >> "$TMPNEW"
    done < "$RSSFILE"
    rm -f "$RSSFILE" "$DURFILE"

    TMPMERGE=$(mktemp /tmp/rofeed-merge-XXXX.tsv)
    merge_tsv "$TMPNEW" "$CACHE_FILE" > "$TMPMERGE"
    total_vids=$(wc -l < "$TMPMERGE")
    lines_json=$(build_lines_json "$TMPMERGE")
    emit "🔄 Canal ${COUNT}/${TOTAL} — ${total_vids} vídeos..." "$lines_json"
    rm -f "$TMPMERGE"

done < "$SUBS"

# ── Fase 3: guardar cache final ───────────────────────────────────────────────
TMPFINAL=$(mktemp /tmp/rofeed-final-XXXX.tsv)
merge_tsv "$TMPNEW" "$CACHE_FILE" > "$TMPFINAL"
mv "$TMPFINAL" "$CACHE_FILE"
rm -f "$TMPNEW"

total_vids=$(wc -l < "$CACHE_FILE")
lines_json=$(build_lines_json "$CACHE_FILE")
emit "✅ Listo — ${total_vids} vídeos" "$lines_json"
) &
# ──────────────────────────────────────────────────────────────────────────────

# ── Fase 4: eventos — con event format "{{data}}" rofi manda solo el vid_id ──
while IFS= read -r vid_id; do
    # Ignorar eventos que no son video IDs (11 caracteres alfanuméricos)
    if echo "$vid_id" | grep -qE '^[A-Za-z0-9_-]{11}$'; then
        # Lanzamos mpv con nohup para que no muera al cerrarse rofi
        notify-send -a "Mi Feed" "🎬 Cargando vídeo..." "Resolviendo enlace en mpv" -t 3000

        # 2. Lanzamos mpv forzando a que la ventana se abra AL INSTANTE
        # mpv --force-window=immediate "https://www.youtube.com/watch?v=${vid_id}" 1>&2 &
        nohup mpv --force-window=immediate "https://www.youtube.com/watch?v=${vid_id}" >/dev/null 2>&1 &
    fi
done

EOF

chmod +x "$WRAPPER"

rofi -modi blocks -show blocks \
    -blocks-wrap "$WRAPPER" \
    -theme "$HOME/.config/rofi/rofeed.rasi" \
    -markup-rows

rm -f "$WRAPPER"
