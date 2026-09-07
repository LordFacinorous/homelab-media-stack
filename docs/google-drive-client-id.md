# The backup needs its own Google API client_id

## What went wrong

2026-09-06, 03:51. Two of ten pairs — `projects` and `arr-config`, the two with by far
the most files — died with HTTP 403:

```
"quota_limit": "defaultPerMinutePerProject",
"quota_metric": "drive.googleapis.com/default",
"quota_unit": "1/min/{project}",
"reason": "RATE_LIMIT_EXCEEDED"
```

`defaultPerMinutePerProject` is the quota of **rclone's built-in client_id**, which every
rclone user on earth shares. `rclone config show gdrive` has no `client_id` line, so this
host is drawing on that shared bucket. The old settings here — 24 transfers, 24 checkers,
a 10ms pacer and a burst of 200 — meant it arrived at that bucket with 48 concurrent
workers and no brakes.

Nothing reported the failure. `prime-backup.service` recorded `ExecMainStatus=0`,
`Result=success`. Both of those are now fixed in `backup.sh` and the unit, and the brakes
in `RCLONE_OPTS` are enough to keep it succeeding.

## The actual fix, which needs a Google account

A dedicated client_id moves this off the shared quota onto its own. It takes about five
minutes and is free.

1. https://console.cloud.google.com/ → create a project (any name).
2. APIs & Services → Library → **Google Drive API** → Enable.
3. **Google Auth Platform** → **Get started**.

   Google replaced the old "APIs & Services → OAuth consent screen" page with the
   **Google Auth Platform**, and there is no longer an External/Internal choice sitting
   on a page of its own. It is step 2 of a four-step wizard that only appears after you
   click **Get started**, so on a fresh project the console shows "Google Auth Platform
   not configured yet" and nothing else — verified on screen 2026-09-06.

   The wizard, in order:

   1. **App Information** — App name, User support email (your own address, offered in a
      dropdown) → Next
   2. **Audience** — **← "External" is HERE.** Two radio buttons, Internal and External.
   3. **Contact Information** — an email address for Google to notify about the project.
   4. **Finish** — tick *I agree to the Google API Services: User Data Policy* → Continue
      → **Create**.

   Leave the app in **Testing** and add your own Google account under **Test users**
   (Audience → Test users, after the wizard). Testing-mode refresh tokens expire after 7
   days *only* for apps that never got verified AND use sensitive scopes; `drive.file`,
   which this remote uses, is not sensitive, so the token persists. If you ever widen the
   scope, publish the app.

4. **Google Auth Platform → Clients** → Create client → Application type **Desktop app**.
   (This is the old "APIs & Services → Credentials → OAuth client ID"; it now lives under
   Clients in the Auth Platform's left nav.) **Download JSON** on the confirmation dialog —
   the client secret is shown once and never again, and the JSON is the easiest way to get
   both values onto the host without retyping them.

4a. **Two things the wizard does NOT finish**, both of which block the consent screen and
   neither of which is obvious (found 2026-09-06 after the wizard reported success):

   - **Audience → Test users → Add users → your own Google address.** In Testing mode
     only listed test users may authorise, and *the project owner is not automatically
     one*. With an empty list, consent fails with `access_denied` and the error does not
     mention test users. The Create-client dialog says this in passing: "OAuth access is
     restricted to the test users listed on your OAuth consent screen."
   - **Branding.** The Audience page shows "Your app's OAuth configuration is incomplete.
     You must enter the missing information to proceed. Please visit the Branding page to
     finish configuring your app." Fill in whatever Branding flags as missing. The banner
     carries a **Go to Branding** button.

   Check both before running the auth, or you will debug a consent failure that has
   nothing to do with rclone.
5. On PRIME:

   The interactive `rclone config` walk is optional - the two values can be written
   straight into the remote, which is what was done here:

   ```
   # from the downloaded client_secret_*.json, without echoing the secret
   python3 - ~/Downloads/client_secret_*.json ~/.config/rclone/rclone.conf <<'EOF'
   import json, sys, configparser
   d = json.load(open(sys.argv[1])); inst = d.get("installed") or d.get("web")
   cp = configparser.RawConfigParser(); cp.optionxform = str; cp.read(sys.argv[2])
   cp["gdrive"]["client_id"] = inst["client_id"]
   cp["gdrive"]["client_secret"] = inst["client_secret"]
   cp.write(open(sys.argv[2], "w"), space_around_delimiters=True)
   EOF
   chmod 600 ~/.config/rclone/rclone.conf
   ```

   The existing token was issued to rclone's shared client and stays bound to it, so the
   new client_id changes nothing until the remote is re-authorised:

   ```
   rclone config reconnect gdrive: --auto-confirm
   ```

   That prints a `http://127.0.0.1:53682/auth?state=...` link and waits. Open it, pick the
   Google account, and approve. Expect an "unverified app" interstitial - that is normal
   for an app in Testing; click Advanced -> Go to <app name> (unsafe). It is your own
   client asking for access to your own Drive.

6. Prove it took, and that the credential is not empty:

   ```
   rclone config show gdrive | grep client_id
   rclone lsd gdrive-crypt: --tpslimit 10
   ```

7. Once that works, the brakes in `backup.sh` can be relaxed if you want more speed —
   `--transfers 8 --checkers 16 --tpslimit 20`. There is no reason to go higher: the
   uplink is ~19.5 Mbit and the old 24/24 was buying nothing but 403s.

## STOP - read this before switching client_id on this remote

**The dedicated client_id was set up, authorised successfully, and then reverted. Here is
why, because the trap is not obvious and it cost nothing only because it was checked.**

This remote uses `scope = drive.file`. That scope grants an app access to **only the files
that app itself created** - and "that app" means that OAuth client. Swap the client_id and
the new client sees an empty Drive, because every existing file was created by the old one.

Measured, 2026-09-06, immediately after a successful re-auth with the new client:

    $ rclone lsd gdrive:                  # (nothing at all)
    $ rclone lsd gdrive:prime-backup
    ERROR : : error listing: directory not found

All 6.5 GB was still in the Drive account. rclone simply could not see it. Had the 03:20
timer fired in that state it would have found an empty destination and re-uploaded
everything, leaving two disconnected copies and burning the uplink for a day.

Reverting `~/.config/rclone/rclone.conf` to the pre-change copy restored it instantly -
all thirteen directories listed again.

**So there are only three real options, and none of them is "just set client_id":**

1. **Stay on the shared client_id** (current state). The brakes in `backup.sh` - `--tpslimit
   10`, default pacer, 4/8 transfers/checkers, `--retries 5` - are what keep it under the
   shared quota, and they have held: a full ten-pair run with zero rateLimitExceeded.
2. **Switch to the dedicated client AND widen the scope to `drive`.** Full Drive access
   rather than only rclone's own files, so the new client can see the existing backups.
   This is a genuine widening of what a compromised token could reach, and it needs a
   re-auth. It is the only option that gets the dedicated quota AND keeps the data.
3. **Switch client, keep `drive.file`, accept a full re-upload.** 6.5 GB back up the link,
   and the old copy is orphaned - still consuming Drive quota, invisible to rclone forever.

Option 2 is the only one that actually finishes the job, and it is a security decision
rather than a technical one. The credentials are already in place for it: the client_id
and secret are saved at `~/.config/rclone/rclone.conf.newclient-*`, so switching means
restoring that file, changing `scope` to `drive`, and re-running `rclone config reconnect`.

## Do not

- Do not remove `--tpslimit` while still on the shared client_id. It is the only setting
  that caps API calls per second outright; `--transfers` caps concurrent file bodies,
  which is not the same thing and is not what the quota counts.
- Do not "fix" a 403 by deleting the remote and re-syncing. rclone's
  `not deleting files as there were IO errors` guard is what stops a partial failure from
  turning into a partial *deletion*.
