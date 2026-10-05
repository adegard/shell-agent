#!/usr/bin/env bash
# ── Linux setup for shell-agent ──────────────────────────────────────────────
# Run this once in a terminal to install everything needed.
#
# Usage:
#   bash setup-linux.sh                    # default model qwen2.5-coder:3b
#   bash setup-linux.sh qwen2.5-coder:7b   # custom model
#   bash setup-linux.sh --cloud-only       # skip Ollama, just install agent
#   bash setup-linux.sh --user             # no sudo, Ollama in ~/.local/bin
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Ensure ~/.local/bin is always in PATH
export PATH="${HOME}/.local/bin:$PATH"

MODEL=""
CLOUD_ONLY=0
USER_INSTALL=0

for arg in "$@"; do
    case "$arg" in
        -CloudOnly|--cloud-only)
            CLOUD_ONLY=1 ;;
        --user)
            USER_INSTALL=1 ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            echo "Unknown option: $arg" >&2
            exit 1 ;;
        *)
            MODEL="$arg" ;;
    esac
done

MODEL="${MODEL:-qwen2.5-coder:3b}"
OLLAMA_URL="http://127.0.0.1:11434"

GREEN='\033[32m'
CYAN='\033[36m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

info()  { echo -e "${CYAN}▸${RESET} $*"; }
ok()    { echo -e "${GREEN}✔${RESET} $*"; }
warn()  { echo -e "${YELLOW}⚠${RESET} $*"; }
err()   { echo -e "${RED}✖${RESET} $*" >&2; }

# ── 1. Detect package manager ───────────────────────────────────────────────
PKG_MGR="none"
for pm in apt-get dnf pacman zypper apk; do
    if command -v "$pm" &>/dev/null; then
        PKG_MGR="$pm"
        break
    fi
done

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo &>/dev/null; then
        SUDO="sudo"
    elif [[ "${USER_INSTALL}" -eq 0 ]]; then
        err "No sudo found. Re-run as root, or use --user for a user-level install."
        exit 1
    else
        warn "No sudo found — using user-level installs only"
    fi
fi

install_pkgs() {
    case "$PKG_MGR" in
        apt-get)
            $SUDO apt-get update -y
            $SUDO apt-get install -y "$@" ;;
        dnf)
            $SUDO dnf install -y "$@" ;;
        pacman)
            $SUDO pacman -Sy --noconfirm "$@" ;;
        zypper)
            $SUDO zypper install -y "$@" ;;
        apk)
            $SUDO apk add --no-cache "$@" ;;
        *)
            return 1 ;;
    esac
}

if [[ "$PKG_MGR" == "none" ]]; then
    warn "Unknown package manager — install these yourself: curl jq git zstd ca-certificates"
else
    ok "Package manager: ${PKG_MGR}"
fi

# ── 2. System dependencies ──────────────────────────────────────────────────
MISSING=()
for cmd in curl jq git zstd tar; do
    command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done

if [[ "${#MISSING[@]}" -gt 0 ]]; then
    if [[ "$PKG_MGR" == "none" ]]; then
        err "Missing required commands: ${MISSING[*]}"
        err "Install them with your package manager and re-run."
        exit 1
    fi
    info "Installing system dependencies: ${MISSING[*]}"
    install_pkgs "${MISSING[@]}" ca-certificates || warn "Some packages failed to install"
fi

ok "System packages ready"

# jq is required by the agent itself — bail out if it is still missing
if ! command -v jq &>/dev/null; then
    err "jq is required by shell-agent but was not found"
    err "Install it with your package manager (apt install jq / dnf install jq / pacman -S jq)"
    exit 1
fi

# ── 3. Install Ollama ───────────────────────────────────────────────────────
OLLAMA_BIN="${HOME}/.local/bin/ollama"
mkdir -p "${HOME}/.local/bin"

if [[ "$CLOUD_ONLY" -eq 1 ]]; then
    warn "Cloud-only mode: skipping Ollama installation"
    OLLAMA_BIN=""
elif command -v ollama &>/dev/null; then
    OLLAMA_BIN="$(command -v ollama)"
    ok "Ollama already installed at ${OLLAMA_BIN}"
elif [[ -x "$OLLAMA_BIN" ]]; then
    ok "Ollama already installed at ${OLLAMA_BIN}"
elif [[ "$USER_INSTALL" -eq 0 ]]; then
    # Method 1: official installer (handles systemd unit + GPU libs)
    info "Installing Ollama via official installer..."
    if curl -fsSL https://ollama.com/install.sh | sh; then
        if command -v ollama &>/dev/null; then
            OLLAMA_BIN="$(command -v ollama)"
            ok "Ollama installed at ${OLLAMA_BIN}"
        else
            warn "Installer finished but ollama is not on PATH"
        fi
    else
        warn "Official installer failed, falling back to release tarball"
    fi
fi

# Method 2: user-level binary from GitHub releases (no sudo)
if [[ -z "${OLLAMA_BIN}" || ! -x "${OLLAMA_BIN}" ]] \
   && { command -v ollama &>/dev/null || [[ "$CLOUD_ONLY" -eq 0 ]]; }; then

    if command -v ollama &>/dev/null; then
        OLLAMA_BIN="$(command -v ollama)"
    else
        case "$(uname -m)" in
            aarch64|arm64) OLLAMA_ARCH="arm64" ;;
            x86_64)        OLLAMA_ARCH="amd64" ;;
            armv7l|armhf)  OLLAMA_ARCH="arm" ;;
            *) err "Unsupported architecture: $(uname -m)"; exit 1 ;;
        esac

        DOWNLOAD_URL=$(curl -fsSL https://api.github.com/repos/ollama/ollama/releases/latest \
            | jq -r --arg arch "$OLLAMA_ARCH" '
                .assets[] | select(.name == "ollama-linux-\($arch).tar.zst") | .browser_download_url
            ' 2>/dev/null)

        if [[ -z "$DOWNLOAD_URL" ]]; then
            err "Could not find Ollama download for: ${OLLAMA_ARCH}"
            err "Install manually from https://ollama.com/download"
            exit 1
        fi

        OLLAMA_DL_DIR="${HOME}/.local/share/ollama-dl"
        mkdir -p "${OLLAMA_DL_DIR}"
        ARCHIVE="${OLLAMA_DL_DIR}/ollama.tar.zst"

        info "Downloading Ollama (~2GB, resumes on retry)..."
        info "URL: ${DOWNLOAD_URL}"
        DOWNLOADED=0
        for attempt in 1 2 3 4 5; do
            info "Attempt ${attempt}/5..."
            if [[ -s "${ARCHIVE}" ]]; then
                curl -fL --retry 2 --retry-delay 2 -C - -o "${ARCHIVE}" "${DOWNLOAD_URL}" && DOWNLOADED=1
            else
                curl -fL --retry 2 --retry-delay 2 -o "${ARCHIVE}" "${DOWNLOAD_URL}" && DOWNLOADED=1
            fi
            if [[ "${DOWNLOADED}" -eq 1 ]]; then
                break
            fi
            warn "Download interrupted on attempt ${attempt}, resuming..."
            sleep 2
        done

        if [[ "${DOWNLOADED}" -eq 0 || ! -s "${ARCHIVE}" ]]; then
            err "Download failed after 5 attempts"
            err "You can manually download and place the ollama binary in ~/.local/bin/"
            exit 1
        fi

        info "Extracting..."
        TMPDIR=$(mktemp -d)
        zstd -dfq "${ARCHIVE}" -o "${TMPDIR}/ollama.tar"
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

# ── 4. Auto-start Ollama ────────────────────────────────────────────────────
# START_MODE: system | user | none — how Ollama should be (re)started on boot.
START_MODE="none"

if [[ -n "${OLLAMA_BIN}" ]]; then
    SYSTEM_UNIT=0
    if command -v systemctl &>/dev/null; then
        if systemctl is-enabled --quiet ollama.service 2>/dev/null \
           || systemctl is-active --quiet ollama.service 2>/dev/null; then
            SYSTEM_UNIT=1
        fi
    fi

    if [[ "${SYSTEM_UNIT}" -eq 1 ]]; then
        ok "Ollama system service enabled (starts on boot)"
        START_MODE="system"
    elif [[ "${EUID}" -ne 0 ]] && command -v systemctl &>/dev/null \
         && systemctl --user show-environment &>/dev/null 2>&1; then
        # User-level install: own unit, no sudo needed
        UNIT_FILE="${HOME}/.config/systemd/user/ollama.service"
        mkdir -p "$(dirname "$UNIT_FILE")"
        cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=${OLLAMA_BIN} serve
Environment="PATH=${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"
Environment="OLLAMA_HOST=127.0.0.1:11434"

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload || true
        if systemctl --user enable --now ollama.service >/dev/null 2>&1; then
            ok "Ollama systemd user service enabled (starts on login)"
            START_MODE="user"

            # Keep serving after logout
            if command -v loginctl &>/dev/null; then
                if loginctl enable-linger "$USER" 2>/dev/null; then
                    ok "Linger enabled (Ollama keeps running without an active session)"
                else
                    warn "Could not enable linger — Ollama stops when you log out"
                fi
            fi
        else
            rm -f "$UNIT_FILE"
            warn "Could not enable a systemd user service — Ollama will not auto-start"
        fi
    else
        warn "No systemd service available — start Ollama manually with: ollama serve &"
    fi
fi

# ── 5. Start Ollama and pull model ──────────────────────────────────────────
if [[ -n "${OLLAMA_BIN}" ]]; then
    info "Starting Ollama server..."
    if ! curl -sf "${OLLAMA_URL}/api/tags" &>/dev/null; then
        case "${START_MODE}" in
            system) systemctl restart ollama.service || warn "systemctl restart failed" ;;
            user)   systemctl --user restart ollama.service || warn "systemctl --user restart failed" ;;
            *)      nohup "${OLLAMA_BIN}" serve &>/dev/null & ;;
        esac
        sleep 3
    fi

    if curl -sf "${OLLAMA_URL}/api/tags" &>/dev/null; then
        ok "Ollama server running"
    else
        warn "Ollama is not responding. Start it manually with: ollama serve"
    fi

    info "Pulling model: ${MODEL} (may take a while on first run)..."
    "${OLLAMA_BIN}" pull "${MODEL}"
    ok "Model ready: ${MODEL}"
else
    MODEL="(cloud only)"
fi

# ── 6. Install the agent ────────────────────────────────────────────────────
INSTALL_DIR="${HOME}/shell-agent"
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

# ── 7. Create convenience aliases ───────────────────────────────────────────
MARKER="# shell-agent aliases"

write_rc() {
    local rc="$1"
    {
        echo ""
        echo "${MARKER}"
        echo 'export PATH="${HOME}/.local/bin:$PATH"'
        echo "alias agent='${INSTALL_DIR}/agent.sh'"
        if [[ -n "${OLLAMA_BIN}" ]] && ! command -v ollama &>/dev/null; then
            echo "alias ollama='${OLLAMA_BIN}'"
            echo "alias ollama-start='${OLLAMA_BIN} serve &'"
        fi
        echo "alias ollama-stop='pkill ollama'"
        echo "alias ollama-models='curl -s ${OLLAMA_URL}/api/tags | jq -r \".models[].name\"'"
        if [[ "$CLOUD_ONLY" -eq 0 ]]; then
            echo "export OLLAMA_MODEL=\"${MODEL}\""
        fi
        echo ""
    } >> "$rc"
}

for RC in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    [[ -f "$RC" ]] || continue
    if grep -q "$MARKER" "$RC" 2>/dev/null; then
        ok "$(basename "$RC") already configured"
        continue
    fi
    write_rc "$RC"
    ok "Added aliases to ${RC}"
done

if [[ ! -f "${HOME}/.bashrc" && ! -f "${HOME}/.zshrc" ]]; then
    warn "No ~/.bashrc or ~/.zshrc found — run the agent directly:"
    warn "  ${INSTALL_DIR}/agent.sh"
fi

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}  shell-agent installed on Linux!${RESET}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo "  Model:     ${MODEL}"
echo "  Install:   ${INSTALL_DIR}"
echo ""
if [[ "$CLOUD_ONLY" -eq 0 ]]; then
    echo "  Start Ollama:"
    echo "    ollama serve &"
    echo ""
fi
echo "  Run agent:"
echo "    agent                          # interactive"
echo "    agent \"write hello world\"     # single prompt"
echo ""
echo "  Reload shell (run: source ~/.bashrc):"
if [[ "$CLOUD_ONLY" -eq 0 ]]; then
    echo "    agent, ollama, ollama-start, ollama-stop, ollama-models"
else
    echo "    agent"
fi
echo ""
if [[ "$CLOUD_ONLY" -eq 1 ]]; then
    echo "  Cloud mode: set env vars for cloud API:"
    echo "    export CLOUD_API_KEY='sk-...'"
    echo "    export CLOUD_BASE_URL='https://api.openai.com/v1'"
    echo "    export CLOUD_MODEL='gpt-4o'"
    echo "    Then run: agent --cloud"
    echo ""
fi