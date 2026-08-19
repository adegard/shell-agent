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
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model) OLLAMA_MODEL="$2"; shift 2 ;;
        -d|--debug) export DEBUG=1; shift ;;
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
            echo "Usage: agent.sh [-m model] [-d] [-t] [prompt]"
            echo "  -m, --model   Override Ollama model"
            echo "  -d, --debug   Show debug output"
            echo "  -t, --test    Test Ollama connection"
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
check_ollama() {
    if ! curl -sf "${OLLAMA_HOST}/api/tags" &>/dev/null; then
        echo -e "${C_RED}Ollama is not running at ${OLLAMA_HOST}${C_RESET}"
        echo ""
        echo "Start it with:"
        echo "  ollama serve &"
        echo ""
        echo "Or install Ollama:"
        echo "  curl -fsSL https://ollama.com/install.sh | sh"
        exit 1
    fi

    # Check model exists
    local models
    models=$(curl -sf "${OLLAMA_HOST}/api/tags" | jq -r '.models[].name' 2>/dev/null)
    if ! echo "$models" | grep -q "$OLLAMA_MODEL"; then
        echo -e "${C_YELLOW}Model '${OLLAMA_MODEL}' not found.${C_RESET}"
        echo ""
        echo "Available models:"
        echo "$models" | sed 's/^/  /'
        echo ""
        echo "Pull it with: ollama pull ${OLLAMA_MODEL}"
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
run_agent() {
    local user_input="$1"

    echo -e "${C_BOLD}${C_CYAN}shell-agent${C_RESET} ${C_DIM}v${AGENT_VERSION}${C_RESET}"
    echo -e "${C_DIM}model: ${OLLAMA_MODEL} | workspace: ${WORKSPACE}${C_RESET}"
    echo ""

    build_tools_json
    OLLAMA_MESSAGES=()
    add_message "system" "$(get_system_prompt)"
    add_message "user" "$user_input"

    local iteration=0
    local last_tool=""
    local repeat_count=0
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

            # ── Loop detection: same tool called 3+ times → break ──
            local call_sig="${tname}:${targs}"
            if [[ "$call_sig" == "$last_tool" ]]; then
                repeat_count=$((repeat_count + 1))
                if (( repeat_count >= 2 )); then
                    echo -e "${C_YELLOW}(model stuck in loop, forcing summary)${C_RESET}"
                    add_message "assistant" "$content"
                    add_message "user" "You already called this tool and got the result. Now respond with a text summary of what you found. Do NOT call any more tools."
                    # Get final text response
                    local final_resp
                    final_resp=$(ollama_chat 2>&1)
                    local final_content
                    final_content=$(extract_content "$final_resp")
                    echo ""
                    echo -e "${C_GREEN}${final_content}${C_RESET}"
                    echo ""
                    return 0
                fi
            else
                last_tool="$call_sig"
                repeat_count=0
            fi

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

        else
            echo ""
            echo -e "${C_GREEN}${content}${C_RESET}"
            echo ""

            # Log the exchange
            printf '{"ts":"%s","input":"%s","iterations":%d}\n' \
                "$(date -Iseconds)" "$user_input" "$iteration" \
                >> "${HISTORY_FILE}"

            return 0
        fi
    done

    echo -e "${C_YELLOW}Reached max iterations (${MAX_ITERATIONS})${C_RESET}"
}

# ── Entry point ─────────────────────────────────────────────────────────────
check_ollama

if [[ -n "$SINGLE_PROMPT" ]]; then
    run_agent "$SINGLE_PROMPT"
else
    echo -e "${C_BOLD}shell-agent${C_RESET} - local coding assistant"
    echo -e "${C_DIM}Type your request, or 'quit' to exit${C_RESET}"
    echo ""

    while true; do
        echo -ne "${C_GREEN}▸ ${C_RESET}"
        read -r input || break
        [[ -z "$input" ]] && continue
        [[ "$input" == "quit" || "$input" == "exit" || "$input" == "q" ]] && break

        run_agent "$input"
        echo ""
    done

    echo -e "${C_DIM}Bye${C_RESET}"
fi
