# Media stack deployer

Rebuilds a complete self-hosted media stack from a single filled-in config file:
Jellyfin, Jellyseerr, the arr suite, and a torrent client sealed inside a ProtonVPN
container with a structural killswitch — plus monitoring, phone alerting, and subtitles.

Rootless podman quadlets, systemd user units, no docker-compose, no root.

Built because the machine it runs on will get wiped at some point, and a wipe should
cost an afternoon rather than a weekend.

## Files

| | |
|---|---|
| `stack.env.example` | every variable, commented. Copy to `stack.env`, fill in, `chmod 600`. |
| `regenerate-templates.sh` | rebuilds `templates/` **from the live host**. Run after any quadlet change. |
| `deploy.sh` | `--check` (default) / `--render` / `--install` |
| `wire.sh` | post-start API wiring. Idempotent, `--dry-run` supported. |
| `templates/` | 20 quadlets + 9 systemd units + 3 scripts, generated not hand-written |

## What it needs

| | |
|---|---|
| podman | 4.9+ (tested on 4.9.3 and 5.4.2) |
| disk for images | **~20 GB.** 9.4 GB of that is the whisper ASR image alone — delete `templates/containers/whisper.container.tmpl` if you do not want generated subtitles and the requirement drops to ~9 GB. |
| `/dev/dri` | only for Jellyfin hardware transcoding. Without a render node podman refuses to start the container outright; delete the `AddDevice=/dev/dri` line to run software transcoding. |
| downloads + media | must be **one filesystem**, or the arr apps copy instead of hardlinking. `deploy.sh` refuses to continue otherwise. |
| tailscale | for the admin UIs, which bind to the tailnet address and loopback only. |

`deploy.sh --check` verifies all of these before it touches anything.

## Rebuild on a fresh machine

```bash
# 0. prerequisites: podman, systemd user session, tailscale, the media disk mounted
loginctl enable-linger "$USER"

# 1. configure
cp stack.env.example stack.env && chmod 600 stack.env && $EDITOR stack.env

# 2. look before you leap
./deploy.sh --render          # writes to ./out/, changes nothing

# 3. install and start
./deploy.sh --install

# 4. once the containers have settled (a minute or so)
./wire.sh
```

## The two-phase split, and why it exists

`deploy.sh` can only produce files. **Every arr app generates its own API key the first
time it runs**, so every cross-connection between them - download clients, Prowlarr's
applications, the FlareSolverr proxy - can only be made after the containers are up.
That is `wire.sh`, and it is the reason this is two steps rather than one.

## Templates are generated, never hand-edited

`regenerate-templates.sh` derives them from the live configuration. Hand-authored
templates drift from what actually runs and the drift is invisible until a rebuild
fails months later.

`deploy.sh --check` renders the templates back using this host's own values and diffs
them against the live files. **If that diff is not empty the templates have lost
something.** It has already earned its place: the first run caught that `jellyfin`
deliberately uses `PUID=0` while every other container uses `1000`, which a blanket
substitution had flattened.

Change a quadlet, then:

```bash
./regenerate-templates.sh && ./deploy.sh --check
```

## What stays manual - five things, none scriptable

1. **Tailscale**: `tailscale up` is an interactive browser login. Then
   `sudo tailscale set --operator=$USER` so `serve` works without root.
2. **The tailnet ACL**, if you share with a guest. Admin console only. See
   `docs/tailscale-acl-example.json` for a policy that restricts a shared guest to
   Jellyfin and Jellyseerr and nothing else, with self-verifying tests.
3. **ProtonVPN**: download a WireGuard config from account.protonvpn.com with a P2P
   server and **NAT-PMP enabled**, then paste the private key and address into
   `stack.env`. Without port forwarding, torrents get no incoming connections.
4. **Jellyfin's setup wizard** and admin account, plus Jellyseerr pointing at
   `http://jellyfin:8096`.
5. **The ntfy subscription** on the phone (both topics), and Uptime-Kuma's admin
   account before monitors can be created.

## Gotchas this deployer already encodes

- **`MEDIA_ROOT/downloads` and `MEDIA_ROOT/media` must be one filesystem.** `deploy.sh`
  refuses to continue otherwise. Different filesystems means the arr apps copy instead
  of hardlinking: double the disk, and seeding breaks when the download copy goes.
- **Deluge is `gluetun:8112`, never `deluge:8112`.** It runs inside gluetun's network
  namespace and has no address of its own.
- **SABnzbd is port 8080 container-to-container**, not the 8282 published on the host.
- **`PUID=0` on jellyfin is correct.** It is the one container without
  `UserNS=keep-id`, so container-root maps to the host user. Do not "fix" it to 1000.
- **gluetun must be up before deluge.** `deploy.sh` sleeps 20s after starting it, and
  the quadlet's `BindsTo=` enforces it thereafter.

## Not covered

Restoring *data* - configs, media, the Jellyfin library. That is what the encrypted
nightly rclone backup is for (`~/services/backup/`). This deployer rebuilds the
machinery, not the contents.
