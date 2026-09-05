#!/bin/bash
# Deprecated entrypoint — thin shim to the Bun organizer.
# Prefer: bun run organize [--dry-run] [limit]
set -euo pipefail

ORGANIZE_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.bun/bin:$PATH"

if [[ "${AI_ORGANIZE_QUIET_SHIM:-0}" != "1" ]]; then
  echo "ai-organize.sh is deprecated; use: bun run organize $*" >&2
fi

cd "$ORGANIZE_DIR"
exec bun run organize "$@"
