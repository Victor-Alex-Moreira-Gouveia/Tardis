#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ "$EUID" -ne 0 ]]; then
  echo "Execute como root: sudo $0" >&2
  exit 1
fi

read -r -s -p "Cole a Incoming Webhook de #tardis-backups (a entrada fica oculta): " SLACK_WEBHOOK_URL
printf '\n'

case "$SLACK_WEBHOOK_URL" in
  https://hooks.slack.com/services/*) ;;
  *)
    echo "URL inválida. Use uma Incoming Webhook Slack do domínio hooks.slack.com." >&2
    exit 1
    ;;
esac

if ! SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL" python3 - <<'PY'
import json
import os
import urllib.request

payload = {
    "text": "🔔 Tardis: avisos semanais de backup conectados ao canal #tardis-backups."
}
request = urllib.request.Request(
    os.environ["SLACK_WEBHOOK_URL"],
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=20) as response:
    if response.status != 200 or response.read().decode("utf-8").strip() != "ok":
        raise SystemExit("Slack recusou a mensagem de teste")
PY
then
  unset SLACK_WEBHOOK_URL
  echo "Não foi possível enviar a mensagem de teste; a configuração anterior foi mantida." >&2
  exit 1
fi

TEMP_FILE="$(mktemp /etc/tardis-backup.env.XXXXXX)"
printf 'SLACK_WEBHOOK_URL=%s\n' "$SLACK_WEBHOOK_URL" > "$TEMP_FILE"
chown root:root "$TEMP_FILE"
chmod 0600 "$TEMP_FILE"
mv -f "$TEMP_FILE" /etc/tardis-backup.env
unset SLACK_WEBHOOK_URL

echo "Webhook validada e salva com permissão exclusiva para root."
