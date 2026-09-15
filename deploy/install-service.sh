#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# Installs the prism-hubot systemd unit on the VPS. Run it once, as root, on the
# deployment host before the first `Deploy` workflow run. See docs/deploy.md.
#
#   sudo DEPLOY_PATH=/srv/prism-hubot DEPLOY_USER=prism ./deploy/install-service.sh
#
# Re-running the script is safe: it rewrites the unit and reloads systemd.

set -euo pipefail

DEPLOY_PATH="${DEPLOY_PATH:-/srv/prism-hubot}"
DEPLOY_USER="${DEPLOY_USER:-prism}"
BIND_ADDRESS="${BIND_ADDRESS:-127.0.0.1}"
PORT="${PORT:-9292}"
BUNDLE_BIN="${BUNDLE_BIN:-}"
UNIT_NAME="${UNIT_NAME:-prism-hubot.service}"
INSTALL_SUDOERS="${INSTALL_SUDOERS:-yes}"

template="$(dirname "$0")/prism-hubot.service"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this script as root (systemd units live under /etc/systemd/system)." >&2
  exit 1
fi

case "$DEPLOY_PATH" in
  /*) ;;
  *) echo "DEPLOY_PATH must be an absolute path." >&2; exit 1 ;;
esac

if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  echo "Deploy user '$DEPLOY_USER' does not exist. Create it first." >&2
  exit 1
fi

if [ -z "$BUNDLE_BIN" ]; then
  BUNDLE_BIN="$(su -s /bin/sh -c 'command -v bundle' "$DEPLOY_USER" || true)"
fi
if [ -z "$BUNDLE_BIN" ]; then
  echo "Could not find 'bundle' on the PATH of '$DEPLOY_USER'." >&2
  echo "Install bundler for that user, or set BUNDLE_BIN to its absolute path." >&2
  exit 1
fi

test -f "$template"

sed \
  -e "s|__DEPLOY_PATH__|$DEPLOY_PATH|g" \
  -e "s|__DEPLOY_USER__|$DEPLOY_USER|g" \
  -e "s|__BUNDLE_BIN__|$BUNDLE_BIN|g" \
  -e "s|__BIND_ADDRESS__|$BIND_ADDRESS|g" \
  -e "s|__PORT__|$PORT|g" \
  "$template" > "/etc/systemd/system/$UNIT_NAME"
chmod 644 "/etc/systemd/system/$UNIT_NAME"

if [ "$INSTALL_SUDOERS" = "yes" ]; then
  sudoers_file="/etc/sudoers.d/prism-hubot-deploy"
  printf '%s ALL=(root) NOPASSWD: /bin/systemctl restart %s, /usr/bin/systemctl restart %s\n' \
    "$DEPLOY_USER" "$UNIT_NAME" "$UNIT_NAME" > "$sudoers_file"
  chmod 440 "$sudoers_file"
  if command -v visudo >/dev/null 2>&1 && ! visudo -cf "$sudoers_file" >/dev/null; then
    rm -f "$sudoers_file"
    echo "Generated sudoers drop-in was rejected by visudo; removed it." >&2
    exit 1
  fi
fi

systemctl daemon-reload
systemctl enable "$UNIT_NAME"

echo "Installed /etc/systemd/system/$UNIT_NAME"
echo "Deployment path: $DEPLOY_PATH"
echo "Service user:    $DEPLOY_USER"
echo "Listening on:    $BIND_ADDRESS:$PORT"
echo
echo "The unit is enabled but not started: it needs $DEPLOY_PATH/current, which the"
echo "Deploy workflow creates. Run Deploy, then check 'systemctl status $UNIT_NAME'."
