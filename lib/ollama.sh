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
    local mode="${1:-build}"
    local sys_msg=""
    sys_msg+="You are an AI coding agent running locally in a terminal. You help users with software engineering tasks.\n\n"

    if [[ "$mode" == "plan" ]]; then
        sys_msg+="MODE: PLAN (read-only)\n"
        sys_msg+="You are in plan mode. You CANNOT make any changes to files or run commands that modify anything.\n"
        sys_msg+="You can ONLY read files, search code, list directories, and analyze.\n"
        sys_msg+="Provide analysis, suggestions, and plans in text. Do NOT attempt to write, edit, or execute commands.\n\n"
    else
        sys_msg+="MODE: BUILD (full access)\n"
        sys_msg+="You have full access to read, write, edit files and run shell commands.\n\n"
    fi

    sys_msg+="## Tool Use\n"
    sys_msg+="When you need to use a tool, output EXACTLY one code block:\n\n"
    sys_msg+='```tool'+"\n"
    sys_msg+='{"name": "tool_name", "args": {"arg": "value"}}'+"\n"
    sys_msg+='```'+"\n\n"

    sys_msg+="### Available tools:\n"
    sys_msg+="- read_file: {path} — read file contents (supports offset/limit for large files)\n"
    sys_msg+="- write_file: {path, content} — create or overwrite a file\n"
    sys_msg+="- edit_file: {path, old_string, new_string} — find and replace in a file\n"
    sys_msg+="- search_files: {pattern, path?, include?} — search file contents with regex\n"
    sys_msg+="- glob_files: {pattern, path?} — find files by name pattern\n"
    sys_msg+="- bash_exec: {command, workdir?} — execute a shell command\n"
    sys_msg+="- list_dir: {path} — list directory contents\n"
    sys_msg+="- web_fetch: {url, format?} — fetch a web page (text or html)\n"
    sys_msg+="- todowrite: {todos: [{content, status, priority}]} — track task progress\n\n"

    sys_msg+="## Rules\n"
    sys_msg+="1. Call ONE tool at a time, then WAIT for the result\n"
    sys_msg+="2. After each tool result, DECIDE: call another tool OR respond with text\n"
    sys_msg+="3. When you have enough information, STOP calling tools and respond with text\n"
    sys_msg+="4. NEVER call the same tool with the same arguments more than once\n"
    sys_msg+="5. NEVER call the same tool more than 2 times in a row (even with different args)\n"
    sys_msg+="6. After writing/editing a file successfully, move on — do NOT redo it\n"
    sys_msg+="7. After listing a directory, describe what you see — do NOT list it again\n"
    sys_msg+="8. When you complete a task, summarize what you did and STOP\n"
    sys_msg+="9. For complex tasks, use todowrite to track your progress\n"
    sys_msg+="10. Read files before editing them — understand the context first\n"
    sys_msg+="11. Follow existing code conventions in the project\n"
    sys_msg+="12. Do NOT commit changes unless explicitly asked\n"

    echo -e "$sys_msg"
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
        local bin="${OLLAMA_BIN:-$(command -v ollama 2>/dev/null || echo "${HOME}/.local/bin/ollama")}"
        if [[ -x "$bin" ]]; then
            "$bin" serve &>/dev/null &
        elif command -v ollama &>/dev/null; then
            ollama serve &>/dev/null &
        else
            echo "ERROR: Cannot find Ollama binary" >&2
            return 1
        fi
        sleep 2
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
                if [[ "$tool_json" != *'"name"'* ]]; then
                    # Validate it's valid JSON before wrapping
                    if echo "$tool_json" | jq -e '.' &>/dev/null; then
                        tool_json="{\"name\":\"${tname}\",\"args\":${tool_json}}"
                    else
                        # Try to fix common JSON issues: single quotes, trailing commas
                        local fixed
                        fixed=$(echo "$tool_json" | sed "s/'/\"/g" | sed 's/,\s*}/}/g' | sed 's/,\s*]/]/g')
                        if echo "$fixed" | jq -e '.' &>/dev/null; then
                            tool_json="{\"name\":\"${tname}\",\"args\":${fixed}}"
                        else
                            tool_json=""
                        fi
                    fi
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

        local total=${#OLLAMA_MESSAGES[@]}
        local keep_start=$((total - 6))
        (( keep_start < 2 )) && keep_start=2

        # Copy messages to keep into a new array (avoid corrupting while reading)
        local -a new_msgs=("${OLLAMA_MESSAGES[0]}")
        local i=$keep_start
        while (( i < total )); do
            new_msgs+=("${OLLAMA_MESSAGES[i]}")
            i=$((i + 1))
        done

        OLLAMA_MESSAGES=("${new_msgs[@]}")

        save_session
        echo -e "${C_DIM}(compacted: kept system + last $((total - keep_start)) messages)${C_RESET}"
    fi
}

# ── Session save after each turn ────────────────────────────────────────────
save_session_after_turn() {
    save_session
}
