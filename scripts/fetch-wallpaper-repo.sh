#!/bin/bash
# Fetches an http(s) wallpaper source once and caches its images locally.
# $1: the source URL (expected to be a plain directory listing).
# $2: the local cache directory to download images into.
set -uo pipefail

url="$1"
cache_dir="$2"

mkdir -p "$cache_dir"

listing="$(curl -fsSL --max-time 20 "$url" 2>/dev/null)" || exit 0

echo "$listing" \
  | grep -oiE 'href="[^"]+\.(jpe?g|png|webp|gif|bmp)"' \
  | sed -E 's/^[Hh][Rr][Ee][Ff]="([^"]+)"$/\1/' \
  | while IFS= read -r href; do
      case "$href" in
        http://*|https://*) full="$href" ;;
        /*) full="$(printf '%s' "$url" | sed -E 's#^(https?://[^/]+).*#\1#')$href" ;;
        *) full="${url%/}/$href" ;;
      esac
      name="$(basename "$href")"
      dest="$cache_dir/$name"
      [ -f "$dest" ] || curl -fsSL --max-time 20 -o "$dest" "$full" 2>/dev/null || rm -f "$dest"
    done
