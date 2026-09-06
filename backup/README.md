# Backups

Nightly restic snapshot of worlds, mods and config to an off-host repository,
encrypted client-side. The server is stopped for the duration — tModLoader
writes the world on shutdown, which is the only way to get a
guaranteed-consistent save.

## Setup

Prerequisites: `restic` and `rclone`

```sh
sudo rclone config                             # remote for wherever snapshots go
sudo chmod 600 /root/.config/rclone/rclone.conf

openssl rand -base64 32 | sudo tee /root/.restic-terraria-password
sudo chmod 600 /root/.restic-terraria-password

sudo tee /root/.restic-terraria-env >/dev/null <<'ENV'
export RESTIC_REPOSITORY=rclone:<remote>:<path>
export RESTIC_PASSWORD_FILE=/root/.restic-terraria-password
export CONFIG_DIR=<config>
export DATA_DIR=<data>
ENV
sudo chmod 600 /root/.restic-terraria-env
sudo -E bash -c '. /root/.restic-terraria-env && restic init'

sudo install -m 700 backup/terraria-backup.sh /usr/local/sbin/terraria-backup.sh
sudo install -m 644 backup/terraria-backup.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now terraria-backup.timer

sudo /usr/local/sbin/terraria-backup.sh        # first run, watched
sudo docker compose ps                         # confirm the server came back
```

**Store the repository password off this machine.** It is the only unrecoverable
piece.

## Check

```sh
systemctl list-timers terraria-backup.timer
journalctl -u terraria-backup.service -n 50
sudo -E bash -c '. /root/.restic-terraria-env && restic snapshots'
```

## Restore test

```sh
sudo -E bash
. /root/.restic-terraria-env
restic restore latest --target /tmp/restore-test --include '*/Worlds/*'
ls -la /tmp/restore-test/**/Worlds/
rm -rf /tmp/restore-test
```

## Restore

```sh
sudo docker compose stop
sudo -E bash -c '. /root/.restic-terraria-env && restic restore latest --target /'
sudo chown -R terraria:terraria <data>
sudo docker compose start
```

## Alerting

```sh
echo 'https://hc-ping.com/<uuid>' | sudo tee /root/.healthchecks-terraria-url
sudo chmod 600 /root/.healthchecks-terraria-url
curl -fsS "$(sudo cat /root/.healthchecks-terraria-url)/fail"   # confirm the mail arrives
sudo /usr/local/sbin/terraria-backup.sh                         # back to green
```

Own check, period 1 day, grace 2 hours. A shared check cannot tell you which job
stopped reporting. Absent file disables alerting silently.

## Notes

- In: `Worlds/`, `Mods/` (incl. `install.txt`, `enabled.json`), `ModConfigs/`,
  and `<config>` with its `.env` — which is gitignored, so this is its only
  copy.
- Out: `server/` (rebuilt from the image), `steamapps/` (re-downloaded), logs.
- Retention 14 daily / 8 weekly / 6 monthly. Griefed bases and corrupt saves get
  noticed late.
- The script restarts the server on any exit path, and reports a failed restart
  as a failed run.
- `docker kill --signal=HUP terraria` saves without stopping. Not used here: the
  server signals when a save *starts* but the script would still be guessing
  when it finished.
- `systemctl enable --now` is a no-op on an already-running unit — use `restart`
  after changing the script.
