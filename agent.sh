#!/usr/bin/env bash
# ── shell-agent: local coding assistant for Termux/Android ───────────────────
# Replicates opencode-style coding workflow using Ollama locally.
#
# Usage:
#   ./agent.sh                        # interactive mode
#   ./agent.sh "write a fizzbuzz"     # single prompt mode
#   ./agent.sh -m llama3.2 "hello"    # override model
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Load modules (before arg parsing so vars are set) ───────────────────────
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/ollama.sh"

# Load all tool implementations
for tool_file in "${SCRIPT_DIR}/tools/"*.sh; do
    [[ -f "$tool_file" ]] && source "$tool_file"
done

# ── Parse args ──────────────────────────────────────────────────────────────
SINGLE_PROMPT=""
FRESH_SESSION=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model) OLLAMA_MODEL="$2"; shift 2 ;;
        -d|--debug) export DEBUG=1; shift ;;
        --fresh) FRESH_SESSION=1; shift ;;
        -t|--test)
            echo "Testing Ollama at ${OLLAMA_HOST}..."
            if ! curl -sf "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
                echo "Cannot reach Ollama. Is it running? Try: ollama serve &"
                exit 1
            fi
            echo "Ollama is running. Models:"
            curl -sf "${OLLAMA_HOST}/api/tags" | jq -r '.models[].name' 2>/dev/null
            echo ""
            echo "Testing model ${OLLAMA_MODEL}..."
            echo 'Sending: {"model":"'"${OLLAMA_MODEL}"'","messages":[{"role":"user","content":"say hi"}],"stream":false}'
            RESP=$(curl -s --max-time 60 "${OLLAMA_HOST}/api/chat" \
                -H "Content-Type: application/json" \
                -d '{"model":"'"${OLLAMA_MODEL}"'","messages":[{"role":"user","content":"say hi"}],"stream":false}' 2>&1)
            echo "Response: $(echo "$RESP" | jq -r '.message.content // .error // empty' 2>/dev/null || echo "$RESP")"
            exit 0
            ;;
        -h|--help)
            echo "Usage: agent.sh [-m model] [-d] [-t] [--fresh] [prompt]"
            echo "  -m, --model   Override Ollama model"
            echo "  -d, --debug   Show debug output"
            echo "  -t, --test    Test Ollama connection"
            echo "  --fresh       Start fresh session (ignore saved)"
            echo "  -h, --help    Show this help"
            echo ""
            echo "Env vars:"
            echo "  OLLAMA_HOST    Ollama server URL (default: http://127.0.0.1:11434)"
            echo "  OLLAMA_MODEL   Model name (default: qwen2.5-coder:1.5b)"
            echo "  WORKSPACE      Working directory (default: cwd)"
            echo "  DEBUG=1        Enable debug output"
            exit 0
            ;;
        *) SINGLE_PROMPT="$1"; shift ;;
    esac
done

# ── Check Ollama is running ─────────────────────────────────────────────────
start_ollama() {
    local bin="${OLLAMA_BIN:-$(command -v ollama 2>/dev/null || echo "${HOME}/.local/bin/ollama")}"
    if [[ -x "$bin" ]]; then
        "$bin" serve &>/dev/null &
    elif command -v ollama &>/dev/null; then
        ollama serve &>/dev/null &
    else
        return 1
    fi
    sleep 2
    curl -sf "${OLLAMA_HOST}/api/tags" &>/dev/null
}

check_ollama() {
    if curl -sf "${OLLAMA_HOST}/api/tags" &>/dev/null; then
        # Already running, just check model
        local models
        models=$(curl -sf "${OLLAMA_HOST}/api/tags" | jq -r '.models[].name' 2>/dev/null)
        if echo "$models" | grep -q "$OLLAMA_MODEL"; then
            return 0
        fi
        echo -e "${C_YELLOW}Model '${OLLAMA_MODEL}' not found.${C_RESET}"
        echo ""
        echo "Available models:"
        echo "$models" | sed 's/^/  /'
        echo ""
        echo "Pull it with: ollama pull ${OLLAMA_MODEL}"
        exit 1
    fi

    # Not running — try to start it
    echo -e "${C_DIM}Starting Ollama...${C_RESET}" >&2
    if start_ollama; then
        echo -e "${C_GREEN}Ollama started${C_RESET}" >&2
    else
        echo -e "${C_RED}Cannot start Ollama. Is it installed?${C_RESET}" >&2
        echo "  Install: curl -fsSL https://ollama.com/install.sh | sh" >&2
        echo "  Or start manually: ollama serve &" >&2
        exit 1
    fi
}

# ── Dispatch tool call ──────────────────────────────────────────────────────
execute_tool() {
    local name="$1" args_json="$2"
    local result=""

    case "$name" in
        read_file)
            local p
            p=$(tool_arg "$args_json" "path")
            result=$(tool_read_file "$p")
            ;;
        write_file)
            local p c
            p=$(tool_arg "$args_json" "path")
            c=$(tool_arg "$args_json" "content")
            result=$(tool_write_file "$p" "$c")
            ;;
        edit_file)
            local p o n
            p=$(tool_arg "$args_json" "path")
            o=$(tool_arg "$args_json" "old_string")
            n=$(tool_arg "$args_json" "new_string")
            result=$(tool_edit_file "$p" "$o" "$n")
            ;;
        search_files)
            local pat path inc
            pat=$(tool_arg "$args_json" "pattern")
            path=$(tool_arg "$args_json" "path")
            inc=$(tool_arg "$args_json" "include")
            [[ -z "$path" ]] && path="."
            result=$(tool_search_files "$pat" "$path" "$inc")
            ;;
        glob_files)
            local pat path
            pat=$(tool_arg "$args_json" "pattern")
            path=$(tool_arg "$args_json" "path")
            [[ -z "$path" ]] && path="."
            result=$(tool_glob_files "$pat" "$path")
            ;;
        bash_exec)
            local cmd wd
            cmd=$(tool_arg "$args_json" "command")
            wd=$(tool_arg "$args_json" "workdir")
            [[ -z "$wd" ]] && wd="$WORKSPACE"
            result=$(tool_bash_exec "$cmd" "$wd")
            ;;
        list_dir)
            local p
            p=$(tool_arg "$args_json" "path")
            [[ -z "$p" ]] && p="$WORKSPACE"
            result=$(tool_list_dir "$p")
            ;;
        web_fetch)
            local url fmt
            url=$(tool_arg "$args_json" "url")
            fmt=$(tool_arg "$args_json" "format")
            [[ -z "$fmt" ]] && fmt="text"
            result=$(tool_web_fetch "$url" "$fmt")
            ;;
        todowrite)
            local todos
            todos=$(tool_arg "$args_json" "todos")
            result=$(tool_todowrite "$todos")
            ;;
        *)
            result="ERROR: Unknown tool: ${name}"
            ;;
    esac

    # Truncate long output
    local byte_count
    byte_count=$(echo -n "$result" | wc -c)
    if (( byte_count > MAX_OUTPUT_BYTES )); then
        result=$(echo "$result" | head -n "$MAX_OUTPUT_LINES")
        result="${result}
... (truncated: ${byte_count} bytes total)"
    fi

    echo "$result"
}

# ── Main agent loop ─────────────────────────────────────────────────────────
AGENT_MODE="build"  # "build" or "plan"
LAST_USER_INPUT=""
LAST_SESSION_FILE="${AGENT_DIR}/last_session.json"

run_agent() {
    local user_input="$1"
    LAST_USER_INPUT="$user_input"

    local mode_label=""
    if [[ "$AGENT_MODE" == "plan" ]]; then
        mode_label="${C_YELLOW}[plan]${C_RESET} "
    fi

    echo -e "${mode_label}${C_BOLD}${C_CYAN}shell-agent${C_RESET} ${C_DIM}v${AGENT_VERSION}${C_RESET}"
    echo -e "${C_DIM}model: ${OLLAMA_MODEL} | workspace: ${WORKSPACE}${C_RESET}"
    echo ""

    build_tools_json
    OLLAMA_MESSAGES=()
    add_message "system" "$(get_system_prompt "$AGENT_MODE")"
    add_message "user" "$user_input"

    local iteration=0
    # Track recent tool calls for loop detection (last N calls)
    local -a recent_calls=()
    local MAX_RECENT=5
    local MAX_REPEAT=2

    while (( iteration < MAX_ITERATIONS )); do
        iteration=$((iteration + 1))
        echo -ne "${C_DIM}[${iteration}/${MAX_ITERATIONS}] thinking...${C_RESET}\r" >&2

        local response
        response=$(ollama_chat 2>&1) || {
            echo ""
            echo -e "${C_RED}Failed to contact Ollama:${C_RESET}"
            echo "$response" | head -5
            return 1
        }

        if [[ "$response" == ERROR:* ]]; then
            echo ""
            echo -e "${C_RED}${response}${C_RESET}"
            return 1
        fi

        local content
        content=$(extract_content "$response")

        if [[ -z "$content" ]]; then
            echo ""
            echo -e "${C_YELLOW}Empty response from model.${C_RESET}"
            return 1
        fi

        if has_tool_call "$response"; then
            local call_json
            call_json=$(parse_tool_call "$response")
            local tname targs
            tname=$(tool_name "$call_json")
            targs=$(tool_args "$call_json")

            # ── Plan mode: deny write/edit/bash tools ──
            if [[ "$AGENT_MODE" == "plan" ]]; then
                case "$tname" in
                    write_file|edit_file|bash_exec|todowrite)
                        echo -e "${C_YELLOW}[plan mode] Skipping ${tname} (read-only mode)${C_RESET}"
                        add_message "assistant" "$content"
                        add_message "user" "Tool ${tname} was skipped because you are in plan mode (read-only). You cannot make changes. Analyze the code and provide your plan in text."
                        continue
                        ;;
                esac
            fi

            local call_sig="${tname}:${targs}"

            # ── Loop detection: count how many times this exact call appears in recent history ──
            local same_count=0
            local recent_idx=$(( ${#recent_calls[@]} - MAX_RECENT ))
            (( recent_idx < 0 )) && recent_idx=0
            for (( ri=recent_idx; ri < ${#recent_calls[@]}; ri++ )); do
                if [[ "${recent_calls[$ri]}" == "$call_sig" ]]; then
                    same_count=$((same_count + 1))
                fi
            done

            if (( same_count >= MAX_REPEAT )); then
                echo -e "${C_YELLOW}(model stuck in loop — same tool+args called $((same_count+1))x, forcing summary)${C_RESET}"
                add_message "assistant" "$content"
                add_message "user" "STOP. You have already called this tool with the same arguments and got the result. Do NOT call any more tools. Respond now with a text summary of what you found and what you did."
                local final_resp
                final_resp=$(ollama_chat 2>&1)
                local final_content
                final_content=$(extract_content "$final_resp")
                echo ""
                echo -e "${C_GREEN}${final_content}${C_RESET}"
                echo ""
                save_session
                return 0
            fi

            # Also detect: same tool name called MAX_REPEAT+ times even with different args
            local tool_count=0
            for (( ri=recent_idx; ri < ${#recent_calls[@]}; ri++ )); do
                local prev_name="${recent_calls[$ri]%%:*}"
                if [[ "$prev_name" == "$tname" ]]; then
                    tool_count=$((tool_count + 1))
                fi
            done

            if (( tool_count >= MAX_REPEAT )); then
                echo -e "${C_YELLOW}(model calling ${tname} repeatedly, forcing summary)${C_RESET}"
                add_message "assistant" "$content"
                add_message "user" "STOP. You have called ${tname} too many times. Do NOT call any more tools. Respond now with a text summary of what you found and what you did."
                local final_resp
                final_resp=$(ollama_chat 2>&1)
                local final_content
                final_content=$(extract_content "$final_resp")
                echo ""
                echo -e "${C_GREEN}${final_content}${C_RESET}"
                echo ""
                save_session
                return 0
            fi

            # Track this call
            recent_calls+=("$call_sig")
            (( ${#recent_calls[@]} > MAX_RECENT * 2 )) && recent_calls=("${recent_calls[@]:$MAX_RECENT}")

            # Show tool call
            echo -e "${C_BLUE}▸ tool:${C_RESET} ${C_BOLD}${tname}${C_RESET} ${C_DIM}$(echo "$targs" | jq -c '.' 2>/dev/null || echo "$targs")${C_RESET}"

            local output
            output=$(execute_tool "$tname" "$targs") || true

            # Show output — special formatting for bash_exec
            if [[ "$tname" == "bash_exec" ]]; then
                local cmd_line dir_line exit_line
                cmd_line=$(echo "$output" | grep '^CMD: ' | sed 's/^CMD: //')
                dir_line=$(echo "$output" | grep '^DIR: ' | sed 's/^DIR: //')
                exit_line=$(echo "$output" | grep '^EXIT: ' | sed 's/^EXIT: //')
                local out_body
                out_body=$(echo "$output" | sed '/^CMD: /d; /^DIR: /d; /^OUT:/d; /^EXIT: /d')

                echo -e "  ${C_CYAN}\$${C_RESET} ${C_BOLD}${cmd_line}${C_RESET}"
                echo -e "  ${C_DIM}in ${dir_line}${C_RESET}"
                if [[ -n "$out_body" ]]; then
                    local out_lines
                    out_lines=$(echo "$out_body" | wc -l)
                    if (( out_lines <= 20 )); then
                        echo -e "  ${C_DIM}${out_body}${C_RESET}"
                    else
                        echo -e "  ${C_DIM}$(echo "$out_body" | head -n 15)${C_RESET}"
                        echo -e "  ${C_DIM}  ... +$(( out_lines - 15 )) lines${C_RESET}"
                    fi
                fi
                if [[ "$exit_line" != "0" ]]; then
                    echo -e "  ${C_RED}exit: ${exit_line}${C_RESET}"
                else
                    echo -e "  ${C_DIM}exit: 0${C_RESET}"
                fi
            else
                local line_count
                line_count=$(echo "$output" | wc -l)
                if (( line_count <= 15 )); then
                    echo -e "${C_DIM}${output}${C_RESET}"
                else
                    echo -e "${C_DIM}$(echo "$output" | head -n 10)${C_RESET}"
                    echo -e "${C_DIM}  ... +$(( line_count - 10 )) lines (${C_RESET}${line_count}${C_DIM} total)${C_RESET}"
                fi
            fi
            echo ""

            add_message "assistant" "$content"
            add_message "user" "Tool result for ${tname}:
${output}"

            # Auto-compact: if messages get too large, summarize old ones
            compact_if_needed

        else
            echo ""
            echo -e "${C_GREEN}${content}${C_RESET}"
            echo ""

            save_session

            printf '{"ts":"%s","input":"%s","iterations":%d}\n' \
                "$(date -Iseconds)" "$user_input" "$iteration" \
                >> "${HISTORY_FILE}"

            return 0
        fi
    done

    echo -e "${C_YELLOW}Reached max iterations (${MAX_ITERATIONS})${C_RESET}"
    save_session
}

# ── Entry point ─────────────────────────────────────────────────────────────
check_ollama

if [[ -n "$SINGLE_PROMPT" ]]; then
    run_agent "$SINGLE_PROMPT"
else
    echo -e "${C_BOLD}shell-agent${C_RESET} - local coding assistant"
    echo -e "${C_DIM}Commands: /clear (new session), /plan (toggle plan mode), /undo (revert), /history (show context), quit to exit${C_RESET}"
    echo ""

    # Try to resume previous session (unless --fresh)
    if [[ "$FRESH_SESSION" -eq 0 ]] && load_session 2>/dev/null; then
        echo -e "${C_DIM}(resumed previous session with ${#OLLAMA_MESSAGES[@]} messages)${C_RESET}"
        echo ""
    fi

    while true; do
        echo -ne "${C_GREEN}▸ ${C_RESET}"
        read -r input || break
        [[ -z "$input" ]] && continue
        [[ "$input" == "quit" || "$input" == "exit" || "$input" == "q" ]] && break

        # Handle built-in commands
        if [[ "$input" == "/clear" || "$input" == "/fresh" ]]; then
            clear_session
            echo -e "${C_DIM}(session cleared)${C_RESET}"
            continue
        fi
        if [[ "$input" == "/plan" ]]; then
            if [[ "$AGENT_MODE" == "plan" ]]; then
                AGENT_MODE="build"
                echo -e "${C_DIM}(switched to build mode — full tool access)${C_RESET}"
            else
                AGENT_MODE="plan"
                echo -e "${C_YELLOW}(switched to plan mode — read-only, no edits)${C_RESET}"
            fi
            continue
        fi
        if [[ "$input" == "/undo" ]]; then
            if [[ -f "${LAST_SESSION_FILE}" ]]; then
                cp "${LAST_SESSION_FILE}" "${SESSION_FILE}"
                load_session 2>/dev/null
                echo -e "${C_DIM}(restored previous session state)${C_RESET}"
            else
                echo -e "${C_DIM}(nothing to undo)${C_RESET}"
            fi
            continue
        fi
        if [[ "$input" == "/history" ]]; then
            echo -e "${C_DIM}Session messages: ${#OLLAMA_MESSAGES[@]}${C_RESET}"
            local_count=0
            for m in "${OLLAMA_MESSAGES[@]}"; do
                local role
                role=$(echo "$m" | jq -r '.role' 2>/dev/null)
                local preview
                preview=$(echo "$m" | jq -r '.content // ""' 2>/dev/null | head -c 60)
                echo -e "${C_DIM}  [$((++local_count))] ${role}: ${preview}...${C_RESET}"
            done
            continue
        fi
        if [[ "$input" == "/restart" ]]; then
            echo -e "${C_DIM}Restarting Ollama...${C_RESET}"
            pkill ollama 2>/dev/null; sleep 1
            if start_ollama; then
                echo -e "${C_GREEN}Ollama restarted${C_RESET}"
            else
                echo -e "${C_RED}Failed to restart Ollama${C_RESET}"
            fi
            continue
        fi

        # Backup session before running (for /undo)
        if [[ -f "${SESSION_FILE}" ]]; then
            cp "${SESSION_FILE}" "${LAST_SESSION_FILE}" 2>/dev/null || true
        fi

        run_agent "$input"
        echo ""
    done

    echo -e "${C_DIM}Bye${C_RESET}"
fi
