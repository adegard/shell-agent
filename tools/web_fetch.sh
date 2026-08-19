#!/usr/bin/env bash
# ── web_fetch tool (curl) ────────────────────────────────────────────────────

tool_web_fetch() {
    local url="$1"
    local format="${2:-text}"

    if [[ -z "$url" ]]; then
        echo "ERROR: No URL provided"
        return 1
    fi

    # Add https:// if no scheme
    [[ "$url" != http* ]] && url="https://${url}"

    local output
    if [[ "$format" == "html" ]]; then
        output=$(curl -sL --max-time 30 \
            -H "User-Agent: Mozilla/5.0 (Linux; Android) AppleWebKit/537.36" \
            "$url" 2>&1) || true
        # Strip HTML tags for readability
        output=$(echo "$output" | sed 's/<script[^>]*>.*<\/script>//g; s/<style[^>]*>.*<\/style>//g; s/<[^>]*>//g; s/&nbsp;/ /g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g' | sed '/^[[:space:]]*$/d' | head -n 200)
    else
        output=$(curl -sL --max-time 30 \
            -H "User-Agent: Mozilla/5.0 (Linux; Android) AppleWebKit/537.36" \
            "$url" 2>&1) || true
        # Plain text: strip HTML
        output=$(echo "$output" | sed 's/<[^>]*>//g; s/&nbsp;/ /g; s/&amp;/\&/g' | sed '/^[[:space:]]*$/d' | head -n 200)
    fi

    echo "URL: ${url}"
    echo "CONTENT:"
    echo "$output"
}
