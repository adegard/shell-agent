#!/usr/bin/env bash
# ── Ollama API integration ──────────────────────────────────────────────────

OLLAMA_MESSAGES=()
OLLAMA_TOOLS_JSON=""

# Build the OpenAI-compatible tools JSON from our tool definitions
build_tools_json() {
    local tools_dir="${AGENT_DIR}/tools"
    OLLAMA_TOOLS_JSON="["
    local first=true
    for f in "${tools_dir}"/*.tool.json; do
        [[ -f "$f" ]] || continue
        [[ "$first" == "true" ]] && first=false || OLLAMA_TOOLS_JSON+=","
        OLLAMA_TOOLS_JSON+="$(cat "$f")"
    done
    OLLAMA_TOOLS_JSON+="]"
}

# System prompt
get_system_prompt() {
    cat <<'SYSPROMPT'
You are a coding assistant. You help with reading, writing, searching, and building code.

When you need to use a tool, output EXACTLY one code block like this:

```tool
{"name": "tool_name", "args": {"arg": "value"}}
```

Available tools:
- read_file: {path} — read a file
- write_file: {path, content} — write a file
- edit_file: {path, old_string, new_string} — edit a file
- search_files: {pattern, path?, include?} — grep for pattern
- glob_files: {pattern, path?} — find files by name
- bash_exec: {command, workdir?} — run a shell command
- list_dir: {path} — list directory
- web_fetch: {url, format?} — fetch a webpage (text or html)

IMPORTANT RULES:
1. Call ONE tool at a time
2. After each tool result, DECIDE: call another tool OR respond with text
3. When you have enough information, STOP calling tools and respond with text
4. NEVER call the same tool with the same arguments twice
5. For "list files" tasks: list the directory ONCE, then describe what you see in text
6. To get GitHub repos, use: bash_exec with command "curl -s https://api.github.com/users/USERNAME/repos | jq '.[].full_name'"
7. After completing a task, respond with what you did. Wait for the next request.
SYSPROMPT
}

# Append a message to the conversation
add_message() {
    local role="$1" content="$2"
    OLLAMA_MESSAGES+=("{\"role\":\"${role}\",\"content\":$(json_escape "$content")}")
}

# Escape string for JSON (with surrounding quotes)
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '"%s"' "$s"
}

# Send chat request to Ollama (native API, more reliable than OpenAI compat)
ollama_chat() {
    # Auto-restart Ollama if not responding
    if ! curl -sf "${OLLAMA_HOST}/api/tags" &>/dev/null; then
        echo -e "${C_YELLOW}Ollama not running, restarting...${C_RESET}" >&2
        if [[ -x "$OLLAMA_BIN" ]]; then
            "${OLLAMA_BIN}" serve &>/dev/null &
        else
            ollama serve &>/dev/null &
        fi
        sleep 3
        if ! curl -sf "${OLLAMA_HOST}/api/tags" &>/dev/null; then
            echo "ERROR: Cannot start Ollama" >&2
            return 1
        fi
        echo -e "${C_GREEN}Ollama restarted${C_RESET}" >&2
    fi

    local messages_json
    messages_json=$(printf '%s\n' "${OLLAMA_MESSAGES[@]}" | paste -sd, -)

    local payload
    payload=$(cat <<EOF
{
  "model": "${OLLAMA_MODEL}",
  "messages": [${messages_json}],
  "stream": false,
  "options": {
    "num_ctx": ${CONTEXT_WINDOW},
    "temperature": 0.1
  }
}
EOF
)

    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo "[DEBUG] POST ${OLLAMA_HOST}/api/chat" >&2
    fi

    local response http_code
    response=$(curl -s -w "\n%{http_code}" --max-time "${OLLAMA_TIMEOUT}" \
        "${OLLAMA_HOST}/api/chat" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)

    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        echo "ERROR: Ollama returned HTTP ${http_code}" >&2
        echo "$response" | head -5 >&2
        return 1
    fi

    if [[ -z "$response" ]] || [[ "$response" == "null" ]]; then
        echo "ERROR: Empty response from Ollama" >&2
        return 1
    fi

    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo "[DEBUG] Response OK ($(echo "$response" | wc -c) bytes)" >&2
    fi

    echo "$response"
}

# Extract the assistant message content from response (native Ollama API)
extract_content() {
    local response="$1"
    # Native API: .message.content
    local content
    content=$(echo "$response" | jq -r '.message.content // empty' 2>/dev/null)
    if [[ -n "$content" ]]; then
        echo "$content"
        return
    fi
    # OpenAI compat fallback: .choices[0].message.content
    echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null
}

# Check if response contains a tool call
has_tool_call() {
    local response="$1"
    local content
    content=$(extract_content "$response")
    # Match ```tool OR ```<tool_name> (model sometimes uses tool name as language)
    [[ "$content" == *'```tool'* ]] || \
    [[ "$content" == *'```bash_exec'* ]] || \
    [[ "$content" == *'```write_file'* ]] || \
    [[ "$content" == *'```read_file'* ]] || \
    [[ "$content" == *'```edit_file'* ]] || \
    [[ "$content" == *'```search_files'* ]] || \
    [[ "$content" == *'```glob_files'* ]] || \
    [[ "$content" == *'```list_dir'* ]] || \
    [[ "$content" == *'```web_fetch'* ]]
}

# Parse tool call from response: {"name": "...", "args": {...}}
parse_tool_call() {
    local response="$1"
    local content
    content=$(extract_content "$response")

    local tool_json=""

    # Try ```tool first (correct format)
    tool_json=$(echo "$content" | sed -n '/```tool/,/```/{/```/d;p}' | tr -d '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

    # If not found, try ```<tool_name> format
    if [[ -z "$tool_json" ]]; then
        for tname in bash_exec write_file read_file edit_file search_files glob_files list_dir web_fetch; do
            tool_json=$(echo "$content" | sed -n "/^\`\`\`${tname}/,/^\`\`\`/{/\`\`\`/d;p}" | tr -d '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            if [[ -n "$tool_json" ]]; then
                # Model output just the args without {"name":..., "args":...} wrapper
                # Wrap it: {"name": "tname", "args": <json>}
                if [[ "$tool_json" != *'"name"'* ]]; then
                    tool_json="{\"name\":\"${tname}\",\"args\":${tool_json}}"
                fi
                break
            fi
        done
    fi

    if [[ -n "$tool_json" ]]; then
        echo "$tool_json"
        return 0
    fi
    return 1
}

# Extract tool name from tool call JSON
tool_name() {
    echo "$1" | jq -r '.name // empty' 2>/dev/null
}

# Extract tool args from tool call JSON
tool_args() {
    echo "$1" | jq -r '.args // {}' 2>/dev/null
}

# Extract a single arg value
tool_arg() {
    echo "$1" | jq -r ".$2 // \"\"" 2>/dev/null
}

# ── Session persistence ─────────────────────────────────────────────────────

SESSION_FILE="${AGENT_DIR}/session.json"

save_session() {
    local msgs_json="["
    local first=true
    for m in "${OLLAMA_MESSAGES[@]}"; do
        [[ "$first" == "true" ]] && first=false || msgs_json+=","
        msgs_json+="$m"
    done
    msgs_json+="]"
    echo "$msgs_json" > "${SESSION_FILE}"
}

load_session() {
    if [[ -f "${SESSION_FILE}" ]] && [[ -s "${SESSION_FILE}" ]]; then
        local count
        count=$(jq 'length' "${SESSION_FILE}" 2>/dev/null || echo "0")
        if (( count > 0 )); then
            OLLAMA_MESSAGES=()
            local i=0
            while (( i < count )); do
                local msg
                msg=$(jq -c ".[$i]" "${SESSION_FILE}" 2>/dev/null)
                [[ -n "$msg" ]] && OLLAMA_MESSAGES+=("$msg")
                i=$((i + 1))
            done
            return 0
        fi
    fi
    return 1
}

clear_session() {
    OLLAMA_MESSAGES=()
    rm -f "${SESSION_FILE}"
}

# ── Auto-compaction ─────────────────────────────────────────────────────────

compact_if_needed() {
    local total_chars=0
    for m in "${OLLAMA_MESSAGES[@]}"; do
        total_chars=$((total_chars + ${#m}))
    done

    local max_chars=$((CONTEXT_WINDOW * 4 * 80 / 100))

    if (( total_chars > max_chars )); then
        echo -e "${C_DIM}(context full, compacting...)${C_RESET}"

        # Keep: system message [0] + last 6 messages
        local sys_msg="${OLLAMA_MESSAGES[0]}"
        local total=${#OLLAMA_MESSAGES[@]}
        local keep_start=$((total - 6))
        (( keep_start < 2 )) && keep_start=2

        OLLAMA_MESSAGES=("$sys_msg")
        local i=$keep_start
        while (( i < total )); do
            OLLAMA_MESSAGES+=("${OLLAMA_MESSAGES[$i]}")
            i=$((i + 1))
        done

        save_session
        echo -e "${C_DIM}(compacted: kept system + last $((total - keep_start)) messages)${C_RESET}"
    fi
}

# ── Session save after each turn ────────────────────────────────────────────
save_session_after_turn() {
    save_session
}
