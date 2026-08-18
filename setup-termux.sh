#!/usr/bin/env bash
# ── Termux setup for shell-agent on Android ──────────────────────────────────
# Run this once in Termux to install everything needed.
#
# Usage:
#   bash setup-termux.sh [model]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Ensure ~/.local/bin is always in PATH
export PATH="${HOME}/.local/bin:$PATH"

MODEL="${1:-qwen2.5-coder:1.5b}"

GREEN='\033[32m'
CYAN='\033[36m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

info()  { echo -e "${CYAN}▸${RESET} $*"; }
ok()    { echo -e "${GREEN}✔${RESET} $*"; }
warn()  { echo -e "${YELLOW}⚠${RESET} $*"; }
err()   { echo -e "${RED}✖${RESET} $*" >&2; }

# ── 1. System dependencies ──────────────────────────────────────────────────
info "Installing system dependencies..."
pkg update -y
pkg install -y \
    curl jq git \
    python nodejs \
    clang make \
    openssh \
    termux-api 2>/dev/null || true

ok "System packages installed"

# ── 2. Install Ollama (no sudo, user-level) ────────────────────────────────
OLLAMA_BIN="${HOME}/.local/bin/ollama"
mkdir -p "${HOME}/.local/bin"

if command -v ollama &>/dev/null || [[ -x "$OLLAMA_BIN" ]]; then
    ok "Ollama already installed"
else
    info "Downloading Ollama for aarch64-linux..."

    # Detect architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64) OLLAMA_ARCH="arm64" ;;
        armv7l|armhf)  OLLAMA_ARCH="arm" ;;
        x86_64)        OLLAMA_ARCH="amd64" ;;
        *)             err "Unsupported architecture: $ARCH"; exit 1 ;;
    esac

    OLLAMA_VERSION=$(curl -fsSL https://api.github.com/repos/ollama/ollama/releases/latest | jq -r '.tag_name' 2>/dev/null || echo "latest")
    DOWNLOAD_URL="https://github.com/ollama/ollama/releases/latest/download/ollama-linux-${OLLAMA_ARCH}"

    info "Fetching: ${DOWNLOAD_URL}"
    curl -fsSL -o "${OLLAMA_BIN}" "${DOWNLOAD_URL}"
    chmod +x "${OLLAMA_BIN}"

    # Make sure ~/.local/bin is in PATH
    if ! echo "$PATH" | grep -q "${HOME}/.local/bin"; then
        export PATH="${HOME}/.local/bin:$PATH"
    fi

    ok "Ollama installed to ${OLLAMA_BIN}"
fi

# ── 3. Configure storage ────────────────────────────────────────────────────
info "Requesting storage access..."
termux-setup-storage 2>/dev/null || warn "termux-setup-storage failed (may already be configured)"
ok "Storage access configured"

# ── 4. Start Ollama and pull model ──────────────────────────────────────────
info "Starting Ollama server..."
"${OLLAMA_BIN}" serve &>/dev/null &
OLLAMA_PID=$!
sleep 3

# Check if it started
if curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
    ok "Ollama server running (PID: ${OLLAMA_PID})"
else
    # Try starting with nohup
    nohup "${OLLAMA_BIN}" serve &>/dev/null &
    sleep 5
    if curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
        ok "Ollama server running"
    else
        err "Could not start Ollama. Try: ollama serve"
    fi
fi

info "Pulling model: ${MODEL} (may take a while on first run)..."
"${OLLAMA_BIN}" pull "${MODEL}"
ok "Model ready: ${MODEL}"

# ── 5. Install the agent ────────────────────────────────────────────────────
INSTALL_DIR="${HOME}/shell-agent"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

info "Installing shell-agent to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
cp -r "${SCRIPT_DIR}/lib" "${INSTALL_DIR}/"
cp -r "${SCRIPT_DIR}/tools" "${INSTALL_DIR}/"
cp "${SCRIPT_DIR}/agent.sh" "${INSTALL_DIR}/"
chmod +x "${INSTALL_DIR}/agent.sh"

# ── 6. Create convenience aliases ───────────────────────────────────────────
ALIAS_FILE="${HOME}/.bashrc"
MARKER="# shell-agent aliases"

if ! grep -q "$MARKER" "$ALIAS_FILE" 2>/dev/null; then
    cat >> "$ALIAS_FILE" <<EOF

${MARKER}
export PATH="\${HOME}/.local/bin:\$PATH"
alias agent='${INSTALL_DIR}/agent.sh'
alias ollama='${OLLAMA_BIN}'
alias ollama-start='${OLLAMA_BIN} serve &'
alias ollama-stop='pkill ollama'
alias ollama-models='curl -s http://127.0.0.1:11434/api/tags | jq -r ".models[].name"'
EOF
    ok "Added aliases to .bashrc"
fi

# ── 7. Create systemd-style startup ─────────────────────────────────────────
STARTUP_FILE="${HOME}/.termux/boot/start-ollama.sh"
mkdir -p "$(dirname "$STARTUP_FILE")"
cat > "$STARTUP_FILE" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
export PATH="\${HOME}/.local/bin:\$PATH"
termux-wake-lock
${OLLAMA_BIN} serve &>/dev/null &
EOF
chmod +x "$STARTUP_FILE"
ok "Boot script created (Ollama starts on device boot)"

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}  shell-agent installed on Termux!${RESET}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo "  Model:     ${MODEL}"
echo "  Install:   ${INSTALL_DIR}"
echo ""
echo "  Start Ollama:"
echo "    ollama serve &"
echo ""
echo "  Run agent:"
echo "    agent                          # interactive"
echo "    agent \"write hello world\"     # single prompt"
echo ""
echo "  Aliases (run: source ~/.bashrc):"
echo "    agent, ollama, ollama-start, ollama-stop, ollama-models"
echo ""
echo "  For 'termux-api' boot support:"
echo "    pkg install termux-api"
echo "    (enable 'Run at Boot' in Termux:Boot app)"
echo ""
