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

# jellyfin.container passes /dev/dri through for VAAPI hardware transcoding. On a host
# with no render node podman refuses to start it at all ("stat /dev/dri: no such file or
# directory") - it does not quietly fall back to software. Say so here rather than let it
# look like a jellyfin fault.
# Container images for the full stack are about 18 GB, and 9.4 GB of that is the whisper
# ASR image alone. Running out mid-pull leaves a half-installed stack whose failures look
# like anything but a full disk, so check before starting rather than after.
graphroot="${HOME}/.local/share/containers"
mkdir -p "$graphroot"
free_g=$(df -BG --output=avail "$graphroot" 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "$free_g" ]; then
  if grep -q '^Image=' "$TPL/containers/whisper.container.tmpl" 2>/dev/null; then
    need=20; hint="Delete templates/containers/whisper.container.tmpl to save 9.4G (subtitles only)."
  else
    need=10; hint="Free space or move \$HOME/.local/share/containers to a bigger disk."
  fi
  if [ "$free_g" -ge "$need" ]; then
    ok "${free_g}G free for images (need ~${need}G)"
  else
    warn "only ${free_g}G free at $graphroot - the images need ~${need}G."
    warn "      $hint"
  fi
fi

jf_tmpl="$TPL/containers/jellyfin.container.tmpl"
if ! grep -q '^AddDevice=/dev/dri' "$jf_tmpl" 2>/dev/null; then
  ok "jellyfin configured for software transcoding (no /dev/dri passthrough)"
elif [ -e /dev/dri ]; then
  ok "/dev/dri present (jellyfin hardware transcoding)"
else
  warn "no /dev/dri - jellyfin will NOT start. Delete the AddDevice=/dev/dri line from"
  warn "      $jf_tmpl to run software transcoding."
fi

# Where each rendered script belongs. The guard and the installer both use this, so a
# unit's ExecStart and the file's install location cannot drift apart.
# templates/scripts/MANIFEST says which directory each script came from, written by
# regenerate-templates.sh. Reading it beats a hand-kept case list here: the list version
# would silently send a newly added backup script to ARR_DIR, and the only symptom would
# be a unit whose ExecStart points at a file that is not there.
script_dest() {
  local tok
  tok=$(awk -v n="$1" '$1 == n {print $2; exit}' "$TPL/scripts/MANIFEST" 2>/dev/null)
  case "$tok" in
    backup) echo "$STACK_HOME/services/backup" ;;
    *)      echo "$ARR_DIR" ;;
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
    b=$(basename "${f%.tmpl}")
    envsubst "$VARS" < "$f" > "$dest/scripts/$b"
    # Only actual programs get +x. exclude.txt is data that scripts read, and marking it
    # executable says something false about what it is.
    case "$b" in *.sh|*.py) chmod +x "$dest/scripts/$b" ;; esac
  done
}

case "$MODE" in
--check)
  echo "== round-trip check: rendered templates vs the live files =="
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  render_all "$T"
  fail=0
  compared=0   # how many rendered files actually had a live file to diff against
  for f in "$T"/containers/*; do
    live="$HOME/.config/containers/systemd/$(basename "$f")"
    [ -e "$live" ] || { warn "no live counterpart: $(basename "$f")"; continue; }
    compared=$((compared+1))
    diff -q "$f" "$live" >/dev/null || { echo "  DIFFERS: $(basename "$f")"; diff "$live" "$f" | head -6; fail=1; }
  done
  for f in "$T"/systemd/*; do
    live="$HOME/.config/systemd/user/$(basename "$f")"
    [ -e "$live" ] || { warn "no live counterpart: $(basename "$f")"; continue; }
    compared=$((compared+1))
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
    compared=$((compared+1))
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
  # Second half of the same class: a script that sources another file. `sources.sh` is
  # shared by both backup scripts, and a shipped script sourcing an unshipped one fails on
  # a fresh machine exactly like a unit pointing at a missing binary - except no unit
  # mentions it, so the ExecStart pass above is blind to it.
  for f in "$T"/scripts/*; do
    [ -e "$f" ] || continue
    while IFS= read -r dep; do
      b=$(basename "$dep")
      [ -e "$T/scripts/$b" ] || echo "  NOT SHIPPED $(basename "$f"): sources $dep, which deploy.sh never installs" >> "$guard_out"
    done < <(grep -hoE '^[[:space:]]*\.[[:space:]]+/[^ "'"'"']+' "$f" 2>/dev/null | awk '{print $2}')
  done
  if [ -s "$guard_out" ]; then cat "$guard_out"; fail=1; else echo "  all ExecStart paths resolve"; fi
  rm -f "$guard_out"

  # On a machine with no stack installed there is nothing to diff against, and saying
  # "reproduces the live stack exactly" there is a lie - it compared zero files.
  if [ $fail -ne 0 ]; then
    echo "== templates do NOT reproduce the live stack (above) =="; exit 1
  elif [ $compared -eq 0 ]; then
    echo "== nothing installed here yet: templates render and every ExecStart resolves,"
    echo "   but there is no live stack to compare against. Run ./deploy.sh --install =="
  else
    echo "== round trip is lossless: $compared live files reproduced exactly =="
  fi
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

  # Every Volume host path has to exist before podman starts. Podman does not create a
  # bind-mount source; it fails with "statfs <path>: no such file or directory", the unit
  # hits its restart limit in under a second, and every container in the stack dies the
  # same way. Deriving the list from the rendered units rather than hard-coding it means
  # a container added later cannot be forgotten here.
  # Found 2026-09-06 on a clean Debian 13 VM - on the host this was written on the
  # config directories already existed, so the omission was invisible.
  vdirs=0
  while IFS= read -r hostpath; do
    case "$hostpath" in /*) ;; *) continue ;; esac
    [ -d "$hostpath" ] || { mkdir -p "$hostpath" && vdirs=$((vdirs+1)); }
  done < <(sed -n 's/^Volume=\([^:]*\):.*/\1/p' "$T"/containers/*.container | sort -u)
  ok "bind-mount directories ($vdirs created)"

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

  # jellystat-db and jellystat share one EnvironmentFile. Without it BOTH units fail
  # with "parsing file .../jellystat.env: no such file or directory" - and because the
  # file existed on the host this was written on, that never showed up until a clean
  # install (2026-09-06, Debian 13 VM).
  # Written once and never rewritten: postgres bakes the password in at initdb time, so
  # changing it later locks jellystat out of its own database.
  if [ -e "$ARR_DIR/config/jellystat.env" ]; then
    ok "jellystat.env already exists (left alone - the db password is baked into postgres)"
  else
    jpw="${JELLYSTAT_DB_PASSWORD:-}"; [ -n "$jpw" ] || jpw=$(head -c 18 /dev/urandom | base64)
    jjwt="${JELLYSTAT_JWT_SECRET:-}"; [ -n "$jjwt" ] || jjwt=$(head -c 18 /dev/urandom | base64)
    cat > "$ARR_DIR/config/jellystat.env" <<EOF
POSTGRES_USER=jellystat
POSTGRES_PASSWORD=${jpw}
POSTGRES_DB=jfstat
JWT_SECRET=${jjwt}
EOF
    chmod 600 "$ARR_DIR/config/jellystat.env"
    ok "jellystat.env (0600, generated)"
  fi

  echo "== ntfy control config =="
  mkdir -p "$NTFY_DIR"
  printf 'CMD_TOPIC=%s\nFIX_TOKEN=%s\n' "$NTFY_CMD_TOPIC" "$FIX_TOKEN" > "$NTFY_DIR/config.env"
  chmod 600 "$NTFY_DIR/config.env"
  printf '%s\n' "$NTFY_ALERT_TOPIC" > "$ARR_DIR/ntfy-topic.txt"
  chmod 600 "$ARR_DIR/ntfy-topic.txt"
  ok "ntfy topics (0600)"

  systemctl --user daemon-reload

  # Pull before starting. A unit still pulling a multi-gigabyte image runs past
  # TimeoutStartSec and is reported as "failed to start" when nothing is actually wrong,
  # which sends you debugging a non-problem on every fresh install. This is the slow
  # step - roughly 6 GB the first time.
  echo "== pulling images (first install: this is the slow part) =="
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    podman image exists "$img" 2>/dev/null && continue
    printf '  %-46s ' "$img"
    perr=$(mktemp)
    if podman pull -q "$img" >/dev/null 2>"$perr"; then
      echo ok
    else
      # Say why. "FAILED" alone sends you looking in the wrong place - the usual cause
      # is a full disk, not a bad image reference.
      echo "FAILED - $(tail -1 "$perr" | cut -c1-90)"
    fi
    rm -f "$perr"
  done < <(sed -n 's/^Image=//p' "$T"/containers/*.container | sort -u)

  echo "== starting, in dependency order =="
  failed=""
  # gluetun first: deluge lives in its network namespace and cannot start without it.
  for u in gluetun deluge sonarr radarr lidarr prowlarr bazarr sabnzbd jellyfin \
           jellyseerr flaresolverr autobrr homepage uptime-kuma jellystat-db jellystat \
           whisper unpackerr; do
    [ -e "$HOME/.config/containers/systemd/$u.container" ] || continue
    if systemctl --user start "$u.service" 2>/dev/null; then
      ok "started $u"
    else
      # Say WHY. Swallowing the reason is what makes a fresh install feel unfixable.
      warn "failed to start $u: $(journalctl --user -u "$u.service" -n 20 --no-pager -o cat 2>/dev/null |
              grep -iE 'error|cannot|no such|denied|refused' | tail -1 | cut -c1-100)"
      failed="$failed $u"
    fi
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
  if [ -n "$failed" ]; then
    # Reporting "containers are up" while half of them are dead is how an install looks
    # fine and behaves broken.
    echo "These did NOT start:$failed"
    echo "  systemctl --user status <name>      journalctl --user -u <name> -n 40"
    echo "Fix them before ./wire.sh - it reads each app's API key from a running app."
    exit 1
  fi
  echo "Containers are up but NOT wired together yet - each app generates its own"
  echo "API key on first start. Give them a minute, then run:  ./wire.sh"
  ;;

*) die "unknown mode '$MODE' (use --check, --render or --install)" ;;
esac
