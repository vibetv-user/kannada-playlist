#!/usr/bin/env python3
import sys
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed

def is_live(url):
    try:
        r = requests.get(url, timeout=5, stream=True)
        return r.status_code < 400
    except:
        return False

def parse_m3u(filepath):
    channels = []
    with open(filepath) as f:
        lines = f.readlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith('#EXTINF'):
            # Extract channel name (everything after last comma)
            name = line.split(',')[-1].strip()
            # Look ahead for the URL (skip empty lines)
            i += 1
            while i < len(lines) and lines[i].strip() == '':
                i += 1
            if i < len(lines):
                url = lines[i].strip()
                if url.startswith('http'):
                    channels.append((name, url))
        i += 1
    return channels

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python3 test_m3u.py <playlist.m3u>")
        sys.exit(1)
    channels = parse_m3u(sys.argv[1])
    print(f"Found {len(channels)} channels. Testing live streams...")
    live, dead = [], []
    with ThreadPoolExecutor(max_workers=20) as executor:
        future_to_name = {executor.submit(is_live, url): name for name, url in channels}
        for future in as_completed(future_to_name):
            name = future_to_name[future]
            if future.result():
                live.append(name)
            else:
                dead.append(name)
    print(f"\nLIVE ({len(live)}):")
    for name in live:
        print(f"  {name}")
    print(f"\nDEAD ({len(dead)}):")
    for name in dead:
        print(f"  {name}")
