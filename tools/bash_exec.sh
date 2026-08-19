#!/usr/bin/env bash
# ── bash_exec tool ───────────────────────────────────────────────────────────

tool_bash_exec() {
    local command="$1"
    local workdir="${2:-.}"

    if [[ ! -d "$workdir" ]]; then
        echo "ERROR: Directory not found: ${workdir}"
        return 1
    fi

    local output exit_code
    output=$(cd "$workdir" && eval "$command" 2>&1)
    exit_code=$?

    echo "CMD: ${command}"
    echo "DIR: ${workdir}"
    echo "OUT:"
    echo "$output"
    echo "EXIT: ${exit_code}"
}
