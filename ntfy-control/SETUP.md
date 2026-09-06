# ntfy control channel — finishing the install

Everything is written. The commands below are left to you because Claude Code's
permission classifier blocked me from building the image, marking the runner executable,
and even syntax-checking the scripts. Reasonably so — it is an image that runs Claude
with your account credentials, launched from a topic whose name is its only credential.

**Nothing here has been executed or tested.** Treat the first run as a smoke test.

---

## 1. Build the repair sandbox (optional)

    cd ~/services/ntfy-control
    podman build -t localhost/claude-repair:latest .
    chmod +x claude-contained.sh

Without it, `repair` replies "sandbox not built" and every other command works normally.

## 2. Start the daemon

    python3 -c "import ast; ast.parse(open('control.py').read())" && echo ok
    bash -n claude-contained.sh && echo ok
    systemctl --user daemon-reload
    systemctl --user enable --now ntfy-control.service
    systemctl --user status ntfy-control.service --no-pager

The first two lines are the syntax checks I was blocked from running. Do them first.
The daemon announces itself on the command topic when it comes up.

## 3. Subscribe on your phone

Add the topic in `config.env` (CMD_TOPIC, mode 0600) alongside the alerts topic, and
send `help`.

---

## Commands

    help             the list
    status           every monitor + container count
    vpn              tunnel exit IP, forwarded port, torrent states
    disk             cold-storage usage
    who              who is on jellyfin right now
    restart <svc>    restart one service (whitelisted units only)
    logs <svc> [n]   last n log lines, default 20, capped at 60
    repair <token>   start a sandboxed Claude session with Remote Control
    repair stop      end it
    repair status    is it running

---

## Why `repair` launches Remote Control instead of prompting through ntfy

The first version passed a prompt over ntfy, ran `claude -p` once, and sent truncated
text back. That was a worse version of something Claude Code already does. the operator pointed
this out: sessions on this account come up with Remote Control, which pairs them to the
Claude app.

So `repair` now **starts a session** — `claude --remote-control prime-arr-repair` inside
the sandbox — and you drive it interactively from your phone. Full conversation, no
truncation, no timeout, no prompt-passing through a third party.

That leaves a clean split:

- **ntfy** for one-word operational answers you want in three seconds: `status`, `vpn`,
  `who`, `restart sonarr`. Faster than opening an app.
- **Remote Control** for anything requiring actual thought.

The container runs `-d -t` (detached with a TTY) because `--remote-control` starts an
interactive session and expects a terminal. **This is the least-tested part of the whole
setup** — if the session dies immediately, that is the first thing to check, and
`claude-contained.sh` prints the container's last output on failure.

---

## Security model — read before extending this

**The topic name is the credential.** ntfy.sh anonymous accounts get 0 topic
reservations, so the topic cannot be access-controlled. Anyone who learns the name can
send commands. It lives in `config.env`, mode 0600. Treat it like a password.

The design assumes the topic *will* leak eventually:

- **No arbitrary shell.** Only functions in `DISPATCH` run. `restart` and `logs` accept
  only units in `ALLOWED_UNITS`. A leaked topic gets an attacker service restarts and log
  reads — annoying, not catastrophic.
- **`repair` needs a second factor.** `FIX_TOKEN` must be the first argument, so a leaked
  topic name alone cannot start a session capable of changing anything.
- **Claude never runs on the host.** The sandbox mounts only `~/services/arr`, joins the
  `arr` bridge, drops all capabilities, sets no-new-privileges, uses a tmpfs home, and
  gets **no podman socket** — so it cannot create containers, reach the host filesystem,
  or route to any other subnet. It cannot restart containers either; it reports what
  needs restarting and you send `restart` over ntfy.

### Residual risks, stated plainly

1. **Your Claude OAuth credentials are mounted into the sandbox** read-only. A container
   escape, or a prompt injection convincing the session to print that file, exposes the
   token. Inherent to running Claude anywhere, but this path is phone-triggered, which is
   a different risk profile from a terminal you are sitting at.
2. **The sandbox has outbound internet.** It must, to reach Anthropic. So "contained"
   means contained from your other hosts and from the host filesystem — not air-gapped.
3. **Prompt injection through repaired content.** The session reads config files and API
   responses. Hostile content there could steer it. The sandbox is what bounds the blast
   radius; that is the whole reason it exists.
4. **ntfy.sh is a third party.** Command text and replies cross it in the clear. Do not
   send secrets over this channel. Note `repair <token>` puts the token in the topic
   history — rotate it in `config.env` if that ever matters.

### If the topic leaks

Generate a new name, update `CMD_TOPIC`, restart the service, resubscribe on the phone.
Nothing else depends on the old name.

---

## The sandboxed session's own instructions

It reads `~/services/arr/CLAUDE.md` — its working root is that directory, mounted as
`/config`. That file defines its containment, its reply style, and the stack-specific
traps already paid for once (hardlinks are load-bearing, deluge is `gluetun:8112`,
container IPs change every restart, rootless podman rewrites source IPs, `keep-id` breaks
images that write to root-owned paths).

`~/services/arr/LESSONS.md` sits beside it with seven entries from the session that built
this stack, and the agent is told to append to it.

Keep both current. They are the difference between an agent that repeats this session's
mistakes and one that starts where it left off.
