#!/usr/bin/env bash
# bump-version.sh — increments the patch segment of NetMapServer/VERSION
# Usage: ./bump-version.sh [major|minor|patch]   (default: patch)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/VERSION"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "ERROR: $VERSION_FILE not found" >&2; exit 1
fi

current=$(tr -d '[:space:]' < "$VERSION_FILE")
IFS='.' read -r major minor patch <<< "$current"

segment="${1:-patch}"
case "$segment" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
  *) echo "Usage: $0 [major|minor|patch]" >&2; exit 1 ;;
esac

new_version="$major.$minor.$patch"
printf '%s\n' "$new_version" > "$VERSION_FILE"
echo "Bumped: $current \u2192 $new_version"

# Sync WEB_VERSION in Public/app.js
APP_JS="$SCRIPT_DIR/Public/app.js"
if [[ -f "$APP_JS" ]]; then
  sed -i.bak "s/const WEB_VERSION = '[^']*'/const WEB_VERSION = '$new_version'/" "$APP_JS" && rm -f "$APP_JS.bak"
fi

# Sync ?v= cache-buster query strings in Public/index.html so browsers
# always fetch the latest JS/CSS after a deploy (pairs with the Caddyfile
# long-lived Cache-Control header set on *.js and *.css).
INDEX_HTML="$SCRIPT_DIR/Public/index.html"
if [[ -f "$INDEX_HTML" ]]; then
  sed -i.bak \
    -e "s/style\.css?v=[^\"']*/style.css?v=$new_version/g" \
    -e "s/app\.js?v=[^\"']*/app.js?v=$new_version/g" \
    "$INDEX_HTML" && rm -f "$INDEX_HTML.bak"
fi
