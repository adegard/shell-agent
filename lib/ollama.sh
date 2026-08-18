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
You are a coding assistant that runs in a terminal. You help with reading, writing, searching, and building code.

You have access to these tools. Use them by writing a JSON code block:

```tool
{"name": "tool_name", "args": {"arg1": "value1"}}
```

Available tools:
- read_file: Read a file. args: {path}
- write_file: Write/overwrite a file. args: {path, content}
- edit_file: Edit a file (old_string → new_string). args: {path, old_string, new_string}
- search_files: Grep for pattern in files. args: {pattern, path?, include?}
- glob_files: Find files by name pattern. args: {pattern, path?}
- bash_exec: Run a shell command. args: {command, workdir?}
- list_dir: List directory contents. args: {path}

Rules:
- Always use the tool JSON code block format above
- One tool call per response
- After tool execution you'll see the result, then continue
- For multi-step tasks, keep calling tools until done
- When finished, just respond with text (no tool call)
- NEVER commit secrets, keys, or passwords
SYSPROMPT
}

# Append a message to the conversation
add_message() {
    local role="$1" content="$2"
    OLLAMA_MESSAGES+=("{\"role\":\"${role}\",\"content\":$(json_escape "$content")}")
}

# Escape string for JSON
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# Send chat request to Ollama (native API, more reliable than OpenAI compat)
ollama_chat() {
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
    [[ "$content" == *'```tool'* ]]
}

# Parse tool call from response: {"name": "...", "args": {...}}
parse_tool_call() {
    local response="$1"
    local content
    content=$(extract_content "$response")

    # Extract the JSON block between ```tool and ```
    local tool_json
    tool_json=$(echo "$content" | sed -n '/```tool/,/```/{/```/d;p}' | tr -d '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

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
