#!/bin/bash
# Scan the files that would be committed for personal data and secrets:
# private IPs, MAC addresses, UUIDs (account/client ids), Dyson serials,
# AWS IoT endpoints, tokens, email addresses and home-folder paths.
#   scripts/check-secrets.sh                 scan the repo (exit 1 on findings)
#   scripts/check-secrets.sh <dir>           scan any folder
#   scripts/check-secrets.sh --install-hook  also run it before every commit
# A line that must keep a match can carry the marker "secret-scan: allow".
set -euo pipefail
target=""
if [[ -n "${1:-}" && "$1" != --* ]]; then target=$(cd "$1" && pwd); fi
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--install-hook" ]]; then
    hook=.git/hooks/pre-commit
    printf '#!/bin/bash\nexec scripts/check-secrets.sh\n' > "$hook"
    chmod +x "$hook"
    echo "installed $hook"
    exit 0
fi

PATTERNS=(
    'private IPv4|\b(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b'
    'MAC address|\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b'
    'UUID|\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'
    'Dyson serial|\b[A-Z0-9]{3}-[A-Z]{2}-[A-Z0-9]{8}\b'
    'AWS IoT endpoint|[a-z0-9]{10,}-ats\.iot\.'
    'bearer token|Bearer [A-Za-z0-9._~+/-]{20,}'
    'token value|"(token|TokenSignature|TokenValue|apPasswordHash)" *: *"[^"<]{16,}"'
    'long base64|[A-Za-z0-9+/]{40,}={1,2}|[A-Za-z0-9+]{48,}'
    'email address|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
    'home folder path|/Users/[A-Za-z0-9._-]+/'
)
# Synthetic values used by the tests and docs.
ALLOW='secret-scan: allow|TST-EU-|@example\.com|noreply@|/Users/<'

if [[ -n "$target" ]]; then
    cd "$target"
    files=$(find . -type f -not -path './.git/*' | sed 's|^\./||')
elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    files=$(git ls-files -co --exclude-standard)
else
    files=$(find . -type f -not -path './.git/*' -not -path './build/*' | sed 's|^\./||')
fi

out=$(mktemp)
trap 'rm -f "$out"' EXIT
for entry in "${PATTERNS[@]}"; do
    label=${entry%%|*}
    regex=${entry#*|}
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        grep -IEn "$regex" "$file" 2>/dev/null | grep -Ev "$ALLOW" | while IFS= read -r hit; do
            echo "[$label] $file:$hit"
        done
    done <<< "$files"
done > "$out" || true

if [[ -s "$out" ]]; then
    cat "$out"
    echo "check-secrets: possible personal data or secrets found (see above)." >&2
    exit 1
fi
echo "check-secrets: clean ($(echo "$files" | grep -c .) files)"
