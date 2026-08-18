#!/usr/bin/env bash
# ── read_file tool ───────────────────────────────────────────────────────────

tool_read_file() {
    local path="$1"

    if [[ ! -f "$path" ]]; then
        echo "ERROR: File not found: ${path}"
        return 1
    fi

    local lines
    lines=$(wc -l < "$path")
    echo "[${path}] (${lines} lines)"
    echo "---"
    head -n "${MAX_OUTPUT_LINES}" "$path"

    if (( lines > MAX_OUTPUT_LINES )); then
        echo ""
        echo "... (${lines} total lines, showing first ${MAX_OUTPUT_LINES})"
    fi
}
