#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# One-time server preparation for prism-hubot. Idempotent: rerunning it after a
# dependency is installed or a value changes is the intended way to use it.
#
#   sudo DEPLOY_USER=deploy PUBLIC_HOST=prism.example.org deploy/bootstrap.sh
#
# It never writes shared/.env contents, never opens a firewall, and never
# touches DNS. Those stay operator decisions and are listed at the end.

set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_PATH="${DEPLOY_PATH:-/srv/prism-hubot}"
SERVICE="${SERVICE:-prism-hubot}"
APP_PORT="${APP_PORT:-9292}"
PUBLIC_HOST="${PUBLIC_HOST:-}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
warnings=()

warn() {
  warnings+=("$1")
  printf 'warning: %s\n' "$1" >&2
}

[ "$(id -u)" -eq 0 ] || { echo "Run this as root." >&2; exit 1; }
case "$DEPLOY_PATH" in
  /*) ;;
  *) echo "DEPLOY_PATH must be absolute." >&2; exit 1 ;;
esac

# --- deploy account ---------------------------------------------------------

if id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  echo "Account $DEPLOY_USER already exists, leaving it as it is."
else
  useradd --system --create-home --home-dir "/home/$DEPLOY_USER" \
    --shell /bin/bash --user-group "$DEPLOY_USER"
  echo "Created account $DEPLOY_USER."
fi

deploy_group="$(id -gn "$DEPLOY_USER")"
deploy_home="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"

install -d -o "$DEPLOY_USER" -g "$deploy_group" -m 700 "$deploy_home/.ssh"
if [ ! -e "$deploy_home/.ssh/authorized_keys" ]; then
  install -o "$DEPLOY_USER" -g "$deploy_group" -m 600 /dev/null \
    "$deploy_home/.ssh/authorized_keys"
  warn "$deploy_home/.ssh/authorized_keys is empty: add the public half of SSH_PRIVATE_KEY."
fi

# --- deployment root --------------------------------------------------------

install -d -o "$DEPLOY_USER" -g "$deploy_group" -m 755 "$DEPLOY_PATH"
install -d -o "$DEPLOY_USER" -g "$deploy_group" -m 755 "$DEPLOY_PATH/releases"
install -d -o "$DEPLOY_USER" -g "$deploy_group" -m 755 "$DEPLOY_PATH/shared"
install -d -o "$DEPLOY_USER" -g "$deploy_group" -m 755 "$DEPLOY_PATH/shared/bundle"
install -d -o "$DEPLOY_USER" -g "$deploy_group" -m 755 "$DEPLOY_PATH/shared/var"
install -d -o "$DEPLOY_USER" -g "$deploy_group" -m 700 \
  "$DEPLOY_PATH/shared/var/interaction-state"

if [ ! -f "$DEPLOY_PATH/shared/.env" ]; then
  install -o "$DEPLOY_USER" -g "$deploy_group" -m 600 "$here/../.env.example" \
    "$DEPLOY_PATH/shared/.env"
  warn "$DEPLOY_PATH/shared/.env was seeded from .env.example and still holds placeholders."
else
  chown "$DEPLOY_USER:$deploy_group" "$DEPLOY_PATH/shared/.env"
  chmod 600 "$DEPLOY_PATH/shared/.env"
fi

# --- restart permission -----------------------------------------------------

systemctl_path="$(command -v systemctl)"
sudoers_file="/etc/sudoers.d/$SERVICE"

if sudo -l -U "$DEPLOY_USER" 2>/dev/null | grep -Eq "NOPASSWD.*(ALL|systemctl)"; then
  echo "Account $DEPLOY_USER already has a passwordless systemctl grant, adding no rule."
else
  printf '%s ALL=(root) NOPASSWD: %s restart %s.service\n' \
    "$DEPLOY_USER" "$systemctl_path" "$SERVICE" > "$sudoers_file.tmp"
  chmod 0440 "$sudoers_file.tmp"
  if visudo -cf "$sudoers_file.tmp" >/dev/null; then
    mv "$sudoers_file.tmp" "$sudoers_file"
    echo "Installed $sudoers_file."
  else
    rm -f "$sudoers_file.tmp"
    echo "Generated sudoers rule was rejected by visudo." >&2
    exit 1
  fi
fi

# --- service unit -----------------------------------------------------------

bundle_path="$(sudo -u "$DEPLOY_USER" bash -lc 'command -v bundle' 2>/dev/null || true)"
if [ -z "$bundle_path" ]; then
  bundle_path="/usr/bin/bundle"
  warn "bundle was not found on ${DEPLOY_USER}'s PATH. The unit points at $bundle_path; install Ruby and Bundler, then rerun this script."
fi

sed \
  -e "s|@DEPLOY_USER@|$DEPLOY_USER|g" \
  -e "s|@DEPLOY_GROUP@|$deploy_group|g" \
  -e "s|@DEPLOY_PATH@|$DEPLOY_PATH|g" \
  -e "s|@BUNDLE@|$bundle_path|g" \
  -e "s|@APP_PORT@|$APP_PORT|g" \
  "$here/prism-hubot.service" > "/etc/systemd/system/$SERVICE.service"
chmod 644 "/etc/systemd/system/$SERVICE.service"
systemctl daemon-reload
echo "Installed /etc/systemd/system/$SERVICE.service."

if [ -L "$DEPLOY_PATH/current" ]; then
  systemctl enable "$SERVICE.service" >/dev/null
  echo "Enabled $SERVICE.service. Start it with: systemctl restart $SERVICE.service"
else
  warn "$DEPLOY_PATH/current does not exist yet, so $SERVICE.service was not enabled. Run the Deploy workflow once, then rerun this script."
fi

# --- reverse proxy ----------------------------------------------------------

if [ -n "$PUBLIC_HOST" ]; then
  if command -v caddy >/dev/null; then
    sed -e "s|@PUBLIC_HOST@|$PUBLIC_HOST|g" -e "s|@APP_PORT@|$APP_PORT|g" \
      "$here/Caddyfile" > /etc/caddy/Caddyfile
    if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
      systemctl reload caddy || systemctl restart caddy
      echo "Installed /etc/caddy/Caddyfile for $PUBLIC_HOST."
    else
      echo "Generated Caddyfile failed validation." >&2
      exit 1
    fi
  else
    warn "caddy is not installed, so no reverse proxy was configured. Install it, then rerun this script with the same PUBLIC_HOST."
  fi
else
  echo "PUBLIC_HOST is unset, skipping reverse proxy configuration."
fi

# --- what stays manual ------------------------------------------------------

cat <<SUMMARY

Done. Outside this machine, and therefore outside this script:

  - a DNS A record for the public hostname pointing at this server's IPv4 address;
  - inbound 443 (and the SSH port, for the Deploy workflow) allowed in the
    Hetzner Cloud firewall and in any host firewall;
  - GitHub repository secrets SSH_HOST, SSH_USER=$DEPLOY_USER,
    SSH_PRIVATE_KEY and SSH_DEPLOYMENT_PATH=$DEPLOY_PATH;
  - real values in $DEPLOY_PATH/shared/.env;
  - the Telegram webhook, registered with deploy/set-webhook.sh once the
    service answers.
SUMMARY

if [ ${#warnings[@]} -ne 0 ]; then
  echo
  echo "Unresolved on this host:"
  printf '  - %s\n' "${warnings[@]}"
  exit 1
fi
