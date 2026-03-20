#!/usr/bin/env bash
# set-release-version.sh — sets the SERVER version in the VERSION file.
# UI versioning is managed independently by set-ui-version.sh.
#
# Usage: ./set-release-version.sh <version>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/VERSION"

NEW_VERSION="${1:-}"
if [[ -z "$NEW_VERSION" ]]; then
  echo "Usage: $0 <version>" >&2
  exit 1
fi

printf '%s\n' "$NEW_VERSION" > "$VERSION_FILE"
echo "Release version set to: $NEW_VERSION"