#!/usr/bin/env bash
# ── edit_file tool ───────────────────────────────────────────────────────────

tool_edit_file() {
    local path="$1"
    local old_string="$2"
    local new_string="$3"

    if [[ ! -f "$path" ]]; then
        echo "ERROR: File not found: ${path}"
        return 1
    fi

    if ! grep -qF "$old_string" "$path"; then
        echo "ERROR: old_string not found in ${path}"
        return 1
    fi

    local tmp="${path}.tmp.$$"
    # Use awk for safe replacement (handles special chars better than sed)
    awk -v old="$old_string" -v new="$new_string" '
        { gsub(old, new) }
        { print }
    ' "$path" > "$tmp"

    mv "$tmp" "$path"
    echo "Edited ${path}"
}
