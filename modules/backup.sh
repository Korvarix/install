#!/usr/bin/env bash
# module: backup
# Nightly off-cluster backup (restic) of irreplaceable data. Models excluded.
# Menu + cron entrypoint: kcv_module_backup, subcommand: run|restore|cron.

backup_run() {
  kcv_init
  [[ -n "${BACKUP_TARGET:-}" ]] || die "BACKUP_TARGET empty in $KCV_ENV_FILE (e.g. /mnt/backup, ssh://user@host:port/backup, rest:https://...)"
  log "backup: target $BACKUP_TARGET"
  dep_ensure "restic:restic" "openssl:openssl"

  local pass_file="${KCV_ETC_DIR}/backup.pass"
  if [[ ! -s "$pass_file" ]]; then
    umask 077
    openssl rand -hex 32 > "$pass_file"
    warn "generated repo passphrase: $pass_file - back it up somewhere OFF this cluster (no pass = no restores)"
  fi
  umask 077
  export RESTIC_PASSWORD_FILE="$pass_file"

  if ! restic -r "$BACKUP_TARGET" snapshots --last >/dev/null 2>&1; then
    log "backup: initializing new restic repo at $BACKUP_TARGET"
    restic -r "$BACKUP_TARGET" init || die "repo init failed - check BACKUP_TARGET reachability"
  fi

  local roots=""
  local root
  for root in $BACKUP_ROOTS; do
    mkdir -p "$root"
    roots="$roots $root"
  done
  [[ -n "$roots" ]] || roots="$KCV_ETC_DIR"

  log "backup: snapshotting$roots (excludes: models, gguf, llama.cpp build)"
  # shellcheck disable=SC2086
  restic -r "$BACKUP_TARGET" backup $roots \
    --exclude "*/models" --exclude "*.gguf" \
    --exclude "*/llama.cpp" --exclude "*/node_modules" \
    --tag korvarix || die "backup failed"
  restic -r "$BACKUP_TARGET" forget --keep-daily "${BACKUP_KEEP:-7}" --prune || warn "prune failed (harmless)"
  log "backup: done"
}

backup_list() {
  kcv_init
  export RESTIC_PASSWORD_FILE="${KCV_ETC_DIR}/backup.pass"
  [[ -f "$RESTIC_PASSWORD_FILE" ]] || die "no backup passphrase - nothing was ever backed up here"
  [[ -n "${BACKUP_TARGET:-}" ]] || die "BACKUP_TARGET empty"
  restic -r "$BACKUP_TARGET" snapshots
}

backup_restore() {
  kcv_init
  export RESTIC_PASSWORD_FILE="${KCV_ETC_DIR}/backup.pass"
  local snap="${1:-latest}" dest="${2:-/tmp/korvarix-restore}"
  [[ -n "${BACKUP_TARGET:-}" ]] || die "BACKUP_TARGET empty"
  mkdir -p "$dest"
  restic -r "$BACKUP_TARGET" restore "$snap" --target "$dest"
  ok "restored $snap -> $dest"
}

kcv_module_backup() {
  local action="${1:-menu}"
  case "$action" in
    run)     backup_run ;;
    list)    backup_list ;;
    restore) shift; backup_restore "$@" ;;
    cron)    cron_menu_run ;;
    menu)
      echo "  1) backup now  2) list snapshots  3) restore  4) install backup cron  0) back"
      local r; read -r -p "select: " r
      case "$r" in
        1) backup_run ;;
        2) backup_list ;;
        3) read -r -p "snapshot id [latest]: " s; backup_restore "${s:-latest}" "" ;;
        4) kcv_run_module cron ;;
        *) : ;;
      esac
      ;;
    *) die "usage: backup run|list|restore <snap>|cron" ;;
  esac
}