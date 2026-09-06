#!/usr/bin/env bash
# Launch a sandboxed Claude session with Remote Control enabled, so the operator drives it
# interactively from the phone instead of passing one-shot prompts over ntfy.
#
# Containment, and why each piece is here:
#   --network arr            only the arr bridge. It has outbound internet (it must, to
#                            reach Anthropic) but no route to any other host subnet.
#   -v services/arr:/config  the only host path it can see or write.
#   credentials :ro          the only thing from ~/.claude it gets.
#   --tmpfs /home/repair     session state lives and dies with the container.
#   --cap-drop=ALL, no-new-privileges
#   NO podman socket         so it cannot create containers or escape via the runtime.
#
# It cannot restart containers. It reports what needs restarting; you send `restart <svc>`
# on the ntfy channel.
#
# Usage:
#   claude-contained.sh start   launch the session (idempotent)
#   claude-contained.sh stop    kill it
#   claude-contained.sh status  is it running
set -uo pipefail

IMAGE="localhost/claude-repair:latest"
NAME="claude-repair"
SESSION="prime-arr-repair"
# Derive from this script's own location so it works wherever it is installed.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARR="$(dirname "$HERE")/arr"
CREDS="$HOME/.claude/.credentials.json"
# A fresh config dir makes Claude run its first-launch onboarding (theme picker) and it
# never reaches --remote-control. These two files mark onboarding done and set a theme.
# Deliberately NOT the operator's real settings.json: its hooks point at host paths that do
# not exist in this container.
SEED="$HERE/seed"
ACTION="${1:-start}"

case "$ACTION" in
  stop)
    podman rm -f "$NAME" >/dev/null 2>&1 && echo "repair session stopped" || echo "not running"
    exit 0 ;;
  status)
    if podman container exists "$NAME" 2>/dev/null; then
      echo "repair session: $(podman inspect -f '{{.State.Status}}' "$NAME")"
    else
      echo "repair session: not running"
    fi
    exit 0 ;;
esac

if ! podman image exists "$IMAGE" 2>/dev/null; then
  cat <<'MSG'
Repair sandbox image is not built, so no session can start.

On PRIME:
  cd ~/services/ntfy-control && podman build -t localhost/claude-repair:latest .

Every other command (status, vpn, disk, who, logs, restart) works without it.
MSG
  exit 0
fi

[ -r "$CREDS" ] || { echo "no readable Claude credentials at $CREDS"; exit 0; }

if podman container exists "$NAME" 2>/dev/null; then
  echo "repair session already running - open Claude on your phone, session '$SESSION'"
  exit 0
fi

# -d -t : detached but with a TTY, because --remote-control starts an interactive session
# and Claude Code expects a terminal.
#   --userns=keep-id  maps host uid 1000 to the container's 'repair' user. Without it
#                     rootless podman maps host 1000 to container root, so /config is
#                     visible but NOT writable - verified, the agent could read and
#                     never repair anything.
#   credentials rw    Claude refreshes its OAuth token; mounted read-only the refresh
#                     cannot persist and the session eventually fails.
#   no /home tmpfs    podman 4.9.3 rejects uid=/gid= as tmpfs options, and --rm already
#                     discards the container's writable layer.
podman run -d -t --rm \
  --name "$NAME" \
  --userns=keep-id \
  --network arr \
  --security-opt no-new-privileges \
  --cap-drop=ALL \
  --tmpfs /tmp \
  -v "$ARR:/config:rw" \
  -v "$CREDS:/home/repair/.claude/.credentials.json:rw" \
  -v "$SEED/claude.json:/home/repair/.claude.json:rw" \
  -v "$SEED/settings.json:/home/repair/.claude/settings.json:ro" \
  --memory 2g --cpus 2 \
  "$IMAGE" \
  --remote-control "$SESSION" >/dev/null 2>&1

sleep 6
if podman container exists "$NAME" 2>/dev/null \
   && [ "$(podman inspect -f '{{.State.Status}}' "$NAME")" = "running" ]; then
  echo "repair session live, sandboxed to the arr suite."
  echo "Open Claude on your phone and pick the session named: $SESSION"
  echo "It can edit /config and call the arr APIs. It cannot restart containers -"
  echo "send 'restart <service>' here for that. Send 'repair stop' when finished."
else
  echo "session failed to start. Last output:"
  podman logs "$NAME" 2>&1 | tail -12
fi
