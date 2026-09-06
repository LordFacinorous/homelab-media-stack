#!/usr/bin/env bash
# Render the media stack from stack.env and install it.
#
#   ./deploy.sh --check    render templates and DIFF against the live files.
#                          Proves the templates lost nothing. Changes nothing.
#   ./deploy.sh --render   render into ./out/ for inspection. Changes nothing.
#   ./deploy.sh --install  actually write units, create dirs, and start the stack.
#
# Default is --check, because the destructive option should be the one you type on
# purpose.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HERE/stack.env"
TPL="$HERE/templates"
MODE="${1:---check}"

# Only these are substituted. The script templates contain their own shell variables
# ($WORK, $JF, $svc...) which must survive untouched - hence the explicit allowlist
# rather than a bare envsubst.
VARS='${STACK_HOME} ${ARR_DIR} ${NTFY_DIR} ${MEDIA_ROOT} ${TAILNET_IP} ${TZ} ${PUID} ${PGID}'

die() { echo "ERROR: $*" >&2; exit 1; }
ok()  { echo "  ok    $*"; }
warn(){ echo "  WARN  $*"; }

[ -r "$ENV_FILE" ] || die "no stack.env - copy stack.env.example and fill it in"
set -a; . "$ENV_FILE"; set +a

# ---- validation ------------------------------------------------------------
echo "== validating stack.env =="
for v in STACK_HOME ARR_DIR NTFY_DIR MEDIA_ROOT TAILNET_IP TZ PUID PGID; do
  [ -n "${!v:-}" ] || die "$v is unset"
done
for v in WIREGUARD_PRIVATE_KEY NTFY_ALERT_TOPIC NTFY_CMD_TOPIC FIX_TOKEN; do
  case "${!v:-}" in
    *CHANGE_ME*|*PASTE_YOUR*|"") warn "$v still holds a placeholder" ;;
    *) ok "$v set" ;;
  esac
done

# The single most consequential check. If downloads and media are on different
# filesystems the arr apps silently copy instead of hardlinking: double disk usage,
# and seeding breaks when the download copy is removed.
if [ -d "$MEDIA_ROOT/downloads" ] && [ -d "$MEDIA_ROOT/media" ]; then
  a=$(stat -c %d "$MEDIA_ROOT/downloads"); b=$(stat -c %d "$MEDIA_ROOT/media")
  [ "$a" = "$b" ] && ok "downloads and media share one filesystem (hardlinks work)" \
                  || die "downloads and media are on DIFFERENT filesystems - hardlinks impossible"
fi
[ "$(id -u)" = "$PUID" ] && ok "PUID matches the running user" \
                         || warn "PUID=$PUID but you are $(id -u) - containers may write unreadable files"

# Where each rendered script belongs. The guard and the installer both use this, so a
# unit's ExecStart and the file's install location cannot drift apart.
script_dest() {
  case "$1" in
    backup.sh) echo "$STACK_HOME/services/backup" ;;
    *)         echo "$ARR_DIR" ;;
  esac
}

render_all() {
  local dest="$1"
  mkdir -p "$dest/containers" "$dest/systemd" "$dest/scripts"
  for f in "$TPL"/containers/*.tmpl; do
    [ -e "$f" ] || continue
    envsubst "$VARS" < "$f" > "$dest/containers/$(basename "${f%.tmpl}")"
  done
  for f in "$TPL"/systemd/*.tmpl; do
    [ -e "$f" ] || continue
    envsubst "$VARS" < "$f" > "$dest/systemd/$(basename "${f%.tmpl}")"
  done
  for f in "$TPL"/scripts/*.tmpl; do
    [ -e "$f" ] || continue
    envsubst "$VARS" < "$f" > "$dest/scripts/$(basename "${f%.tmpl}")"
    chmod +x "$dest/scripts/$(basename "${f%.tmpl}")"
  done
}

case "$MODE" in
--check)
  echo "== round-trip check: rendered templates vs the live files =="
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  render_all "$T"
  fail=0
  for f in "$T"/containers/*; do
    live="$HOME/.config/containers/systemd/$(basename "$f")"
    [ -e "$live" ] || { warn "no live counterpart: $(basename "$f")"; continue; }
    diff -q "$f" "$live" >/dev/null || { echo "  DIFFERS: $(basename "$f")"; diff "$live" "$f" | head -6; fail=1; }
  done
  for f in "$T"/systemd/*; do
    live="$HOME/.config/systemd/user/$(basename "$f")"
    [ -e "$live" ] || { warn "no live counterpart: $(basename "$f")"; continue; }
    diff -q "$f" "$live" >/dev/null || { echo "  DIFFERS: $(basename "$f")"; diff "$live" "$f" | head -6; fail=1; }
  done
  # Scripts were rendered but never compared - the drift check had a blind spot over
  # exactly the files that change most often. Found 2026-09-06 when livetv-guide.sh had
  # drifted and --check still reported "lossless".
  for f in "$T"/scripts/*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    live="$ARR_DIR/$b"
    [ -e "$live" ] || live="$HOME/services/backup/$b"
    [ -e "$live" ] || { warn "no live counterpart: $b"; continue; }
    diff -q "$f" "$live" >/dev/null || { echo "  DIFFERS: $b"; diff "$live" "$f" | head -6; fail=1; }
  done
  # ---- ExecStart guard --------------------------------------------------
  # Every unit's ExecStart must point at a real SYSTEM binary or at something the
  # deployer installs. Twice now a unit shipped referencing a file that was never
  # installed (ntfy control.py, then backfill.py); the round-trip diff cannot catch
  # that because both sides agree the file is simply absent.
  #
  # Only /usr, /bin and /sbin count as "system" - a path under $HOME existing on THIS
  # host proves nothing about a fresh machine, which is the whole point of the check.
  echo "== ExecStart guard: do units point at files the deployer installs? =="
  guard_out=$(mktemp)
  for f in "$T"/systemd/*; do
    [ -e "$f" ] || continue
    while IFS= read -r line; do
      for tok in $line; do
        case "$tok" in
          /usr/*|/bin/*|/sbin/*) [ -x "$tok" ] || echo "  MISSING BIN $(basename "$f"): $tok" >> "$guard_out"; continue ;;
          /*) : ;;
          *) continue ;;
        esac
        base=$(basename "$tok"); dir=$(dirname "$tok")
        # ntfy-control ships its own sources verbatim (not templated) into NTFY_DIR
        if [ -e "$HERE/ntfy-control/$base" ] && [ "$dir" = "$NTFY_DIR" ]; then
          continue
        fi
        if [ ! -e "$T/scripts/$base" ]; then
          echo "  NOT SHIPPED $(basename "$f"): $tok is never installed by deploy.sh" >> "$guard_out"
        elif [ "$dir" != "$(script_dest "$base")" ]; then
          echo "  MISPLACED   $(basename "$f"): wants $tok but it installs to $(script_dest "$base")" >> "$guard_out"
        fi
      done
    done < <(grep -h '^ExecStart=' "$f" 2>/dev/null | sed 's/^ExecStart=//')
  done
  if [ -s "$guard_out" ]; then cat "$guard_out"; fail=1; else echo "  all ExecStart paths resolve"; fi
  rm -f "$guard_out"

  [ $fail -eq 0 ] && echo "== round trip is lossless: templates reproduce the live stack exactly ==" \
                  || { echo "== templates do NOT reproduce the live stack (above) =="; exit 1; }
  ;;

--render)
  render_all "$HERE/out"
  echo "  rendered to $HERE/out (nothing installed)"
  ;;

--install)
  echo "== creating directories =="
  mkdir -p "$ARR_DIR/config" "$NTFY_DIR" "$MEDIA_ROOT"/{downloads,media/{movies,tvshows,music}} \
           "$MEDIA_ROOT/.recyclebin" "$HOME/.config/containers/systemd" "$HOME/.config/systemd/user"
  ok "directories"

  echo "== rendering into place =="
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  render_all "$T"
  cp "$T"/containers/* "$HOME/.config/containers/systemd/"
  cp "$T"/systemd/*    "$HOME/.config/systemd/user/"
  for f in "$T"/scripts/*; do
    [ -e "$f" ] || continue
    d=$(script_dest "$(basename "$f")"); mkdir -p "$d"
    cp "$f" "$d/" && chmod +x "$d/$(basename "$f")"
  done
  # the ntfy control channel's own program, referenced by ntfy-control.service
  mkdir -p "$NTFY_DIR/seed"
  cp "$HERE"/ntfy-control/control.py "$HERE"/ntfy-control/claude-contained.sh \
     "$HERE"/ntfy-control/Containerfile "$NTFY_DIR/" 2>/dev/null || true
  cp "$HERE"/ntfy-control/seed/settings.json "$NTFY_DIR/seed/" 2>/dev/null || true
  [ -e "$NTFY_DIR/seed/claude.json" ] || cp "$HERE"/ntfy-control/seed/claude.json.example \
     "$NTFY_DIR/seed/claude.json" 2>/dev/null || true
  chmod +x "$NTFY_DIR/claude-contained.sh" 2>/dev/null || true
  ok "units, scripts and ntfy-control sources"

  echo "== writing gluetun.env =="
  cat > "$ARR_DIR/config/gluetun.env" <<EOF
VPN_SERVICE_PROVIDER=${VPN_SERVICE_PROVIDER}
VPN_TYPE=${VPN_TYPE}
WIREGUARD_PRIVATE_KEY=${WIREGUARD_PRIVATE_KEY}
WIREGUARD_ADDRESSES=${WIREGUARD_ADDRESSES}
PORT_FORWARD_ONLY=on
VPN_PORT_FORWARDING=on
VPN_PORT_FORWARDING_PROVIDER=protonvpn
VPN_PORT_FORWARDING_STATUS_FILE=/gluetun/forwarded_port
DOT=on
DOT_PROVIDERS=cloudflare
FIREWALL_OUTBOUND_SUBNETS=${FIREWALL_OUTBOUND_SUBNETS}
TZ=${TZ}
EOF
  chmod 600 "$ARR_DIR/config/gluetun.env"
  ok "gluetun.env (0600)"

  echo "== ntfy control config =="
  mkdir -p "$NTFY_DIR"
  printf 'CMD_TOPIC=%s\nFIX_TOKEN=%s\n' "$NTFY_CMD_TOPIC" "$FIX_TOKEN" > "$NTFY_DIR/config.env"
  chmod 600 "$NTFY_DIR/config.env"
  printf '%s\n' "$NTFY_ALERT_TOPIC" > "$ARR_DIR/ntfy-topic.txt"
  chmod 600 "$ARR_DIR/ntfy-topic.txt"
  ok "ntfy topics (0600)"

  echo "== starting, in dependency order =="
  systemctl --user daemon-reload
  # gluetun first: deluge lives in its network namespace and cannot start without it.
  for u in gluetun deluge sonarr radarr lidarr prowlarr bazarr sabnzbd jellyfin \
           jellyseerr flaresolverr autobrr homepage uptime-kuma jellystat-db jellystat \
           whisper unpackerr; do
    [ -e "$HOME/.config/containers/systemd/$u.container" ] || continue
    systemctl --user start "$u.service" 2>/dev/null && ok "started $u" || warn "failed to start $u"
    [ "$u" = gluetun ] && sleep 20   # let the tunnel come up before deluge joins it
  done
  # Enable every timer/helper that has a template, rather than a hand-kept list that
  # silently omits anything added later (recordings-tidy and prime-backup were missed
  # exactly that way).
  systemctl --user enable --now deluge-portsync.path ntfy-control.service 2>/dev/null
  for t in "$HOME"/.config/systemd/user/*.timer; do
    [ -e "$t" ] || continue
    systemctl --user enable --now "$(basename "$t")" 2>/dev/null && ok "timer $(basename "$t")"
  done
  ok "timers and helpers"

  echo
  echo "Containers are up but NOT wired together yet - each app generates its own"
  echo "API key on first start. Give them a minute, then run:  ./wire.sh"
  ;;

*) die "unknown mode '$MODE' (use --check, --render or --install)" ;;
esac
