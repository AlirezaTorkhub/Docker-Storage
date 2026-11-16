#!/usr/bin/env bash
# Conservative, policy-based Docker cleanup.
# Dry-run is the default. Nothing is deleted unless --apply is supplied.
# Named/unused volumes are considered only with --weekly-volumes.

set -Eeuo pipefail
umask 077

# ---------------------------- Policy ---------------------------------
CONTAINER_RETENTION_HOURS="${CONTAINER_RETENTION_HOURS:-48}"   # time since exit; for never-started containers, time since creation
IMAGE_RETENTION_HOURS="${IMAGE_RETENTION_HOURS:-336}"           # unused images older than 14 days
NETWORK_RETENTION_HOURS="${NETWORK_RETENTION_HOURS:-168}"      # unused networks older than 7 days
BUILD_CACHE_RETENTION_HOURS="${BUILD_CACHE_RETENTION_HOURS:-168}" # build cache not used in 7 days
BUILD_CACHE_KEEP="${BUILD_CACHE_KEEP:-512MB}"                   # retain a small warm cache
VOLUME_RETENTION_DAYS="${VOLUME_RETENTION_DAYS:-7}"              # weekly volume sweep; only detached volumes older than this
PROTECTED_VOLUMES_FILE="${PROTECTED_VOLUMES_FILE:-/etc/docker-storage-cleanup/protected-volumes.txt}"
PROTECT_COMPOSE_VOLUMES="${PROTECT_COMPOSE_VOLUMES:-1}"         # keep Compose-managed volumes unless explicitly overridden
LOG_FILE="${LOG_FILE:-/var/log/docker-storage-cleanup.log}"

APPLY=0
WEEKLY_VOLUMES=0
INCLUDE_COMPOSE_VOLUMES=0

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
section() {
  printf '\n\n================================================================\n'
  printf ' %s\n' "$1"
  printf '================================================================\n'
}
usage() {
  cat <<USAGE
Usage: $0 [--dry-run] [--apply] [--weekly-volumes] [--include-compose-volumes]

Options:
  --dry-run                 Preview only (default); no deletion.
  --apply                   Execute regular cleanup policies.
  --weekly-volumes          Also review and remove detached local volumes older
                            than VOLUME_RETENTION_DAYS. Requires --apply to delete.
  --include-compose-volumes  Include Compose-labelled volumes in the weekly sweep.
                            Use only when you intentionally accept deleting their data.
  -h, --help                Show this help.

Policy defaults:
  Stopped containers:       ${CONTAINER_RETENTION_HOURS} hours since exit
  Unused images:            ${IMAGE_RETENTION_HOURS} hours since image creation
  Unused networks:          ${NETWORK_RETENTION_HOURS} hours since creation
  Build cache:              not used in ${BUILD_CACHE_RETENTION_HOURS} hours
  Build cache to retain:    ${BUILD_CACHE_KEEP}
  Weekly volume age:        ${VOLUME_RETENTION_DAYS} days
  Protected volume file:    ${PROTECTED_VOLUMES_FILE}

Important:
  - Volumes are never considered unless --weekly-volumes is supplied.
  - Compose-managed volumes are protected by default.
  - Volumes with label com.example.docker-maintenance.keep=true are always protected.
  - Names listed in the protected-volume file are always protected.
USAGE
}

while (($#)); do
  case "$1" in
    --dry-run) APPLY=0 ;;
    --apply) APPLY=1 ;;
    --weekly-volumes) WEEKLY_VOLUMES=1 ;;
    --include-compose-volumes) INCLUDE_COMPOSE_VOLUMES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$INCLUDE_COMPOSE_VOLUMES" -eq 1 && "$WEEKLY_VOLUMES" -ne 1 ]]; then
  printf 'ERROR: --include-compose-volumes requires --weekly-volumes.\n' >&2
  exit 2
fi
if [[ "$INCLUDE_COMPOSE_VOLUMES" -eq 1 && "$APPLY" -ne 1 ]]; then
  log "NOTE: Compose volumes are included in the preview only; --apply is required for deletion."
fi

for cmd in docker date awk sort df; do
  command -v "$cmd" >/dev/null 2>&1 || {
    printf 'ERROR: required command not found: %s\n' "$cmd" >&2
    exit 1
  }
done

if [[ "$EUID" -ne 0 ]]; then
  printf 'ERROR: run this script as root (for example: sudo %s).\n' "$0" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  printf 'ERROR: Docker daemon unavailable.\n' >&2
  exit 1
fi

# Prevent two cleanup runs from racing each other.
if command -v flock >/dev/null 2>&1; then
  exec 9>/run/lock/docker-storage-cleanup.lock
  if ! flock -n 9; then
    log "Another cleanup run is active; exiting."
    exit 0
  fi
fi

mkdir -p "$(dirname "$LOG_FILE")"
# Keep a persistent log; caller can also redirect output elsewhere.
exec >>"$LOG_FILE" 2>&1

MODE="DRY-RUN"
[[ "$APPLY" -eq 1 ]] && MODE="APPLY"
section "Docker storage cleanup (${MODE})"
log "Docker context: $(docker context show 2>/dev/null || printf unknown)"
log "Docker version: $(docker info --format '{{.ServerVersion}}')"
log "Docker root: $(docker info --format '{{.DockerRootDir}}')"
log "Storage driver: $(docker info --format '{{.Driver}}')"
log "Weekly volume sweep: $([[ "$WEEKLY_VOLUMES" -eq 1 ]] && printf enabled || printf disabled)"
log "Started."

section "Before: disk and Docker usage"
df -hT || true
docker system df || true

# Convert a Docker RFC3339 timestamp into Unix seconds.
to_epoch() {
  local value="$1"
  date -d "$value" +%s 2>/dev/null
}

# ------------------------ 1. Stopped containers -----------------------
section "1. Stopped containers older than policy"
now_epoch="$(date +%s)"
container_cutoff_seconds=$((CONTAINER_RETENTION_HOURS * 3600))
container_candidates=()

while IFS= read -r container_id; do
  [[ -n "$container_id" ]] || continue
  info="$(docker inspect --format '{{.State.Status}}|{{.Created}}|{{.State.FinishedAt}}|{{.Name}}' "$container_id" 2>/dev/null || true)"
  [[ -n "$info" ]] || continue
  IFS='|' read -r status created finished name <<< "$info"
  case "$status" in
    exited|dead)
      timestamp="$finished"
      ;;
    created)
      timestamp="$created"
      ;;
    *)
      continue
      ;;
  esac
  [[ -n "$timestamp" && "$timestamp" != 0001-* ]] || timestamp="$created"
  timestamp_epoch="$(to_epoch "$timestamp" || true)"
  [[ -n "$timestamp_epoch" ]] || { log "SKIP container $container_id: cannot parse age timestamp ($timestamp)"; continue; }
  age_seconds=$((now_epoch - timestamp_epoch))
  if (( age_seconds >= container_cutoff_seconds )); then
    container_candidates+=("$container_id")
    log "CANDIDATE container: ${name#/} id=${container_id:0:12} status=$status age_hours=$((age_seconds / 3600))"
  fi
done < <(docker ps -aq)

if ((${#container_candidates[@]} == 0)); then
  log "No stopped/created containers meet the retention policy."
elif [[ "$APPLY" -eq 1 ]]; then
  for container_id in "${container_candidates[@]}"; do
    docker rm "$container_id" || log "WARNING: could not remove container ${container_id:0:12}; inspect manually."
  done
else
  log "DRY-RUN: would remove ${#container_candidates[@]} stopped/created container(s)."
fi

# ------------------------ 2. Unused networks --------------------------
section "2. Unused networks older than policy"
log "Policy: network created more than ${NETWORK_RETENTION_HOURS} hours ago and not attached to a container."
if [[ "$APPLY" -eq 1 ]]; then
  docker network prune --filter "until=${NETWORK_RETENTION_HOURS}h" --force || log "WARNING: network prune returned an error."
else
  docker network ls
  log "DRY-RUN: would run: docker network prune --filter until=${NETWORK_RETENTION_HOURS}h"
fi

# ------------------------ 3. Unused images ----------------------------
section "3. Unused images older than policy"
log "Policy: remove images not referenced by any remaining container and older than ${IMAGE_RETENTION_HOURS} hours."
if [[ "$APPLY" -eq 1 ]]; then
  docker image prune --all --force --filter "until=${IMAGE_RETENTION_HOURS}h" || log "WARNING: image prune returned an error."
else
  docker image ls --all --digests
  log "DRY-RUN: would run: docker image prune --all --filter until=${IMAGE_RETENTION_HOURS}h"
fi

# ------------------------ 4. Build cache -------------------------------
section "4. Build cache older than policy"
docker builder du || true
log "Policy: unused BuildKit cache older than ${BUILD_CACHE_RETENTION_HOURS} hours; keep up to ${BUILD_CACHE_KEEP} warm cache where supported."
if [[ "$APPLY" -eq 1 ]]; then
  docker builder prune --all --force \
    --filter "until=${BUILD_CACHE_RETENTION_HOURS}h" \
    --keep-storage "$BUILD_CACHE_KEEP" || log "WARNING: builder prune returned an error."
else
  log "DRY-RUN: would run: docker builder prune --all --filter until=${BUILD_CACHE_RETENTION_HOURS}h --keep-storage ${BUILD_CACHE_KEEP}"
fi

# ------------------------ 5. Weekly volumes ----------------------------
section "5. Weekly detached-volume review"
if [[ "$WEEKLY_VOLUMES" -ne 1 ]]; then
  log "Skipped. Volumes are protected unless --weekly-volumes is explicitly supplied."
else
  volume_cutoff_seconds=$((VOLUME_RETENTION_DAYS * 86400))
  volume_candidates=()

  is_protected_volume() {
    local candidate="$1"
    [[ -f "$PROTECTED_VOLUMES_FILE" ]] && grep -Fqx -- "$candidate" "$PROTECTED_VOLUMES_FILE"
  }

  while IFS= read -r volume_name; do
    [[ -n "$volume_name" ]] || continue

    driver="$(docker volume inspect --format '{{.Driver}}' "$volume_name" 2>/dev/null || true)"
    created="$(docker volume inspect --format '{{.CreatedAt}}' "$volume_name" 2>/dev/null || true)"
    keep_label="$(docker volume inspect --format '{{with .Labels}}{{index . "com.example.docker-maintenance.keep"}}{{end}}' "$volume_name" 2>/dev/null || true)"
    compose_project="$(docker volume inspect --format '{{with .Labels}}{{index . "com.docker.compose.project"}}{{end}}' "$volume_name" 2>/dev/null || true)"

    if [[ "$driver" != "local" ]]; then
      log "SKIP volume $volume_name: driver '$driver' is not local."
      continue
    fi
    if [[ "$keep_label" == "true" ]]; then
      log "PROTECTED volume $volume_name: keep label is true."
      continue
    fi
    if is_protected_volume "$volume_name"; then
      log "PROTECTED volume $volume_name: listed in $PROTECTED_VOLUMES_FILE."
      continue
    fi
    if [[ -n "$compose_project" && "$compose_project" != '<no value>' && "$INCLUDE_COMPOSE_VOLUMES" -ne 1 ]]; then
      log "PROTECTED volume $volume_name: Compose-managed (project=$compose_project); use --include-compose-volumes only after review."
      continue
    fi

    # Double-check that no container (including stopped containers) references the volume.
    attached="$(docker ps -aq --filter "volume=$volume_name" 2>/dev/null || true)"
    if [[ -n "$attached" ]]; then
      log "SKIP volume $volume_name: referenced by at least one container."
      continue
    fi

    volume_epoch="$(to_epoch "$created" || true)"
    if [[ -z "$volume_epoch" ]]; then
      log "SKIP volume $volume_name: cannot parse CreatedAt='$created'."
      continue
    fi
    age_seconds=$((now_epoch - volume_epoch))
    if (( age_seconds < volume_cutoff_seconds )); then
      log "KEEP volume $volume_name: age_days=$((age_seconds / 86400)) is below retention (${VOLUME_RETENTION_DAYS} days)."
      continue
    fi

    volume_candidates+=("$volume_name")
    log "CANDIDATE volume: $volume_name driver=$driver age_days=$((age_seconds / 86400)) compose_project=${compose_project:-none}"
  done < <(docker volume ls -q --filter dangling=true)

  if ((${#volume_candidates[@]} == 0)); then
    log "No detached local volumes meet the weekly retention policy."
  elif [[ "$APPLY" -eq 1 ]]; then
    log "Deleting ${#volume_candidates[@]} eligible detached volume(s), one by one."
    for volume_name in "${volume_candidates[@]}"; do
      docker volume rm "$volume_name" || log "WARNING: could not remove volume $volume_name; inspect manually."
    done
  else
    log "DRY-RUN: found ${#volume_candidates[@]} candidate volume(s); no volume data was deleted."
  fi
fi

section "After: disk and Docker usage"
df -hT || true
docker system df -v || true
log "Cleanup finished. Mode=${MODE}. Log=${LOG_FILE}"
