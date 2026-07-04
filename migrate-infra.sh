#!/usr/bin/env sh

set -eu

usage() {
  cat <<'EOF'
Usage:
  ./migrate-infra.sh backup
  ./migrate-infra.sh restore

Environment overrides:
  PROJECT_NAME   Docker Compose project name. Defaults to the current directory name.
  BACKUP_DIR     Backup directory. Defaults to /tmp/infra-migration.
  COMPOSE_FILE   Compose file to use. Defaults to docker-compose.yml.

The script backs up and restores the Docker named volumes used by the stack:
postgres_data, garage_meta, garage_data, caddy_data, and caddy_config.
It also copies garage.toml, .env, and caddy/Caddyfile when present.
EOF
}

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || die "missing required file: $1"
}

backup_tar() {
  volume_name=$1
  archive_name=$2

  docker run --rm \
    -v "${volume_name}:/volume" \
    -v "${BACKUP_DIR}:/backup" \
    alpine sh -c "cd /volume && tar czf /backup/${archive_name} ."
}

restore_tar() {
  volume_name=$1
  archive_name=$2

  [ -f "${BACKUP_DIR}/${archive_name}" ] || die "missing archive: ${BACKUP_DIR}/${archive_name}"

  docker run --rm \
    -v "${volume_name}:/volume" \
    -v "${BACKUP_DIR}:/backup" \
    alpine sh -c "cd /volume && tar xzf /backup/${archive_name}"
}

copy_if_present() {
  source_path=$1
  target_path=$2

  if [ -f "$source_path" ]; then
    mkdir -p "$(dirname "$target_path")"
    cp "$source_path" "$target_path"
  fi
}

PROJECT_NAME=${PROJECT_NAME:-$(basename "$PWD")}
BACKUP_DIR=${BACKUP_DIR:-/tmp/infra-migration}
COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.yml}

command=${1:-}

case "$command" in
  backup)
    require_file "$COMPOSE_FILE"
    require_file garage.toml

    mkdir -p "$BACKUP_DIR/caddy"

    log "Stopping the stack with ${COMPOSE_FILE}"
    docker compose -f "$COMPOSE_FILE" down

    log "Copying config files"
    cp garage.toml "$BACKUP_DIR/garage.toml"
    copy_if_present .env "$BACKUP_DIR/.env"
    copy_if_present caddy/Caddyfile "$BACKUP_DIR/caddy/Caddyfile"

    log "Backing up volumes for project ${PROJECT_NAME}"
    backup_tar "${PROJECT_NAME}_postgres_data" postgres_data.tgz
    backup_tar "${PROJECT_NAME}_garage_meta" garage_meta.tgz
    backup_tar "${PROJECT_NAME}_garage_data" garage_data.tgz
    backup_tar "${PROJECT_NAME}_caddy_data" caddy_data.tgz
    backup_tar "${PROJECT_NAME}_caddy_config" caddy_config.tgz

    log "Backup complete: ${BACKUP_DIR}"
    ;;

  restore)
    require_file "$COMPOSE_FILE"

    [ -d "$BACKUP_DIR" ] || die "missing backup directory: $BACKUP_DIR"

    log "Stopping any running stack with ${COMPOSE_FILE}"
    docker compose -f "$COMPOSE_FILE" down

    log "Restoring config files"
    cp "$BACKUP_DIR/garage.toml" ./garage.toml
    if [ -f "$BACKUP_DIR/.env" ]; then
      cp "$BACKUP_DIR/.env" ./.env
    fi
    if [ -f "$BACKUP_DIR/caddy/Caddyfile" ]; then
      mkdir -p caddy
      cp "$BACKUP_DIR/caddy/Caddyfile" ./caddy/Caddyfile
    fi

    log "Restoring volumes for project ${PROJECT_NAME}"
    restore_tar "${PROJECT_NAME}_postgres_data" postgres_data.tgz
    restore_tar "${PROJECT_NAME}_garage_meta" garage_meta.tgz
    restore_tar "${PROJECT_NAME}_garage_data" garage_data.tgz
    restore_tar "${PROJECT_NAME}_caddy_data" caddy_data.tgz
    restore_tar "${PROJECT_NAME}_caddy_config" caddy_config.tgz

    log "Starting the stack"
    docker compose -f "$COMPOSE_FILE" up -d

    log "Restore complete"
    ;;

  -h|--help|help|"")
    usage
    ;;

  *)
    usage >&2
    exit 1
    ;;
esac