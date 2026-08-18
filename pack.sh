#!/usr/bin/env bash
# Pack shell-agent into a tar.gz for easy transfer to your phone
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${SCRIPT_DIR}/shell-agent.tar.gz"
tar -czf "$OUTPUT" -C "$(dirname "$SCRIPT_DIR")" shell-agent
echo "Packed: ${OUTPUT}"
echo "Transfer to phone:"
echo "  scp ${OUTPUT} yourphone:~/storage/downloads/"
echo "  # Then in Termux:"
echo "  cd ~/storage/downloads && tar xzf shell-agent.tar.gz && bash shell-agent/setup-termux.sh"
