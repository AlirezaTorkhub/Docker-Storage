#!/usr/bin/env bash
# Read-only Docker / containerd storage inventory for Linux hosts.
# Tested for Bash 4+ and GNU coreutils on Ubuntu/Debian-style systems.

set -Eeuo pipefail
umask 077

REPORT_DIR="${REPORT_DIR:-/var/log/docker-storage-audit}"
CONTAINERD_ROOT="${CONTAINERD_ROOT:-/var/lib/containerd}"
SCAN_VOLUME_SIZES="${SCAN_VOLUME_SIZES:-0}" # Set to 1 to recursively measure local volume directories.
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
section() {
  printf '\n\n================================================================\n'
  printf ' %s\n' "$1"
  printf '================================================================\n'
}

for cmd in docker df du find sort awk sed stat date tee; do
  command -v "$cmd" >/dev/null 2>&1 || {
    printf 'ERROR: required command not found: %s\n' "$cmd" >&2
    exit 1
  }
done

if ! docker info >/dev/null 2>&1; then
  printf 'ERROR: Docker daemon is unavailable or this user cannot access it. Run with sudo.\n' >&2
  exit 1
fi

mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/docker-storage-audit-${HOSTNAME_SHORT}-${TIMESTAMP}.txt"
exec > >(tee "$REPORT_FILE") 2>&1

DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}')"
DOCKER_VERSION="$(docker info --format '{{.ServerVersion}}')"
STORAGE_DRIVER="$(docker info --format '{{.Driver}}')"
LOG_DRIVER="$(docker info --format '{{.LoggingDriver}}')"

section "Docker Storage Audit"
log "Host: ${HOSTNAME_SHORT}"
log "Generated: $(date --iso-8601=seconds)"
log "Docker version: ${DOCKER_VERSION}"
log "Docker root: ${DOCKER_ROOT}"
log "Storage driver: ${STORAGE_DRIVER}"
log "Logging driver: ${LOG_DRIVER}"
log "Containerd root override/default: ${CONTAINERD_ROOT}"
log "Recursive local-volume size scan: ${SCAN_VOLUME_SIZES}"
log "Report: ${REPORT_FILE}"
if [[ "${EUID}" -ne 0 ]]; then
  log "WARNING: not running as root; some filesystem sizes and paths may be inaccessible."
fi

section "1. Filesystem capacity and inode usage"
df -hT || true
printf '\n-- Inodes --\n'
df -i || true

section "2. Docker daemon configuration"
docker info 2>/dev/null | sed -n \
  -e '/Server Version:/p' \
  -e '/Storage Driver:/p' \
  -e '/Logging Driver:/p' \
  -e '/Docker Root Dir:/p' \
  -e '/containerd version:/p' \
  -e '/Kernel Version:/p' \
  -e '/Operating System:/p' \
  -e '/Architecture:/p' \
  -e '/Cgroup Driver:/p' \
  -e '/Live Restore Enabled:/p' || true

section "3. Docker resource summary"
docker system df -v || true

section "4. Containers (including stopped)"
docker ps -a --size --no-trunc || true
printf '\n-- Container mounts --\n'
while IFS= read -r container_id; do
  [[ -n "$container_id" ]] || continue
  docker inspect --format '{{.Name}} | {{.State.Status}} | {{range .Mounts}}{{.Type}}:{{if .Name}}{{.Name}}{{else}}{{.Source}}{{end}} -> {{.Destination}}; {{end}}' "$container_id" 2>/dev/null || true
done < <(docker ps -aq)

section "5. Images"
docker image ls --all --digests --no-trunc || true
printf '\n-- Dangling images --\n'
docker image ls --filter dangling=true || true

section "6. Volumes and local volume sizes"
docker volume ls || true
while IFS= read -r volume_name; do
  [[ -n "$volume_name" ]] || continue
  driver="$(docker volume inspect --format '{{.Driver}}' "$volume_name" 2>/dev/null || true)"
  mountpoint="$(docker volume inspect --format '{{.Mountpoint}}' "$volume_name" 2>/dev/null || true)"
  created="$(docker volume inspect --format '{{.CreatedAt}}' "$volume_name" 2>/dev/null || true)"
  labels="$(docker volume inspect --format '{{json .Labels}}' "$volume_name" 2>/dev/null || true)"
  size="N/A (not a local directory or inaccessible)"
  if [[ "$driver" == "local" && -n "$mountpoint" && -d "$mountpoint" ]]; then
    if [[ "$SCAN_VOLUME_SIZES" == "1" ]]; then
      size="$(du -sh -- "$mountpoint" 2>/dev/null | awk '{print $1}' || printf 'unavailable')"
    else
      size="not scanned (set SCAN_VOLUME_SIZES=1)"
    fi
  fi
  printf 'Volume=%s | Driver=%s | Created=%s | Size=%s | Mountpoint=%s | Labels=%s\n' \
    "$volume_name" "$driver" "$created" "$size" "$mountpoint" "$labels"
done < <(docker volume ls -q)

section "7. Networks"
docker network ls || true

section "8. Build cache"
docker builder du || true
if docker buildx version >/dev/null 2>&1; then
  printf '\n-- Buildx builders --\n'
  docker buildx ls || true
fi

section "9. Container log files"
printf 'Configured logging driver: %s\n' "$LOG_DRIVER"
while IFS= read -r container_id; do
  [[ -n "$container_id" ]] || continue
  docker inspect --format '{{.Name}} | LogDriver={{.HostConfig.LogConfig.Type}} | LogPath={{.LogPath}}' "$container_id" 2>/dev/null || true
done < <(docker ps -aq)
if [[ -d "$DOCKER_ROOT/containers" ]]; then
  printf '\n-- Largest json-file logs (top 20) --\n'
  find "$DOCKER_ROOT/containers" -type f -name '*-json.log' -printf '%s\t%p\n' 2>/dev/null \
    | sort -nr | head -20 \
    | awk -F '\t' '{printf "%.2f MiB\t%s\n", $1/1048576, $2}' || true
fi

section "10. Docker / containerd data-root directory sizes"
if [[ -d "$DOCKER_ROOT" ]]; then
  printf '\n-- Docker root: %s --\n' "$DOCKER_ROOT"
  du -xhd2 "$DOCKER_ROOT" 2>/dev/null | sort -h | tail -40 || true
else
  log "Docker root directory not found: $DOCKER_ROOT"
fi
if [[ -d "$CONTAINERD_ROOT" ]]; then
  printf '\n-- Containerd root: %s --\n' "$CONTAINERD_ROOT"
  du -xhd2 "$CONTAINERD_ROOT" 2>/dev/null | sort -h | tail -60 || true
else
  log "Containerd root directory not found: $CONTAINERD_ROOT"
fi

section "11. Largest files under Docker / containerd (top 30, files >= 50 MiB)"
for root in "$DOCKER_ROOT" "$CONTAINERD_ROOT"; do
  [[ -d "$root" ]] || continue
  printf '\n-- %s --\n' "$root"
  find "$root" -xdev -type f -size +50M -printf '%s\t%p\n' 2>/dev/null \
    | sort -nr | head -30 \
    | awk -F '\t' '{printf "%.2f MiB\t%s\n", $1/1048576, $2}' || true
done

section "Audit complete"
log "Read-only report saved to: ${REPORT_FILE}"
log "No Docker resources or files were modified by this script."
