#!/usr/bin/env bash
set -Ee -o pipefail
umask 077

SERVICES_DIR="/home/vamg/Desktop/services"
SERVER_DIR="$SERVICES_DIR/server"
REPO_DIR="$SERVICES_DIR/Tardis-source-2026"
BACKUP_ROOT="/var/backups/tardis-weekly"
RETENTION_WEEKS=12
MIN_FREE_BYTES=$((10 * 1024 * 1024 * 1024))
STAMP="$(date '+%Y-%m-%d_%H-%M-%S%z')"
STAGING_DIR=""
GIT_BUNDLE_TMP=""
FINAL_DIR="$BACKUP_ROOT/tardis-weekly-$STAMP"
PHASE="initialization"
MAINTENANCE_CHANGED=0
N8N_STOPPED=0
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

notify_slack() {
  local message="$1"
  if [[ -z "$SLACK_WEBHOOK_URL" ]]; then
    log "Aviso Slack pendente: configure /etc/tardis-backup.env."
    return 0
  fi

  if SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL" SLACK_MESSAGE="$message" python3 - <<'PY'
import json
import os
import urllib.request

request = urllib.request.Request(
    os.environ["SLACK_WEBHOOK_URL"],
    data=json.dumps({"text": os.environ["SLACK_MESSAGE"]}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=20) as response:
    body = response.read().decode("utf-8").strip()
    if response.status != 200 or body != "ok":
        raise SystemExit("Slack recusou a mensagem")
PY
  then
    log "Notificação enviada ao Slack."
  else
    log "AVISO: o backup foi concluído, mas a notificação Slack falhou."
    return 1
  fi
}

finish() {
  local result=$?
  trap - EXIT
  set +e

  if [[ "$N8N_STOPPED" -eq 1 ]]; then
    docker start n8n_app >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
      log "n8n voltou a iniciar."
    else
      log "ERRO: não foi possível iniciar n8n_app automaticamente."
      result=1
    fi
  fi

  if [[ "$MAINTENANCE_CHANGED" -eq 1 ]]; then
    docker exec -u www-data nextcloud_app php occ maintenance:mode --off >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
      log "Modo de manutenção do Nextcloud desativado."
    else
      log "ERRO: não foi possível desativar o modo de manutenção do Nextcloud."
      result=1
    fi
  fi

  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    rm -rf -- "$STAGING_DIR"
  fi
  if [[ -n "$GIT_BUNDLE_TMP" && -e "$GIT_BUNDLE_TMP" ]]; then
    rm -f -- "$GIT_BUNDLE_TMP"
  fi

  if [[ "$result" -ne 0 ]]; then
    notify_slack "❌ Backup semanal do Tardis falhou em $(hostname) durante: $PHASE. Consulte o journal do serviço tardis-backup." || true
  fi
  exit "$result"
}
trap finish EXIT

if [[ "$EUID" -ne 0 ]]; then
  echo "Execute como root: sudo $0" >&2
  exit 1
fi

install -d -o root -g root -m 0700 "$BACKUP_ROOT"
exec 9>/run/lock/tardis-weekly-backup.lock
if ! flock -n 9; then
  log "Já existe uma execução de backup ativa; esta execução será encerrada."
  exit 0
fi

for command in docker tar gzip sha256sum python3 flock df awk git find sort du install mv tailscale runuser mktemp; do
  command -v "$command" >/dev/null || { log "Comando necessário não encontrado: $command"; exit 1; }
done

for file in \
  "$SERVER_DIR/.env" \
  "$SERVER_DIR/docker-compose.yml" \
  "$SERVER_DIR/nextcloud_data/config/config.php" \
  "$SERVER_DIR/n8n_data/database.sqlite" \
  "$REPO_DIR/docker-compose.yml" \
  "$REPO_DIR/tardis-production.override.yml" \
  "$REPO_DIR/nginx.production.conf"
do
  if [[ ! -e "$file" ]]; then
    log "Arquivo necessário ausente: $file"
    exit 1
  fi
done

for container in DB_Server nextcloud_app n8n_app; do
  if [[ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)" != "true" ]]; then
    log "Container necessário não está em execução: $container"
    exit 1
  fi
done

AVAILABLE_BYTES="$(df -PB1 "$BACKUP_ROOT" | awk 'NR == 2 {print $4}')"
if [[ "$AVAILABLE_BYTES" -lt "$MIN_FREE_BYTES" ]]; then
  log "Espaço insuficiente: são necessários pelo menos 10 GiB livres em $BACKUP_ROOT."
  exit 1
fi

docker exec DB_Server pg_isready -U root -d tardis_db >/dev/null
OCC_STATUS="$(docker exec -u www-data nextcloud_app php occ status --output=json)"
MAINTENANCE_STATE="$(printf '%s' "$OCC_STATUS" | python3 -c 'import json,sys; print(str(bool(json.load(sys.stdin).get("maintenance"))).lower())')"
if [[ "$MAINTENANCE_STATE" == "false" ]]; then
  PHASE="ativação da manutenção Nextcloud"
  docker exec -u www-data nextcloud_app php occ maintenance:mode --on
  MAINTENANCE_CHANGED=1
elif [[ "$MAINTENANCE_STATE" != "true" ]]; then
  log "Não foi possível determinar o estado de manutenção do Nextcloud."
  exit 1
fi

PHASE="parada controlada do n8n"
docker stop --time 45 n8n_app >/dev/null
N8N_STOPPED=1

STAGING_DIR="$BACKUP_ROOT/.partial-$STAMP-$$"
install -d -o root -g root -m 0700 "$STAGING_DIR"

PHASE="dump lógico do PostgreSQL"
docker exec DB_Server pg_dump -U root -d tardis_db --format=custom --compress=9 > "$STAGING_DIR/tardis_db.dump"
docker run --rm -v "$STAGING_DIR/tardis_db.dump:/backup.dump:ro" --entrypoint pg_restore postgres:16-alpine --list /backup.dump >/dev/null

PHASE="arquivos do Nextcloud"
tar --numeric-owner --acls --xattrs -czf "$STAGING_DIR/nextcloud_data.tar.gz" -C "$SERVER_DIR" nextcloud_data

PHASE="dados do n8n"
tar --numeric-owner --acls --xattrs -czf "$STAGING_DIR/n8n_data.tar.gz" -C "$SERVER_DIR" n8n_data

PHASE="configuração de produção e código"
tar --numeric-owner --acls --xattrs -czf "$STAGING_DIR/configuration.tar.gz" \
  -C "$SERVICES_DIR" \
  server/.env \
  server/docker-compose.yml \
  server/databases \
  server/backup.sh \
  server/restore.sh \
  Tardis-source-2026/README.md \
  Tardis-source-2026/.gitignore \
  Tardis-source-2026/docker-compose.yml \
  Tardis-source-2026/tardis-production.override.yml \
  Tardis-source-2026/nginx.production.conf \
  Tardis-source-2026/tardis-production.override.example.yml \
  Tardis-source-2026/scripts \
  Tardis-source-2026/systemd
chmod 0600 "$STAGING_DIR/configuration.tar.gz"
git_repo() {
  runuser -u vamg -- git -C "$REPO_DIR" "$@"
}
GIT_BUNDLE_TMP="$(runuser -u vamg -- mktemp /tmp/tardis-source-bundle.XXXXXX)"
git_repo bundle create "$GIT_BUNDLE_TMP" --all
git_repo bundle verify "$GIT_BUNDLE_TMP" >/dev/null
install -o root -g root -m 0600 "$GIT_BUNDLE_TMP" "$STAGING_DIR/Tardis-source.bundle"
install -o vamg -g vamg -m 0600 "$STAGING_DIR/Tardis-source.bundle" "$GIT_BUNDLE_TMP"
git_repo bundle verify "$GIT_BUNDLE_TMP" >/dev/null
rm -f -- "$GIT_BUNDLE_TMP"
GIT_BUNDLE_TMP=""

if [[ -f /etc/tardis-backup.env ]]; then
  install -o root -g root -m 0600 /etc/tardis-backup.env "$STAGING_DIR/backup-notification.env"
fi

{
  printf 'Backup do Tardis: %s\n' "$STAMP"
  printf 'Host: %s\n' "$(hostname)"
  printf 'Projeto Compose: server\n'
  printf 'Código: %s\n' "$(git_repo rev-parse --abbrev-ref HEAD) @ $(git_repo rev-parse HEAD)"
  printf 'Volume PostgreSQL ativo: '
  docker inspect DB_Server --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}'
  printf '\nImagens em uso:\n'
  docker inspect --format '{{.Name}} {{.Config.Image}} {{.Image}}' DB_Server nextcloud_app n8n_app collabora_app nginx_proxy
  printf '\nTailscale Serve:\n'
  tailscale serve status 2>&1 || true
} > "$STAGING_DIR/host-state.txt"

PHASE="retomada dos serviços"
docker start n8n_app >/dev/null
N8N_STOPPED=0
if [[ "$MAINTENANCE_CHANGED" -eq 1 ]]; then
  docker exec -u www-data nextcloud_app php occ maintenance:mode --off
  MAINTENANCE_CHANGED=0
fi
docker exec DB_Server pg_isready -U root -d tardis_db >/dev/null

PHASE="validação dos arquivos gerados"
gzip -t "$STAGING_DIR/nextcloud_data.tar.gz" "$STAGING_DIR/n8n_data.tar.gz" "$STAGING_DIR/configuration.tar.gz"
tar -tzf "$STAGING_DIR/nextcloud_data.tar.gz" >/dev/null
tar -tzf "$STAGING_DIR/n8n_data.tar.gz" >/dev/null
tar -tzf "$STAGING_DIR/configuration.tar.gz" >/dev/null
if [[ -f "$STAGING_DIR/backup-notification.env" ]]; then
  chmod 0600 "$STAGING_DIR/backup-notification.env"
fi

printf 'Backup completo e validado em %s\n' "$STAMP" > "$STAGING_DIR/COMPLETE.txt"
(cd "$STAGING_DIR" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$STAGING_DIR" && sha256sum -c SHA256SUMS >/dev/null)

PHASE="finalização do backup"
mv "$STAGING_DIR" "$FINAL_DIR"
STAGING_DIR=""
log "Backup semanal concluído e validado: $FINAL_DIR ($(du -sh "$FINAL_DIR" | awk '{print $1}'))."

python3 - "$BACKUP_ROOT" "$RETENTION_WEEKS" <<'PY'
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1])
keep = int(sys.argv[2])
backups = sorted(
    (path for path in root.glob("tardis-weekly-*")
     if path.is_dir() and not path.is_symlink() and (path / "COMPLETE.txt").is_file()),
    key=lambda path: path.name,
    reverse=True,
)
for path in backups[keep:]:
    print(f"Removendo backup semanal antigo: {path.name}")
    shutil.rmtree(path)
PY

PHASE="notificação Slack"
if ! notify_slack "✅ Backup semanal do Tardis concluído em $(hostname): $FINAL_DIR ($(du -sh "$FINAL_DIR" | awk '{print $1}')). Integridade dos arquivos e do dump PostgreSQL verificada."; then
  log "AVISO: backup completo, mas a notificação de sucesso não chegou ao Slack."
fi
log "Rotina concluída."
