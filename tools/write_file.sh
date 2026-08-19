#!/usr/bin/env bash
# ── write_file tool ──────────────────────────────────────────────────────────

tool_write_file() {
    local path="$1"
    local content="$2"

    if ! mkdir -p "$(dirname "$path")" 2>/dev/null; then
        echo "ERROR: Cannot create directory: $(dirname "$path")"
        return 1
    fi

    if ! printf '%s' "$content" > "$path" 2>/dev/null; then
        echo "ERROR: Cannot write to ${path} (read-only or permission denied)"
        return 1
    fi

    local bytes lines
    bytes=$(wc -c < "$path")
    lines=$(wc -l < "$path")
    echo "Wrote ${bytes} bytes (${lines} lines) to ${path}"
}
