# Backups

Nightly `restic` snapshot of the worlds, mods and config to an off-host repository,
encrypted client-side.

| File | Installed to |
|---|---|
| `terraria-backup.sh` | `/usr/local/sbin/terraria-backup.sh` (mode 700) |
| `terraria-backup.service` | `/etc/systemd/system/` |
| `terraria-backup.timer` | `/etc/systemd/system/` |

## Why the server is stopped

tModLoader writes the world to disk on shutdown, so a clean stop gives a guaranteed
consistent save.

The tempting alternative is to issue `save` to the running server and copy afterwards — no
downtime. But there is no completion signal to wait on, so you would be sleeping an
arbitrary number of seconds and hoping the write finished. That is a guess dressed up as a
backup, and the world is the one thing here that cannot be recreated. A minute of downtime
at 05:00 is a cheap price for certainty.

`stop_grace_period: 120s` in the compose file allows the write to finish; Docker's 10s
default would kill a large modded world mid-save.

The console wrapper does expose a no-downtime alternative — `docker kill --signal=HUP
terraria` asks the server to flush the world while it keeps running. It is not used here
because the server gives no signal that the save has *finished*, so the script would be
sleeping an arbitrary interval and hoping. If uptime matters more than certainty to you,
swap the `stop`/`start` pair for a `HUP` and a generous sleep, and know what you traded.

The script traps `EXIT` and restarts the server however it exits, so a failed backup cannot
leave the server down overnight. A failed *restart* is treated as a failed run rather than
being swallowed — otherwise the alert would say everything was fine while the server was
down.

## What is and isn't backed up

**In:** `Worlds/` (irreplaceable), `Mods/` including `install.txt` and `enabled.json`,
`ModConfigs/` (tedious to reconstruct), and the config directory with its `.env` — which is
gitignored, so this backup is its only copy.

**Out:** `server/` (the tModLoader install, rebuilt from the image), `steamapps/` (Workshop
cache, re-downloaded from `install.txt`), and logs. Excluding these keeps snapshots small
enough that a long retention costs nothing.

Retention is 14 daily / 8 weekly / 6 monthly — longer than a typical service backup,
because the failures this protects against tend to be noticed late: a griefed base, a
corrupted save, a mod update that broke the world. Yesterday's snapshot is no help if
nobody looked for a week.

## Setup

```sh
sudo dnf install -y restic rclone        # or apt
```

### 1. Storage backend

Configure an `rclone` remote for wherever the snapshots go:

```sh
sudo rclone config
sudo chmod 600 /root/.config/rclone/rclone.conf
```

Use `sudo` so the config lands in root's home where the timer can read it, and do not set a
config password — it breaks unattended runs.

### 2. Repository

```sh
openssl rand -base64 32 | sudo tee /root/.restic-terraria-password
sudo chmod 600 /root/.restic-terraria-password

sudo tee /root/.restic-terraria-env >/dev/null <<'ENV'
export RESTIC_REPOSITORY=rclone:<remote>:<path>
export RESTIC_PASSWORD_FILE=/root/.restic-terraria-password
export CONFIG_DIR=/opt/terraria
export DATA_DIR=/srv/terraria
ENV
sudo chmod 600 /root/.restic-terraria-env

sudo -E bash -c '. /root/.restic-terraria-env && restic init'
```

The repository location stays in `/root`, out of this repo, so a public repo discloses
nothing about where the data lives.

**Store the repository password somewhere other than this machine.** It is the only part of
this setup that cannot be regenerated; an encrypted repo you cannot decrypt is
indistinguishable from no backup at all.

### 3. Install and schedule

```sh
sudo install -m 700 backup/terraria-backup.sh /usr/local/sbin/terraria-backup.sh
sudo install -m 644 backup/terraria-backup.service backup/terraria-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now terraria-backup.timer
systemctl list-timers terraria-backup.timer
```

If the service was already running from an earlier install, use `systemctl restart` —
`enable --now` is a no-op on an active unit and will not pick up changes.

### 4. First run, watched

```sh
sudo /usr/local/sbin/terraria-backup.sh
```

Confirm the server came back afterwards: `docker compose ps`.

## Restoring

```sh
sudo -E bash
. /root/.restic-terraria-env
restic snapshots
```

A single world:

```sh
restic restore latest --target /tmp/restore-test --include '*/Worlds/*'
```

Full rebuild — restore, then fix ownership, since the container runs as a fixed uid:

```sh
docker compose stop
restic restore latest --target /
chown -R <uid>:<gid> <data>
docker compose start
```

## Test a restore

Do this now, not during an outage:

```sh
restic restore latest --target /tmp/restore-test --include '*/Worlds/*'
ls -la /tmp/restore-test/**/Worlds/
rm -rf /tmp/restore-test
```

A `.wld` of a plausible size is the proof. An untested backup is a guess.

## Alerting

The script pings healthchecks.io — `/start` on begin, the bare URL on success, `/fail` on
error:

```sh
echo 'https://hc-ping.com/<uuid>' | sudo tee /root/.healthchecks-terraria-url
sudo chmod 600 /root/.healthchecks-terraria-url
```

Use a check of its own rather than sharing one with other backups on the host; a shared
check cannot tell you which job stopped reporting. Period 1 day, grace 2 hours.

Test the failure path as well as the success path:

```sh
curl -fsS "$(sudo cat /root/.healthchecks-terraria-url)/fail"
```

Confirm the notification actually arrives. An alerting path you have never seen fire is not
an alerting path — and the failure that matters most is the run that never happened,
which no amount of watching successful runs will reveal.

The ping URL stays out of git: anyone holding it can forge pings and mask a real failure.
