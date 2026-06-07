#!/bin/bash
# Build a Kannada IPTV playlist of only-live channels, tested from an Indian perspective.
#
# Strategy: MERGE, don't replace. The candidate pool is the union of
#   (a) the channels already in kannada.m3u (your curated set), and
#   (b) channels freshly discovered from the public SOURCES below by keyword.
# Every candidate URL is liveness-tested; only live ones survive. This keeps
# working curated channels while folding in new discoveries — so the playlist
# grows/maintains instead of shrinking to whatever the 3 sources happen to list.
#
# When run behind NordVPN India, the liveness curls originate from an India-
# registered IP, so geo-restricted Indian streams report their true availability.
set -uo pipefail
cd ~/kannada-playlist || exit 1

# A realistic player User-Agent — many IPTV edges reject the default curl UA.
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

# Geo guard. NordVPN's India servers are "Virtual" (no physical India servers
# since 2022), so routing DBs like ipinfo see the physical host while the IP is
# *registered* as India. We check ip-api.com (MaxMind family — what Indian
# streaming CDNs use), which reports these IPs as IN. Set REQUIRE_IN=1 to hard-fail.
country=$(curl -s --max-time 10 "http://ip-api.com/line/?fields=countryCode" 2>/dev/null | tr -d '[:space:]')
echo "Detected exit country (ip-api): ${country:-unknown}"
if [[ "$country" != "IN" ]]; then
  if [[ "${REQUIRE_IN:-0}" == "1" ]]; then
    echo "❌ Exit IP is '${country:-unknown}', not IN. Aborting (REQUIRE_IN=1)." >&2
    exit 2
  fi
  echo "⚠️  Warning: exit IP is '${country:-unknown}', not IN — results may not reflect an Indian perspective." >&2
fi

# Sources to pull from
SOURCES=(
  "https://iptv-org.github.io/iptv/countries/in.m3u"
  "https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8"
  "https://raw.githubusercontent.com/bugsfreeweb/LiveTVCollector/main/LiveTV/India/LiveTV.m3u"
)

KEYWORDS="kannada|suvarna|udaya|kasthuri|tv9 kannada|public tv|raj kannada|aastha kannada|colors kannada|zee kannada"

# --- Build the candidate pool ----------------------------------------------
# pairs.tmp holds, one per line:  <url><TAB><EXTINF line>
# Existing curated channels are listed FIRST so their (clean) EXTINF wins on dedup.
: > pairs.tmp
: > live_urls.txt
: > dead_urls.txt

# (a) existing curated channels
if [[ -f kannada.m3u ]]; then
  awk 'BEGIN{FS="\n"} /^#EXTINF/{inf=$0; if((getline u)>0 && u ~ /^http/){print u "\t" inf}}' kannada.m3u >> pairs.tmp
fi

# (b) freshly discovered channels
discovered_raw="$(mktemp)"
echo "#EXTM3U" > "$discovered_raw"
for url in "${SOURCES[@]}"; do
  echo "Fetching $url ..."
  curl -sL -A "$UA" --max-time 20 "$url" \
    | grep -i -A1 -E "$KEYWORDS" | grep -v '^--$' >> "$discovered_raw"
done
awk 'BEGIN{FS="\n"} /^#EXTINF/{inf=$0; if((getline u)>0 && u ~ /^http/){print u "\t" inf}}' "$discovered_raw" >> pairs.tmp
rm -f "$discovered_raw"

# Dedup by URL, first occurrence (curated) wins; preserves order.
awk -F'\t' '!seen[$1]++' pairs.tmp > pairs_uniq.tmp
cut -f1 pairs_uniq.tmp > test_urls.txt
echo "Candidate channels (curated + discovered, deduped): $(wc -l < test_urls.txt)"

# --- Liveness test (parallel, India-routed) --------------------------------
echo "Testing liveness of all channels (may take a minute)..."
cat test_urls.txt | parallel -j 20 '
  url={}
  status=$(curl -s -o /dev/null -L -A "'"$UA"'" -w "%{http_code}" --max-time 8 "$url" 2>/dev/null)
  if [[ "$status" =~ ^[23] ]]; then
    echo "$url" >> live_urls.txt
  else
    echo "$url" >> dead_urls.txt
  fi
'
sort -u live_urls.txt -o live_urls.txt

# --- Rebuild playlist from live channels, preserving curated EXTINF order ---
: > kannada_live.m3u
echo "#EXTM3U" >> kannada_live.m3u
while IFS=$'\t' read -r url inf; do
  if grep -qxF "$url" live_urls.txt; then
    printf '%s\n%s\n' "$inf" "$url" >> kannada_live.m3u
  fi
done < pairs_uniq.tmp

# Sanitize EXTINF names: some upstream sources leak User-Agent fragments
# (e.g. 'like Gecko) Chrome/... " group-title="...",') into the channel name.
sed -i -E '/^#EXTINF/ s/like Gecko\)[^"]*"[[:space:]]*group-title="[^"]*",//g' kannada_live.m3u

# --- Commit result only if non-empty (never clobber with an empty playlist) -
total_live=$(grep -c '^http' kannada_live.m3u)
if [[ "$total_live" -gt 0 ]]; then
  mv kannada_live.m3u kannada.m3u
  echo "✅ Final playlist has $total_live live Kannada channels"
else
  echo "❌ No live channels found — keeping existing kannada.m3u unchanged." >&2
fi

rm -f pairs.tmp pairs_uniq.tmp kannada_live.m3u test_urls.txt live_urls.txt dead_urls.txt
exit 0
