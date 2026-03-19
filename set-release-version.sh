#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/VERSION"
APP_JS="$SCRIPT_DIR/Public/app.js"
INDEX_HTML="$SCRIPT_DIR/Public/index.html"

NEW_VERSION="${1:-}"
if [[ -z "$NEW_VERSION" ]]; then
  echo "Usage: $0 <version>" >&2
  exit 1
fi

printf '%s\n' "$NEW_VERSION" > "$VERSION_FILE"
echo "Release version set to: $NEW_VERSION"

if [[ -f "$APP_JS" ]]; then
  sed -i.bak "s/const WEB_VERSION = '[^']*'/const WEB_VERSION = '$NEW_VERSION'/" "$APP_JS" && rm -f "$APP_JS.bak"
fi

if [[ -f "$INDEX_HTML" ]]; then
  sed -i.bak \
    -e "s/style\.css?v=[^\"']*/style.css?v=$NEW_VERSION/g" \
    -e "s/app\.js?v=[^\"']*/app.js?v=$NEW_VERSION/g" \
    "$INDEX_HTML" && rm -f "$INDEX_HTML.bak"
fi