#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# Registers the Telegram webhook for a deployed prism-hubot instance.
#
#   sudo deploy/set-webhook.sh prism.example.org
#
# This is a one-time action against Telegram, not a release step. Rerun it only
# when the public hostname or PRISM_BOT_TELEGRAM_WEBHOOK_SECRET changes. The
# token is read from the deployed .env and never appears in an argument, so it
# does not reach the process list or the shell history.

set -euo pipefail

PUBLIC_HOST="${1:-${PUBLIC_HOST:-}}"
ENV_FILE="${ENV_FILE:-/srv/prism-hubot/shared/.env}"
WEBHOOK_PATH="${WEBHOOK_PATH:-/telegram/webhook}"

if [ -z "$PUBLIC_HOST" ]; then
  echo "Usage: $0 <public-host>" >&2
  exit 1
fi

if [ ! -r "$ENV_FILE" ]; then
  echo "Cannot read $ENV_FILE. Set ENV_FILE, or run this as a user that can." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${PRISM_BOT_TELEGRAM_TOKEN:?not set in $ENV_FILE}"
: "${PRISM_BOT_TELEGRAM_WEBHOOK_SECRET:?not set in $ENV_FILE}"

case "$PRISM_BOT_TELEGRAM_TOKEN" in
  replace-with-*) echo "$ENV_FILE still holds the placeholder token." >&2; exit 1 ;;
esac
case "$PRISM_BOT_TELEGRAM_WEBHOOK_SECRET" in
  replace-with-*) echo "$ENV_FILE still holds the placeholder webhook secret." >&2; exit 1 ;;
esac

api="https://api.telegram.org/bot$PRISM_BOT_TELEGRAM_TOKEN"
url="https://$PUBLIC_HOST$WEBHOOK_PATH"

echo "Registering $url"
curl -fsS "$api/setWebhook" \
  --data-urlencode "url=$url" \
  --data-urlencode "secret_token=$PRISM_BOT_TELEGRAM_WEBHOOK_SECRET"
echo

echo "Current webhook state:"
curl -fsS "$api/getWebhookInfo"
echo
