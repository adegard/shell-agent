#!/usr/bin/env bash
# ── write_file tool ──────────────────────────────────────────────────────────

tool_write_file() {
    local path="$1"
    local content="$2"

    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"

    local lines
    lines=$(wc -l < "$path")
    echo "Wrote ${lines} lines to ${path}"
}
