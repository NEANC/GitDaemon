#!/usr/bin/env bash
set -euo pipefail
CONFIG_DIR=${CONFIG_DIR:-/etc/git-mirror}
[ -f "$CONFIG_DIR/mirror.env" ] && . "$CONFIG_DIR/mirror.env"
SNAPSHOT=${HOSTS_SNAPSHOT:-${MIRROR_ROOT:-/srv/git-mirror}/github-hosts.snapshot}
URL=${HOSTS_URL:-https://api.github.com/meta}
mkdir -p "$(dirname "$SNAPSHOT")"
TMP=${SNAPSHOT}.tmp
curl --fail --silent --show-error --location "$URL" -o "$TMP"
mv -f "$TMP" "$SNAPSHOT"
printf '%s\n' "$SNAPSHOT"