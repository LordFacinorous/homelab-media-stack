#!/usr/bin/env python3
"""
ntfy control channel for a self-hosted media stack.

Subscribes to a secret ntfy topic, runs whitelisted commands sent from a phone,
and replies to the same topic tagged 'robot' (those are skipped on the way in, so it
cannot talk to itself).

SECURITY MODEL - read this before extending:

  * ntfy.sh anonymous accounts get 0 topic reservations, so the topic cannot be ACL'd.
    The topic NAME is the credential. Anyone who learns it can send commands.
  * Therefore there is NO arbitrary shell here. Only DISPATCH entries run, and
    restart/logs only accept units in ALLOWED_UNITS.
  * 'repair' does not run Claude on this host. It launches a sandboxed container with
    Remote Control enabled, so the operator drives the session interactively from the Claude
    app rather than passing one-shot prompts through here. The container has only
    the arr services directory mounted and the arr network attached - no podman
    socket, no host filesystem, no route to any other subnet. A compromise of this
    command channel therefore cannot reach past the arr suite.
  * 'repair <token>' requires FIX_TOKEN, so a leaked topic name alone cannot start a
    session able to change anything. 'repair stop' and 'repair status' are open: they
    reduce privilege or read it, and gating those while `restart` stays open would be
    backwards.
"""
import collections
import json
import os
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

# Paths derive from this file's own location, so the program works wherever it is
# installed and needs no templating.
HERE = os.path.dirname(os.path.abspath(__file__))
SERVICES = os.path.dirname(HERE)
ARR_DIR = os.path.join(SERVICES, "arr")
CFG = os.path.join(HERE, "config.env")
conf = dict(
    line.strip().split("=", 1)
    for line in open(CFG)
    if "=" in line and not line.lstrip().startswith("#")
)
TOPIC = conf["CMD_TOPIC"]
FIX_TOKEN = conf["FIX_TOKEN"]
BASE = "https://ntfy.sh"
HOSTNAME = os.uname().nodename.upper()
RUNNER = os.path.join(HERE, "claude-contained.sh")

ALLOWED_UNITS = {
    "jellyfin", "jellyseerr", "sonarr", "radarr", "lidarr", "prowlarr", "bazarr",
    "deluge", "gluetun", "sabnzbd", "autobrr", "homepage", "uptime-kuma", "jellystat",
    "whisper", "flaresolverr", "recyclarr",
}
BUSY = threading.Lock()


# ntfy.sh anonymous accounts allow 250 published messages per DAY, per IP - and Kuma's
# outage alerts publish from this same IP. A command flood here would silently eat the
# budget that alerting depends on, and the first symptom would be an outage nobody is
# told about. Cap our own replies well below that and let alerts have the rest.
REPLY_TIMES = collections.deque(maxlen=64)
REPLY_LIMIT_PER_HOUR = 40


def say(msg, title=None, priority=3):
    now = time.time()
    while REPLY_TIMES and now - REPLY_TIMES[0] > 3600:
        REPLY_TIMES.popleft()
    if len(REPLY_TIMES) >= REPLY_LIMIT_PER_HOUR:
        print(f"reply suppressed (>{REPLY_LIMIT_PER_HOUR}/h, protecting the alert "
              f"budget): {msg[:60]}", file=sys.stderr, flush=True)
        return
    REPLY_TIMES.append(now)
    body = msg if len(msg) < 3500 else msg[:3500] + "\n...(truncated)"
    headers = {"Tags": "robot", "Priority": str(priority)}
    if title:
        headers["Title"] = title
    req = urllib.request.Request(
        f"{BASE}/{TOPIC}", data=body.encode(), method="POST", headers=headers
    )
    try:
        urllib.request.urlopen(req, timeout=20).read()
    except Exception as exc:
        print(f"reply failed: {exc}", file=sys.stderr, flush=True)


def sh(cmd, timeout=60):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return (r.stdout + r.stderr).strip() or "(no output)"
    except subprocess.TimeoutExpired:
        return f"timed out after {timeout}s"


def c_help(_):
    return (
        f"{HOSTNAME} control\n"
        "help             this list\n"
        "status           every monitor + container count\n"
        "vpn              tunnel exit IP, forwarded port, torrent states\n"
        "disk             cold-storage usage\n"
        "who              who is on jellyfin right now\n"
        "restart <svc>    restart one service\n"
        "logs <svc> [n]   last n log lines (default 20)\n"
        "repair <token>   start a sandboxed Claude session with Remote Control;\n"
        "                 drive it from the Claude app, not from here\n"
        "repair stop      end that session\n"
        "repair status    is it running\n"
        "\nservices: " + ", ".join(sorted(ALLOWED_UNITS))
    )


def c_status(_):
    db = os.path.join(ARR_DIR, "config/uptime-kuma/kuma.db")
    q = (
        "select m.name, case h.status when 1 then 'UP' when 0 then 'DOWN' else 'x' end "
        "from monitor m left join heartbeat h on h.id=(select max(id) from heartbeat "
        "where monitor_id=m.id) order by 2,1"
    )
    rows = sh(f'sqlite3 "{db}" "{q}"')
    lines = [r for r in rows.splitlines() if "|" in r]
    down = [r.split("|")[0] for r in lines if r.endswith("|DOWN")]
    containers = sh("podman ps -q | wc -l")
    if down:
        return "DOWN:\n" + "\n".join("  " + d for d in down) + f"\ncontainers up: {containers}"
    return f"all {len(lines)} monitors UP - {containers} containers up"


def c_vpn(_):
    ip = sh("podman exec deluge sh -c 'curl -s -m 10 https://ifconfig.io'", 30)
    port = sh(f"cat {ARR_DIR}/config/gluetun/forwarded_port")
    states = sh(
        "podman exec deluge deluge-console -c /config 'info' 2>/dev/null "
        "| grep -oE '^\\[[A-Za-z]\\]' | sort | uniq -c | tr '\\n' ' '",
        40,
    )
    return f"exit IP: {ip}\nforwarded port: {port}\ntorrents: {states}"


def c_disk(_):
    return sh("df -h /mnt/cold-storage / | awk 'NR==1 || /cold-storage|\\/$/'")


def c_who(_):
    # Done in-process: shelling this out meant nested quoting through bash into a
    # python -c, which is a silent-breakage generator.
    db = os.path.join(ARR_DIR, "config/jellyfin/data/data/jellyfin.db")
    key = sh(f"sqlite3 \"{db}\" 'select AccessToken from ApiKeys limit 1;'", 20)
    if not key or " " in key:
        return "could not read a jellyfin API key"
    try:
        req = urllib.request.Request(
            "http://127.0.0.1:8096/Sessions", headers={"X-Emby-Token": key}
        )
        sessions = json.loads(urllib.request.urlopen(req, timeout=15).read())
    except Exception as exc:
        return f"jellyfin query failed: {exc}"
    lines = []
    for s in sessions:
        now = s.get("NowPlayingItem")
        playing = now.get("Name") if now else "idle"
        lines.append(f"{s.get('UserName')} - {s.get('Client')} - {playing}")
    return "\n".join(lines) or "nobody connected"


def c_restart(arg):
    svc = arg.strip().split()[0] if arg.strip() else ""
    if svc not in ALLOWED_UNITS:
        return f"'{svc}' is not on the list. one of: {', '.join(sorted(ALLOWED_UNITS))}"
    sh(f"systemctl --user restart {svc}.service", 120)
    time.sleep(6)
    state = sh(f"systemctl --user is-active {svc}.service")
    # A restarted container gets a NEW IP on the arr bridge, and uptime-kuma's resolver
    # keeps the old one - it then reports the service DOWN with EHOSTUNREACH against a
    # dead address while the service is perfectly healthy. That false alarm nags until
    # dismissed. Bouncing kuma clears its cache. Observed for real: jellyfin moved
    # 10.89.1.55 -> .72 and kuma called it down for 8 minutes.
    extra = ""
    if svc != "uptime-kuma" and state == "active":
        sh("systemctl --user restart uptime-kuma.service", 120)
        extra = " (monitoring refreshed so it doesn't false-alarm on the new IP)"
    return f"{svc}: {state}{extra}"


def c_logs(arg):
    parts = arg.split()
    svc = parts[0] if parts else ""
    n = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 20
    if svc not in ALLOWED_UNITS:
        return f"'{svc}' is not on the list."
    n = min(n, 60)
    return sh(f"podman logs --tail {n} {svc} 2>&1 | tail -{n}", 40)


def c_repair(arg):
    """Start/stop/inspect the sandboxed Remote Control session.

    Nothing is prompted through ntfy: this only launches the session. the operator then
    drives it interactively from the Claude app, which is what Remote Control is for.
    """
    parts = arg.strip().split()
    sub = parts[0] if parts else ""
    # 'status' and 'stop' are both open. Requiring a token to STOP was a mistake:
    # stopping reduces privilege, and `restart gluetun` - which drops the VPN - needs
    # no token at all. Gating the safe direction while the disruptive one stays open
    # is backwards, and it is daily friction for no real protection.
    # 'start' still needs the token, because that is what grants Claude write access.
    if sub == "status":
        try:
            r = subprocess.run(["/bin/bash", RUNNER, "status"],
                               capture_output=True, text=True, timeout=60)
            return (r.stdout or r.stderr or "(no output)").strip()
        except subprocess.TimeoutExpired:
            return "repair status timed out"
    if sub == "stop":
        try:
            r = subprocess.run(["/bin/bash", RUNNER, "stop"],
                               capture_output=True, text=True, timeout=60)
            return (r.stdout or r.stderr or "(no output)").strip()
        except subprocess.TimeoutExpired:
            return "repair stop timed out"
    if sub != FIX_TOKEN:
        return ("repair needs the token: repair <token>\n"
                "or: repair stop | repair status")
    say("starting sandboxed session...", title="repair", priority=2)
    try:
        r = subprocess.run(["/bin/bash", RUNNER, "start"],
                           capture_output=True, text=True, timeout=180)
        return (r.stdout or r.stderr or "(no output)").strip()
    except subprocess.TimeoutExpired:
        return "session start timed out after 180s"


DISPATCH = {
    "help": c_help, "status": c_status, "vpn": c_vpn, "disk": c_disk, "who": c_who,
    "restart": c_restart, "logs": c_logs, "repair": c_repair,
}


def handle(text):
    verb, _, rest = text.strip().partition(" ")
    fn = DISPATCH.get(verb.lower())
    if fn is None:
        return None
    if not BUSY.acquire(blocking=False):
        return "busy with the previous command, try again in a moment"
    try:
        return fn(rest)
    except Exception as exc:
        return f"{verb} failed: {exc}"
    finally:
        BUSY.release()


def main():
    say("control channel online - send 'help'", title=HOSTNAME, priority=2)
    # No `since` on the first connect: that streams new messages only, which is what we
    # want - a restart must not replay old commands. ntfy rejects since=now with a 400;
    # valid forms are `all`, a duration, a unix timestamp, or a message id.
    since = None
    # ntfy's `since` is inclusive, so after a reconnect the last message is redelivered.
    # Without this, a dropped stream would re-run the previous command - which for
    # `restart sonarr` means a second unasked-for restart. Track ids instead.
    seen = collections.deque(maxlen=200)
    while True:
        try:
            url = f"{BASE}/{TOPIC}/json"
            if since is not None:
                url += f"?since={urllib.parse.quote(str(since))}"
            with urllib.request.urlopen(url, timeout=None) as stream:
                for line in stream:
                    if not line.strip():
                        continue
                    msg = json.loads(line)
                    if msg.get("event") != "message":
                        continue
                    since = msg.get("time", since)
                    mid = msg.get("id")
                    if mid and mid in seen:
                        continue
                    if mid:
                        seen.append(mid)
                    if "robot" in (msg.get("tags") or []):
                        continue
                    text = (msg.get("message") or "").strip()
                    if not text:
                        continue
                    print(f"cmd: {text[:80]}", flush=True)
                    out = handle(text)
                    if out is not None:
                        say(out, title=text.split()[0][:24])
        except Exception as exc:
            print(f"stream error: {exc}; reconnecting in 10s", file=sys.stderr, flush=True)
            time.sleep(10)


if __name__ == "__main__":
    main()
