#!/bin/bash
# Nightly restic backup of the tModLoader server.
# Installed at /usr/local/sbin/terraria-backup.sh, run by terraria-backup.timer.
set -euo pipefail

# systemd gives root no HOME, and both restic (its cache) and rclone (its config)
# need one. Without it restic aborts with "unable to locate cache directory".
cd /
export HOME=/root

# Repository location and password live outside this repo, so nothing about the
# storage backend is published. Must define RESTIC_REPOSITORY and
# RESTIC_PASSWORD_FILE, and be mode 600.
# shellcheck source=/dev/null
. /root/.restic-terraria-env

CONFIG_DIR="${CONFIG_DIR:-/opt/terraria}"
DATA_DIR="${DATA_DIR:-/srv/terraria}"
COMPOSE=(-f "$CONFIG_DIR/docker-compose.yaml" --project-directory "$CONFIG_DIR")

# healthchecks.io ping URL. Absent file disables alerting, so a fresh host works
# before this is configured.
HC_URL="$(cat /root/.healthchecks-terraria-url 2>/dev/null || true)"
hc() { [ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 "${HC_URL}${1}" >/dev/null || true; }

# Bring the server back up however we exit. A failed backup must not leave the
# server down overnight — but a failed restart is NOT a successful run, so record
# it rather than swallowing it.
finish() {
  rc=$?
  up_rc=0
  if ! docker compose "${COMPOSE[@]}" start; then
    echo "WARN: server failed to start, retrying in 15s" >&2
    sleep 15
    docker compose "${COMPOSE[@]}" start || { echo "ERROR: server failed to start" >&2; up_rc=1; }
  fi
  if [ "$rc" -eq 0 ] && [ "$up_rc" -eq 0 ]; then hc ""; else hc "/fail"; fi
  [ "$rc" -eq 0 ] && [ "$up_rc" -ne 0 ] && rc=1
  exit "$rc"
}
trap finish EXIT

hc "/start"

# Stop the server rather than backing up a live world.
#
# tModLoader writes the world on shutdown, so a clean stop gives a guaranteed
# consistent save. The alternative — issuing `save` to a running server and copying
# afterwards — has no completion signal to wait on, so it is a guess dressed up as a
# backup. The world is the one irreplaceable thing here; a minute of downtime at
# 05:00 is a cheap price for certainty. stop_grace_period in the compose file allows
# 120s for the write to finish.
echo "Stopping the server for a consistent world save..."
docker compose "${COMPOSE[@]}" stop

echo "Backing up..."
# Excluded, all reconstructible:
#   server/    the tModLoader install itself — rebuilt from the image
#   steamapps/ Steam Workshop cache — re-downloaded from install.txt
# Kept: Worlds/ (irreplaceable), Mods/ (incl. install.txt and enabled.json),
# ModConfigs/ (per-mod settings, tedious to redo), and the compose config.
restic backup "$CONFIG_DIR" "$DATA_DIR" \
  --exclude "$DATA_DIR/server" \
  --exclude "$DATA_DIR/steamapps" \
  --exclude '**/tModLoader-Logs' \
  --exclude '**/*.log*'

echo "Pruning..."
# More dailies than a typical service backup: the failures this protects against
# are often noticed late — a griefed base, a corrupt save, a mod update that broke
# the world. Worlds are small, so history is cheap.
restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 6 --prune

restic snapshots --latest 3
