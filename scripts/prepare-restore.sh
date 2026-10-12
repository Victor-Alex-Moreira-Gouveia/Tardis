#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ "$EUID" -ne 0 ]]; then
  echo "Execute como root: sudo $0 BACKUP_DIR DIRETORIO_DE_PREPARACAO" >&2
  exit 1
fi

if [[ "$#" -ne 2 ]]; then
  echo "Uso: sudo $0 /var/backups/tardis-weekly/tardis-weekly-DATA /var/tmp/tardis-restore-DATA" >&2
  exit 2
fi

BACKUP_DIR="$(realpath "$1")"
DESTINATION="$(realpath -m "$2")"
PRODUCTION_ROOT="/home/vamg/Desktop/services"
GIT_CHECK_DIR=""
cleanup() {
  if [[ -n "$GIT_CHECK_DIR" && -d "$GIT_CHECK_DIR" ]]; then
    rm -rf -- "$GIT_CHECK_DIR"
  fi
}
trap cleanup EXIT

if [[ ! -f "$BACKUP_DIR/COMPLETE.txt" || ! -f "$BACKUP_DIR/SHA256SUMS" ]]; then
  echo "A pasta não contém uma cópia semanal completa." >&2
  exit 1
fi

if [[ -e "$DESTINATION" ]]; then
  echo "O destino já existe; escolha uma pasta nova para preservar os arquivos existentes." >&2
  exit 1
fi

if python3 - "$PRODUCTION_ROOT" "$DESTINATION" <<'PY'
import os
import sys

root = os.path.realpath(sys.argv[1])
destination = os.path.realpath(sys.argv[2])
try:
    inside = os.path.commonpath([root, destination]) == root
except ValueError:
    inside = False
sys.exit(0 if inside else 1)
PY
then
  echo "O destino não pode ficar dentro das pastas de produção." >&2
  exit 1
fi

for file in tardis_db.dump nextcloud_data.tar.gz n8n_data.tar.gz configuration.tar.gz Tardis-source.bundle host-state.txt; do
  if [[ ! -s "$BACKUP_DIR/$file" ]]; then
    echo "Arquivo ausente ou vazio no backup: $file" >&2
    exit 1
  fi
done

(
  cd "$BACKUP_DIR"
  sha256sum -c SHA256SUMS
)
if command -v docker >/dev/null; then
  docker run --rm -v "$BACKUP_DIR/tardis_db.dump:/backup.dump:ro" --entrypoint pg_restore postgres:16-alpine --list /backup.dump >/dev/null
else
  echo "Validação do dump requer pg_restore ou Docker com a imagem postgres:16-alpine." >&2
  exit 1
fi
tar -tzf "$BACKUP_DIR/nextcloud_data.tar.gz" >/dev/null
tar -tzf "$BACKUP_DIR/n8n_data.tar.gz" >/dev/null
tar -tzf "$BACKUP_DIR/configuration.tar.gz" >/dev/null
GIT_CHECK_DIR="$(mktemp -d /tmp/tardis-restore-bundle.XXXXXX)"
git -c init.defaultBranch=main clone --quiet "$BACKUP_DIR/Tardis-source.bundle" "$GIT_CHECK_DIR/repo"
git -C "$GIT_CHECK_DIR/repo" fsck --no-reflogs --connectivity-only
rm -rf -- "$GIT_CHECK_DIR"
GIT_CHECK_DIR=""

install -d -o root -g root -m 0700 "$DESTINATION"
tar --numeric-owner --acls --xattrs -xzf "$BACKUP_DIR/nextcloud_data.tar.gz" -C "$DESTINATION"
tar --numeric-owner --acls --xattrs -xzf "$BACKUP_DIR/n8n_data.tar.gz" -C "$DESTINATION"
tar --numeric-owner --acls --xattrs -xzf "$BACKUP_DIR/configuration.tar.gz" -C "$DESTINATION"
install -d -o root -g root -m 0700 "$DESTINATION/database"
install -o root -g root -m 0600 "$BACKUP_DIR/tardis_db.dump" "$DESTINATION/database/tardis_db.dump"
install -o root -g root -m 0600 "$BACKUP_DIR/Tardis-source.bundle" "$DESTINATION/Tardis-source.bundle"
install -o root -g root -m 0600 "$BACKUP_DIR/host-state.txt" "$DESTINATION/host-state.txt"
if [[ -f "$BACKUP_DIR/backup-notification.env" ]]; then
  install -o root -g root -m 0600 "$BACKUP_DIR/backup-notification.env" "$DESTINATION/backup-notification.env"
fi

cat > "$DESTINATION/RESTORE-NOTES.txt" <<'EOF'
Esta pasta é uma preparação isolada. Nenhum container ou arquivo de produção foi alterado.

Inclui os arquivos Nextcloud e n8n, o dump customizado tardis_db.dump,
as configurações salvas e um bundle Git. Para completar uma recuperação,
use PostgreSQL 16, recrie/verifique as roles root e oc_admin, importe
tardis_db.dump com pg_restore e valide a aplicação antes de trocar mounts.

Não suba este Compose nem copie arquivos para a produção sem revisar todos
os caminhos e os nomes de volume em tardis-production.override.yml.
EOF
chmod 0600 "$DESTINATION/RESTORE-NOTES.txt"

echo "Arquivos de recuperação preparados em $DESTINATION."
echo "A produção permaneceu intacta. Revise RESTORE-NOTES.txt antes de continuar."
