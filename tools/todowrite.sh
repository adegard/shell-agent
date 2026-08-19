#!/usr/bin/env bash
# ── todowrite tool ───────────────────────────────────────────────────────────

TODO_FILE="${WORKSPACE}/.agent-todos.json"

tool_todowrite() {
    local todos_json="$1"

    # Initialize empty array if no file exists
    if [[ ! -f "$TODO_FILE" ]]; then
        echo "[]" > "$TODO_FILE"
    fi

    # Merge new todos with existing ones (by content matching)
    local existing new_merged
    existing=$(cat "$TODO_FILE")
    new_merged=$(echo "$existing" | jq --argjson new "$todos_json" '
        # For each new todo, check if it already exists by content
        $new as $items |
        reduce $items[] as $item (
            .;
            if (.[] | .content) == $item.content then
                # Update existing todo
                [.[] | if .content == $item.content then $item else . end]
            else
                . + [$item]
            end
        )
    ' 2>/dev/null || echo "$todos_json")

    echo "$new_merged" | jq '.' > "$TODO_FILE"

    # Display current todos
    local count
    count=$(jq 'length' "$TODO_FILE" 2>/dev/null || echo "0")
    echo "Todo list (${count} items):"
    echo ""
    jq -r '.[] | "  [\(.status)] \(.content)"' "$TODO_FILE" 2>/dev/null
}
