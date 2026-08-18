#!/usr/bin/env bash
# ── search_files tool (grep) ─────────────────────────────────────────────────

tool_search_files() {
    local pattern="$1"
    local path="${2:-.}"
    local include="${3:-}"

    local grep_args=(-rn --color=never -l)
    grep_args+=(-E "$pattern")

    if [[ -n "$include" ]]; then
        grep_args+=(--include="$include")
    fi

    # Skip binary files and common junk
    grep_args+=(--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=vendor)

    local results
    results=$(grep "${grep_args[@]}" "$path" 2>/dev/null || true)

    if [[ -z "$results" ]]; then
        echo "No matches found for '${pattern}' in ${path}"
        return 0
    fi

    # Show file list with match count
    echo "Matches in:"
    while IFS= read -r file; do
        local count
        count=$(grep -cE "$pattern" "$file" 2>/dev/null || echo "0")
        echo "  ${file} (${count} matches)"
    done <<< "$results"

    echo ""
    echo "--- First 50 matching lines ---"
    grep -rnE --color=never "$pattern" "$path" \
        --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=vendor \
        2>/dev/null | head -50
}
