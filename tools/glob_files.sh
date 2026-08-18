#!/usr/bin/env bash
# ── glob_files tool (find) ───────────────────────────────────────────────────

tool_glob_files() {
    local pattern="$1"
    local path="${2:-.}"

    # Simple find with name matching, skip .git and node_modules
    local results
    results=$(find "$path" -name "$pattern" \
        -not -path "*/.git/*" \
        -not -path "*/node_modules/*" \
        -not -path "*/vendor/*" \
        -type f 2>/dev/null | head -100)

    if [[ -z "$results" ]]; then
        echo "No files matching '${pattern}' in ${path}"
        return 0
    fi

    local count
    count=$(echo "$results" | wc -l)
    echo "Found ${count} files:"
    echo "$results"
}
