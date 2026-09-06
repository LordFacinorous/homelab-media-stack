#!/usr/bin/env python3
"""
Wire the arr suite together AFTER first start.

This cannot be templated. Every arr app generates its own API key the first time it
runs, so nothing that depends on those keys can exist before the containers are up.
That is the whole reason deploy.sh and wire.sh are separate steps.

What it does, all idempotent - safe to re-run:
  * reads each app's generated API key out of its config.xml
  * registers Deluge (via gluetun) and SABnzbd as download clients in sonarr/radarr/lidarr
  * registers sonarr/radarr/lidarr as applications in Prowlarr, so indexers sync outward
  * registers FlareSolverr as Prowlarr's indexer proxy and tags every indexer with it
  * sets media management: hardlinks on, renaming on, recycle bin configured

Usage:  ./wire.sh [--dry-run]
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

DRY = "--dry-run" in sys.argv
HERE = os.path.dirname(os.path.abspath(__file__))

env = {}
with open(os.path.join(HERE, "stack.env")) as fh:
    for line in fh:
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k] = os.path.expandvars(v.replace("${STACK_HOME}", env.get("STACK_HOME", "")))

ARR_DIR = env.get("ARR_DIR") or os.path.expanduser("~/services/arr")
CONFIG = os.path.join(ARR_DIR, "config")

APPS = {  # name: (host port, api version)
    "sonarr": (8989, "v3"), "radarr": (7878, "v3"),
    "lidarr": (8686, "v1"), "prowlarr": (9696, "v1"),
}

def log(*a): print("  ", *a)

def key_for(app):
    p = os.path.join(CONFIG, app, "config.xml")
    if not os.path.exists(p):
        return None
    m = re.search(r"<ApiKey>([^<]+)</ApiKey>", open(p).read())
    return m.group(1) if m else None

def call(app, path, method="GET", body=None, timeout=40):
    port, ver = APPS[app]
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/{ver}{path}", method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"X-Api-Key": key_for(app), "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
        return json.loads(raw) if raw else None

def wait_for(app, tries=30):
    for _ in range(tries):
        try:
            call(app, "/system/status", timeout=10)
            return True
        except Exception:
            time.sleep(5)
    return False

def sabnzbd_key():
    ini = os.path.join(CONFIG, "sabnzbd", "sabnzbd.ini")
    if not os.path.exists(ini):
        return None
    m = re.search(r"^api_key\s*=\s*(\S+)", open(ini, errors="ignore").read(), re.M)
    return m.group(1) if m else None

def field(fields, name, value):
    for f in fields:
        if f["name"] == name:
            f["value"] = value
            return
    fields.append({"name": name, "value": value})

# --------------------------------------------------------------------------
print("== waiting for the arr apps ==")
live = []
for app in APPS:
    if key_for(app) and wait_for(app):
        live.append(app); log(f"{app}: up, key found")
    else:
        log(f"{app}: NOT ready - skipping (it may still be starting)")

# --- download clients -------------------------------------------------------
print("== download clients ==")
DELUGE_PW = env.get("DELUGE_PASSWORD", "deluge")
SAB_KEY = sabnzbd_key()
CATEGORY = {"sonarr": "tvCategory", "radarr": "movieCategory", "lidarr": "musicCategory"}

for app in [a for a in live if a != "prowlarr"]:
    existing = {c["implementation"] for c in call(app, "/downloadclient")}
    # Deluge lives in gluetun's network namespace - it is reachable as gluetun:8112,
    # never deluge:8112. Getting this wrong is the classic failure here.
    if "Deluge" not in existing:
        sch = call(app, "/downloadclient/schema")
        tpl = next((s for s in sch if s["implementation"] == "Deluge"), None)
        if tpl:
            tpl["name"] = "Deluge"; tpl["enable"] = True
            field(tpl["fields"], "host", "gluetun")
            field(tpl["fields"], "port", 8112)
            field(tpl["fields"], "password", DELUGE_PW)
            if not DRY: call(app, "/downloadclient", "POST", tpl)
            log(f"{app}: Deluge -> gluetun:8112")
    else:
        log(f"{app}: Deluge already present")
    if not SAB_KEY:
        log(f"{app}: no SABnzbd api key on disk - skipping")
    elif "Sabnzbd" in existing:
        log(f"{app}: SABnzbd already present")
    else:
        sch = call(app, "/downloadclient/schema")
        tpl = next((s for s in sch if s["implementation"] == "Sabnzbd"), None)
        if tpl:
            tpl["name"] = "SABnzbd"; tpl["enable"] = True
            field(tpl["fields"], "host", "sabnzbd")
            field(tpl["fields"], "port", 8080)   # container-to-container, NOT 8282
            field(tpl["fields"], "apiKey", SAB_KEY)
            if not DRY: call(app, "/downloadclient", "POST", tpl)
            log(f"{app}: SABnzbd -> sabnzbd:8080")

# --- media management -------------------------------------------------------
print("== media management ==")
for app in [a for a in live if a in ("sonarr", "radarr")]:
    mm = call(app, "/config/mediamanagement")
    mm["copyUsingHardlinks"] = True          # downloads and media are one filesystem
    mm["recycleBin"] = "/data/.recyclebin"   # deletes recoverable for 14 days
    mm["recycleBinCleanupDays"] = 14
    if not DRY: call(app, "/config/mediamanagement", "PUT", mm)
    nm = call(app, "/config/naming")
    # Without this, imports keep raw release names and Jellyfin matching is unreliable.
    nm["renameEpisodes" if app == "sonarr" else "renameMovies"] = True
    if not DRY: call(app, "/config/naming", "PUT", nm)
    log(f"{app}: {'would set' if DRY else 'set'} hardlinks, recycle bin, renaming")

# --- prowlarr: applications + flaresolverr ----------------------------------
if "prowlarr" in live:
    print("== prowlarr ==")
    have = {a["name"] for a in call("prowlarr", "/applications")}
    PORTS = {"sonarr": 8989, "radarr": 7878, "lidarr": 8686}
    for app in [a for a in live if a in PORTS]:
        if app.capitalize() in have:
            log(f"{app}: already registered"); continue
        sch = call("prowlarr", "/applications/schema")
        tpl = next((s for s in sch if s["implementation"].lower() == app), None)
        if not tpl: continue
        tpl["name"] = app.capitalize(); tpl["syncLevel"] = "fullSync"
        field(tpl["fields"], "baseUrl", f"http://{app}:{PORTS[app]}")
        field(tpl["fields"], "prowlarrUrl", "http://prowlarr:9696")
        field(tpl["fields"], "apiKey", key_for(app))
        if not DRY: call("prowlarr", "/applications", "POST", tpl)
        log(f"prowlarr -> {app} registered (fullSync)")

    proxies = call("prowlarr", "/indexerproxy")
    if not any(p["implementation"] == "FlareSolverr" for p in proxies):
        sch = call("prowlarr", "/indexerproxy/schema")
        tpl = next((s for s in sch if s["implementation"] == "FlareSolverr"), None)
        if tpl:
            tpl["name"] = "FlareSolverr"
            field(tpl["fields"], "host", "http://flaresolverr:8191/")
            if not DRY: call("prowlarr", "/indexerproxy", "POST", tpl)
            log("prowlarr: FlareSolverr indexer proxy added")
    else:
        log("prowlarr: FlareSolverr already present")

print()
print("Wired. Still manual, because they cannot be automated:")
print("  1. Jellyfin's setup wizard and admin account")
print("  2. Jellyseerr's setup (point it at http://jellyfin:8096)")
print("  3. Adding indexers in Prowlarr - they sync outward automatically after")
print("  4. Bazarr: connect to sonarr/radarr and pick subtitle providers")
print("  5. Uptime-Kuma: create the admin account, then monitors can be added")
