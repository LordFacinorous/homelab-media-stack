#!/usr/bin/env bash
# Regenerate deployment templates FROM the live, working configuration.
#
# This direction matters. Hand-authored templates drift from what actually runs, and the
# drift is invisible until a rebuild fails months later. Run this after any change to the
# quadlets or units, and the deployer stays honest.
#
# Round-trip is verified: deploy.sh --check renders the templates back with this host's
# own values and diffs them against the live files. If that diff is not empty, the
# templates lost something.
set -uo pipefail

SRC_Q="$HOME/.config/containers/systemd"
SRC_U="$HOME/.config/systemd/user"
SRC_S="$HOME/services/arr"
DST="$HOME/services/stack-deploy/templates"

mkdir -p "$DST/containers" "$DST/systemd" "$DST/scripts"

# Longest / most specific first: ARR_DIR is inside STACK_HOME, so it must win.
render() {
  sed \
    -e "s#$HOME/services/arr#\${ARR_DIR}#g" \
    -e "s#$HOME/services/ntfy-control#\${NTFY_DIR}#g" \
    -e "s#$HOME#\${STACK_HOME}#g" \
    -e "s#/mnt/cold-storage#\${MEDIA_ROOT}#g" \
    -e "s#100\.88\.81\.2#\${TAILNET_IP}#g" \
    -e "s#America/Denver#\${TZ}#g" \
    -e "s#^Environment=PUID=1000\$#Environment=PUID=\${PUID}#" \
    -e "s#^Environment=PGID=1000\$#Environment=PGID=\${PGID}#" \
    "$1"
}

n=0
for f in "$SRC_Q"/*.container "$SRC_Q"/*.network; do
  [ -e "$f" ] || continue
  render "$f" > "$DST/containers/$(basename "$f").tmpl"
  n=$((n+1))
done
echo "  quadlets templated: $n"

# Only this stack's units. container-*.service are podman-generated, not ours.
u=0
for f in deluge-portsync.service deluge-portsync.path livetv-guide.service livetv-guide.timer \
         ntfy-control.service prime-backup.service prime-backup.timer \
         recyclarr-sync.service recyclarr-sync.timer \
         recordings-tidy.service recordings-tidy.timer \
         arr-backfill.service arr-backfill.timer; do
  [ -e "$SRC_U/$f" ] || continue
  render "$SRC_U/$f" > "$DST/systemd/$f.tmpl"
  u=$((u+1))
done
echo "  systemd units templated: $u"

s=0
# *.py as well as *.sh: backfill.py is Python, and globbing only *.sh would ship a
# timer whose ExecStart points at a script the deployer never installs.
for f in "$SRC_S"/*.sh "$SRC_S"/*.py "$HOME/services/backup/backup.sh"; do
  [ -e "$f" ] || continue
  render "$f" > "$DST/scripts/$(basename "$f").tmpl"
  s=$((s+1))
done
echo "  scripts templated: $s"

echo "  -> $DST"

# NOTE on PUID/PGID: only the literal 1000 is templated. jellyfin deliberately runs
# PUID=0/PGID=0 because it is the one container WITHOUT UserNS=keep-id - under the
# default rootless mapping, container root IS the host user. Every keep-id container
# uses 1000 instead. Substituting both would flatten a real distinction and break
# file ownership. The --check round trip catches this if anyone reintroduces it.
