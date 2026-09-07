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

# Glob rather than a hand-kept list. The list version silently omitted every unit added
# after it was written - recordings-tidy, prime-backup and arr-backfill each had to be
# noticed and added by hand, and ntfy-alert@ would have been the fourth. Two exclusions,
# both mechanical:
#   container-*.service  podman generates these; n8n is not part of this stack
#   zero-byte files      a zero-length unit is a MASK (recyclarr.timer is masked here to
#                        kill a stale timer). Shipping it would mask the unit on a fresh
#                        machine, where there is nothing stale to mask.
u=0
for f in "$SRC_U"/*.service "$SRC_U"/*.timer "$SRC_U"/*.path; do
  [ -e "$f" ] || continue
  b=$(basename "$f")
  case "$b" in container-*) continue ;; esac
  [ -s "$f" ] || { echo "  skipped (masked, zero bytes): $b"; continue; }
  render "$f" > "$DST/systemd/$b.tmpl"
  u=$((u+1))
done
echo "  systemd units templated: $u"

s=0
# *.py as well as *.sh: backfill.py is Python, and globbing only *.sh would ship a
# timer whose ExecStart points at a script the deployer never installs.
#
# Scripts come from two directories and must be INSTALLED back into the matching one.
# MANIFEST records which, so deploy.sh does not carry a hand-kept name list that would
# go stale the moment a script is added - the failure being a unit whose ExecStart
# points somewhere the file was never put.
: > "$DST/scripts/MANIFEST"
# exclude.txt is DATA, not a script, and both backup scripts read it with
# --exclude-from. It was not shipped: on a fresh machine rclone would abort on a missing
# exclude file and the whole backup would fail. The ExecStart guard cannot see this class
# - the path lives inside a script, not in a unit - so the fix is to ship it.
for f in "$SRC_S"/*.sh "$SRC_S"/*.py "$HOME"/services/backup/*.sh "$HOME"/services/backup/exclude.txt; do
  [ -e "$f" ] || continue
  b=$(basename "$f")
  render "$f" > "$DST/scripts/$b.tmpl"
  case "$(dirname "$f")" in
    "$HOME/services/backup") printf '%s\tbackup\n' "$b" >> "$DST/scripts/MANIFEST" ;;
    *)                       printf '%s\tarr\n'    "$b" >> "$DST/scripts/MANIFEST" ;;
  esac
  s=$((s+1))
done
sort -o "$DST/scripts/MANIFEST" "$DST/scripts/MANIFEST"
echo "  scripts templated: $s"

echo "  -> $DST"

# NOTE on PUID/PGID: only the literal 1000 is templated. jellyfin deliberately runs
# PUID=0/PGID=0 because it is the one container WITHOUT UserNS=keep-id - under the
# default rootless mapping, container root IS the host user. Every keep-id container
# uses 1000 instead. Substituting both would flatten a real distinction and break
# file ownership. The --check round trip catches this if anyone reintroduces it.
