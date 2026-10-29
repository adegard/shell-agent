#!/usr/bin/env bash
set -e

read -r -p "What do you want to search for? " question

python3 - "$question" <<'PY'
import json
import subprocess
import sys
import urllib.request
from html.parser import HTMLParser
from urllib.parse import urlparse

class FirstCodeBlock(HTMLParser):
    def __init__(self):
        super().__init__()
        self.inside_pre = False
        self.finished = False
        self.parts = []

    def handle_starttag(self, tag, attrs):
        if tag == "pre" and not self.finished:
            self.inside_pre = True

    def handle_endtag(self, tag):
        if tag == "pre" and self.inside_pre:
            self.inside_pre = False
            self.finished = True

    def handle_data(self, data):
        if self.inside_pre:
            self.parts.append(data)

def find_url(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key.lower() in ("url", "link") and isinstance(item, str):
                if item.startswith(("https://", "http://")):
                    return item
        for item in value.values():
            result = find_url(item)
            if result:
                return result
    elif isinstance(value, list):
        for item in value:
            result = find_url(item)
            if result:
                return result
    return None

try:
    result = subprocess.run(
        ["ddgr", "--json", "-n", "1", sys.argv[1]],
        capture_output=True, text=True, check=True
    )
    url = find_url(json.loads(result.stdout))
    if not url:
        raise RuntimeError("No first-result URL found in ddgr's output.")

    if urlparse(url).scheme not in ("http", "https"):
        raise RuntimeError("The result is not an HTTP or HTTPS URL.")

    request = urllib.request.Request(
        url, headers={"User-Agent": "Mozilla/5.0"}
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        charset = response.headers.get_content_charset() or "utf-8"
        page = response.read(2_000_000).decode(charset, errors="replace")

    parser = FirstCodeBlock()
    parser.feed(page)
    if not parser.parts:
        raise RuntimeError("The first result has no <pre> code block.")

    code = "".join(parser.parts)
    print(f"\nFirst result: {url}\n")
    print("--- Code found (not executed) ---")
    print(code)
    print("---------------------------------")

    if input("\nSave this code for review? [y/N] ").strip().lower() == "y":
        with open("code-review.txt", "w", encoding="utf-8") as file:
            file.write(code)
        print("Saved to code-review.txt")

except FileNotFoundError:
    sys.exit("ddgr is not installed. Install it with your Linux package manager.")
except Exception as error:
    sys.exit(f"Could not retrieve a code block: {error}")
PY
