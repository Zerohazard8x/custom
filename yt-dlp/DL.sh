#!/usr/bin/env bash
#
# download.sh – combined multithreaded downloader with menu, 15 s timeout,
# and “Unlimited quality” as the new default.
#

set -euo pipefail

# 1. Sanity checks
if [ -z "${SHELL:-}" ]; then
  echo "Error: SHELL environment variable not set." >&2
  exit 1
fi

if ! command -v yt-dlp &>/dev/null; then
  echo "Error: yt-dlp is not installed." >&2
  exit 1
fi

# 2. Prepare URL list
if [ ! -f src_URLs.txt ]; then
  echo "src_URLs.txt not found—creating empty stub and exiting."
  touch src_URLs.txt
  exit 1
else
  # If it’s a playlist, expand it (requires jq)
  if grep -qi "playlist" src_URLs.txt && command -v jq &>/dev/null; then
    playlist_url=$(head -n1 src_URLs.txt)
    yt-dlp "$playlist_url" --flat-playlist -j --cookies-from-browser firefox | jq -r .url > src_URLs.txt \
      || yt-dlp "$playlist_url" --flat-playlist -j --cookies-from-browser chrome | jq -r .url > src_URLs.txt \
      || yt-dlp "$playlist_url" --flat-playlist -j | jq -r .url > src_URLs.txt
  fi
fi

# 3. Prompt menu (15 s timeout; default → 5)
cat <<EOF
Select download option (defaults to 5 → Unlimited quality) within 15 seconds:
  1) Audio only
  2) Video 480p
  3) Video 720p
  4) Video 1080p
  5) Unlimited quality
EOF
read -t 15 -rp $'Enter choice [1-5] (default 5): ' choice
choice=${choice:-5}

# 4. Build format-specific flags
common_opts="--add-header Accept-Language:'en-US,en;q=0.5' \
--add-metadata --embed-thumbnail --embed-subs \
--sponsorblock-mark all --sponsorblock-remove sponsor,selfpromo,music_offtopic --no-simulate --extractor-args \"generic:impersonate\""

case "$choice" in
  1)
    fmt_opts="--extract-audio"
    ;;
  2)
    fmt_opts="-f \"(bv[height<=480][vcodec~='^(av0?1|vp0?9|hevc|h265)']+ba[acodec^=opus]) / (bv[height<=480][vcodec~='^(av0?1|vp0?9|hevc|h265)']+ba) / (bv[height<=480]+ba[acodec^=opus]) / (bv+ba) / b\""
    ;;
  3)
    fmt_opts="-f \"(bv[height<=720][vcodec~='^(av0?1|vp0?9|hevc|h265)']+ba[acodec^=opus]) / (bv[height<=720][vcodec~='^(av0?1|vp0?9|hevc|h265)']+ba) / (bv[height<=720]+ba[acodec^=opus]) / (bv+ba) / b\""
    ;;
  4)
    fmt_opts="-f \"(bv[height<=1080][vcodec~='^(av0?1|vp0?9|hevc|h265)']+ba[acodec^=opus]) / (bv[height<=1080][vcodec~='^(av0?1|vp0?9|hevc|h265)']+ba) / (bv[height<=1080]+ba[acodec^=opus]) / (bv+ba) / b\""
    ;;
  5|*)
    [ "$choice" != 5 ] && echo "Invalid choice—defaulting to Unlimited quality."
    fmt_opts="-f \"(bv[vcodec~='^(av0?1|vp0?9|hevc|h265)']+ba[acodec^=opus]) \
/ (bv[vcodec~='^(av0?1|vp0?9|hevc|h265)']+ba) \
/ (bv+ba[acodec^=opus]) \
/ (bv+ba) \
/ b\""
    # show available formats before downloading
    common_opts="$common_opts --list-formats"
    ;;
esac

opts="$fmt_opts $common_opts"

# 5. Cookies file?
[ -f cookies.txt ] && opts+=" --cookies cookies.txt"

# 6. Aria2 support?
if command -v aria2c &>/dev/null; then
  opts+=" --external-downloader aria2c \
--external-downloader-args \"-x16 -s32 -k 1M --allow-overwrite=true\""
else
  echo "Note: aria2c not found; using yt-dlp’s default downloader."
fi

# 7. Parallel download (4-way)
xargs -a src_URLs.txt -P4 -I{} bash -c '
  url="{}"
  [[ $url != https://* ]] && url="https://${url#http://}"
  url=${url/#www./}
  yt-dlp '"$opts"' --cookies-from-browser firefox "$url" \
    || yt-dlp '"$opts"' --cookies-from-browser chrome "$url" \
    || yt-dlp '"$opts"' "$url"
' 2>&1 | tee output.log

# 8. Cleanup
find . -type f \( -name "*.vtt" -o -name "*.json" \) -delete

# 9. Post‐processing (video modes only)
if [ "$choice" -ne 1 ]; then
  # Prompt for transcription with 15-second timeout, default to "N"
  read -t 15 -p "Transcribe? [y/N] " ans
  ans=${ans:-N}

  if [[ "$ans" =~ ^[Yy]$ ]]; then
    exec ./transcribe.sh
  else
    exit 0
  fi
fi
