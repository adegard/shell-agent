#!/usr/bin/env bash
# ── Configuration ────────────────────────────────────────────────────────────

AGENT_NAME="shell-agent"
AGENT_VERSION="0.1.0"

# Ollama settings
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:1.5b}"
OLLAMA_TIMEOUT="${OLLAMA_TIMEOUT:-300}"

# Paths
AGENT_DIR="${HOME}/.shell-agent"
WORKSPACE="${PWD}"
HISTORY_FILE="${AGENT_DIR}/history.jsonl"
LOG_FILE="${AGENT_DIR}/agent.log"

# Limits
MAX_ITERATIONS=15
MAX_OUTPUT_LINES=200
MAX_OUTPUT_BYTES=51200
CONTEXT_WINDOW=4096

# Colors
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_RED='\033[31m'
    C_GREEN='\033[32m'
    C_YELLOW='\033[33m'
    C_BLUE='\033[34m'
    C_CYAN='\033[36m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi

mkdir -p "${AGENT_DIR}"
