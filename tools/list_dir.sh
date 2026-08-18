#!/usr/bin/env bash
# ── list_dir tool ────────────────────────────────────────────────────────────

tool_list_dir() {
    local path="${1:-.}"

    if [[ ! -d "$path" ]]; then
        echo "ERROR: Directory not found: ${path}"
        return 1
    fi

    echo "[${path}]"
    echo ""

    # ls with indicators: / for dirs, * for executables
    ls -1Fh "$path" 2>/dev/null | head -100

    local total
    total=$(ls -1 "$path" 2>/dev/null | wc -l)
    echo ""
    echo "(${total} entries)"
}
