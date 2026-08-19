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
    zstd \
    termux-api 2>/dev/null || true

ok "System packages installed"

# ── 2. Install Ollama (no sudo, user-level) ────────────────────────────────
OLLAMA_BIN="${HOME}/.local/bin/ollama"
mkdir -p "${HOME}/.local/bin"

if command -v ollama &>/dev/null; then
    OLLAMA_BIN="$(command -v ollama)"
    ok "Ollama already installed at ${OLLAMA_BIN}"
elif [[ -x "$OLLAMA_BIN" ]]; then
    ok "Ollama already installed at ${OLLAMA_BIN}"
else
    # Method 1: Try Termux package
    if pkg install -y ollama 2>/dev/null; then
        if command -v ollama &>/dev/null; then
            OLLAMA_BIN="$(command -v ollama)"
            ok "Ollama installed via pkg at ${OLLAMA_BIN}"
        fi
    fi

    # Method 2: Download binary from GitHub releases
    if ! command -v ollama &>/dev/null && ! [[ -x "$OLLAMA_BIN" ]]; then
        ARCH=$(uname -m)
        case "$ARCH" in
            aarch64|arm64) OLLAMA_ARCH="arm64" ;;
            armv7l|armhf)  OLLAMA_ARCH="arm" ;;
            x86_64)        OLLAMA_ARCH="amd64" ;;
            *)             err "Unsupported architecture: $ARCH"; exit 1 ;;
        esac

        DOWNLOAD_URL=$(curl -fsSL https://api.github.com/repos/ollama/ollama/releases/latest \
            | jq -r --arg arch "$OLLAMA_ARCH" '
                .assets[] | select(.name == "ollama-linux-\($arch).tar.zst") | .browser_download_url
            ' 2>/dev/null)

        if [[ -z "$DOWNLOAD_URL" ]]; then
            err "Could not find Ollama download for: ${OLLAMA_ARCH}"
            exit 1
        fi

        # Ensure wget and zstd are available
        pkg install -y wget zstd 2>/dev/null || true

        OLLAMA_DL_DIR="${HOME}/.local/share/ollama-dl"
        mkdir -p "${OLLAMA_DL_DIR}"
        ARCHIVE="${OLLAMA_DL_DIR}/ollama.tar.zst"

        # Download with resume support (handles connection drops)
        info "Downloading Ollama (~2GB, uses resume on retry)..."
        info "URL: ${DOWNLOAD_URL}"
        for attempt in 1 2 3 4 5; do
            info "Attempt ${attempt}/5..."
            if wget -c --tries=2 --timeout=60 \
                --progress=dot:giga \
                -O "${ARCHIVE}" "${DOWNLOAD_URL}" 2>&1; then
                break
            fi
            warn "Download interrupted on attempt ${attempt}, resuming..."
            sleep 2
        done

        if [[ ! -s "${ARCHIVE}" ]]; then
            err "Download failed after 5 attempts"
            err "You can manually download and place ollama binary in ~/.local/bin/"
            exit 1
        fi

        info "Extracting..."
        TMPDIR=$(mktemp -d)
        zstd -d "${ARCHIVE}" -o "${TMPDIR}/ollama.tar" 2>/dev/null
        tar -xf "${TMPDIR}/ollama.tar" -C "${TMPDIR}"

        OLLAMA_FOUND=$(find "${TMPDIR}" -name "ollama" -type f 2>/dev/null | head -1)
        if [[ -z "$OLLAMA_FOUND" ]]; then
            err "Could not find ollama binary in archive"
            ls -la "${TMPDIR}" 2>/dev/null
            rm -rf "${TMPDIR}"
            exit 1
        fi

        mv "${OLLAMA_FOUND}" "${OLLAMA_BIN}"
        chmod +x "${OLLAMA_BIN}"
        rm -rf "${TMPDIR}"
        ok "Ollama installed to ${OLLAMA_BIN}"
    fi
fi

# Final check: make sure we have a working ollama binary
if ! command -v ollama &>/dev/null && ! [[ -x "$OLLAMA_BIN" ]]; then
    err "Ollama installation failed — binary not found"
    err "Try installing manually:"
    err "  pkg install ollama"
    err "  or download from https://github.com/ollama/ollama/releases"
    exit 1
fi
# Update OLLAMA_BIN if ollama is in PATH but not at our custom path
if command -v ollama &>/dev/null; then
    OLLAMA_BIN="$(command -v ollama)"
fi

# ── 3. Configure storage ────────────────────────────────────────────────────
if [[ -d "${HOME}/storage" ]]; then
    ok "Storage already configured"
else
    info "Requesting storage access..."
    yes | termux-setup-storage 2>/dev/null || warn "termux-setup-storage skipped"
    ok "Storage access configured"
fi

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
INSTALL_DIR="${HOME}/agent-shell"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve to absolute paths to check if same
INSTALL_DIR_REAL="$(cd "${INSTALL_DIR}" 2>/dev/null && pwd || echo "${INSTALL_DIR}")"
SCRIPT_DIR_REAL="$(cd "${SCRIPT_DIR}" 2>/dev/null && pwd || echo "${SCRIPT_DIR}")"

if [[ "${INSTALL_DIR_REAL}" == "${SCRIPT_DIR_REAL}" ]]; then
    ok "shell-agent already in place at ${INSTALL_DIR}"
else
    info "Installing shell-agent to ${INSTALL_DIR}..."
    mkdir -p "${INSTALL_DIR}"
    cp -r "${SCRIPT_DIR}/lib" "${INSTALL_DIR}/"
    cp -r "${SCRIPT_DIR}/tools" "${INSTALL_DIR}/"
    cp "${SCRIPT_DIR}/agent.sh" "${INSTALL_DIR}/"
    chmod +x "${INSTALL_DIR}/agent.sh"
fi

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
