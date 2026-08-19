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

IMPORTANT RULES:
1. Call ONE tool at a time
2. After each tool result, DECIDE: call another tool OR respond with text
3. When you have enough information, STOP calling tools and respond with text
4. NEVER call the same tool with the same arguments twice
5. For "list files" tasks: list the directory ONCE, then describe what you see in text
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
