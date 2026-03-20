#!/usr/bin/env bash
# set-ui-version.sh — sets the UI version independently of the server version.
# Updates Public/ui-version.json (fetched at runtime by the browser) and the
# cache-buster query strings in Public/index.html so browsers always pick up
# the latest JS/CSS after a UI-only deploy.
#
# Usage: ./set-ui-version.sh <version>
# Example: ./set-ui-version.sh 1.1.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UI_VERSION_FILE="$SCRIPT_DIR/Public/ui-version.json"
INDEX_HTML="$SCRIPT_DIR/Public/index.html"

NEW_VERSION="${1:-}"
if [[ -z "$NEW_VERSION" ]]; then
  echo "Usage: $0 <version>" >&2
  exit 1
fi

# Write ui-version.json (served as a static file; fetched by app.js at runtime)
printf '{"version": "%s"}\n' "$NEW_VERSION" > "$UI_VERSION_FILE"
echo "UI version set to: $NEW_VERSION"

# Update ?v= cache-buster query strings in index.html so browsers invalidate
# their long-lived JS/CSS cache on the next page load.
if [[ -f "$INDEX_HTML" ]]; then
  sed -i.bak \
    -e "s/style\.css?v=[^\"']*/style.css?v=$NEW_VERSION/g" \
    -e "s/app\.js?v=[^\"']*/app.js?v=$NEW_VERSION/g" \
    "$INDEX_HTML" && rm -f "$INDEX_HTML.bak"
  echo "Cache-busters in index.html updated to: $NEW_VERSION"
fi
