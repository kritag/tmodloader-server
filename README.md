# tmodloader-server

Modded Terraria server in Docker, built from tModLoader's own dedicated-server image.
Interactive console, nightly encrypted backups.

| Path | What | Owner |
|---|---|---|
| `<config>` | this repo — compose, `.env`, scripts | your admin user |
| `<data>` | worlds, mods, `serverconfig.txt` | `terraria` |

## Install

```sh
# Service account. No home — <data> is a data dir, not a home dir.
sudo useradd --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin terraria
sudo mkdir -p <data> && sudo chown terraria:terraria <data>
id terraria                                    # -> TML_UID / TML_GID

# Config, owned by you. Public repo, so HTTPS clone needs no credentials.
sudo mkdir -p <config> && sudo chown "$USER:$USER" <config>
git clone <repo-url> <config> && cd <config>
cp .env.example .env && $EDITOR .env

# Server settings. Holds the password, so it lives in <data>, not here.
sudo install -o terraria -g terraria -m 600 serverconfig.example.txt <data>/serverconfig.txt
sudo $EDITOR <data>/serverconfig.txt           # set password=

sudo mkdir -p <data>/Mods
sudo install -o terraria -g terraria -m 644 install.txt enabled.json <data>/Mods/

sudo docker compose build
sudo docker compose up -d && sudo docker compose logs -f
```

First start generates the world. Set `TML_UID`/`TML_GID` before `build` — they are build args.

## Console

```sh
sudo install -m 755 bin/terraria-console bin/terraria-cmd /usr/local/bin/

terraria-console          # interactive; Ctrl-C leaves, server keeps running
terraria-cmd save         # one-shot
sudo docker compose logs -f
```

In the console, `exit` closes the client; `!exit` shuts the server down.

## Mods

`install.txt` = Workshop IDs. `enabled.json` = mod internal names. Generate both with
**Workshop → Mod Packs → Save Enabled as New Mod Pack** in the client — internal names are
not shown on Workshop pages, so hand-writing `enabled.json` is guesswork. The tracked copies
here are the record; the server reads them from `<data>/Mods/` and re-downloads on every start.

```sh
sudo /usr/local/sbin/terraria-backup.sh        # removing a content mod breaks a world that used it
sudo install -o terraria -g terraria -m 644 install.txt enabled.json <data>/Mods/
sudo docker compose restart
```

Non-Workshop mods: drop the `.tmod` in `<data>/Mods/` and add its internal name to `enabled.json`.

## Update tModLoader

```sh
sudo /usr/local/sbin/terraria-backup.sh        # a world saved by a newer build won't open on an older one
$EDITOR .env                                   # TMLVERSION
sudo docker compose build                      # --no-cache if the version doesn't change
sudo docker compose up -d
sudo docker compose logs --tail 20             # version is in the banner
```

## Backups

See [`backup/README.md`](backup/README.md).

## Gotchas

- `docker compose restart` does not re-read `.env` or compose — use `up -d`. `TMLVERSION`, `TML_UID`, `TML_GID` are build args and need `build`.
- `worldname` / `seed` / `autocreate` apply only when the file named by `world=` does not exist. To generate a new world, change `world=`.
- Server stdin is a FIFO, not a TTY — that is why Ctrl-C is safe. `tty: true` affects stdout only, and without it carriage-return progress output buffers until the next newline, so logs lag reality badly.
- The port is internet-facing and Terraria has no accounts. `password=` is the only access control; scanner connections in the log are normal.
- Docker bypasses `firewalld`/`ufw` — firewall rules must go in the `DOCKER-USER` chain.
- Never `git clean -fdx` in a deployment directory: it deletes ignored files.
- Pushing from the server needs a key generated *there* and added as a repo deploy key, with the remote as `<alias>:<owner>/<repo>.git`. Plain `git@github.com:...` matches no ssh `Host` block, so the `IdentityFile` is ignored and it fails with `Permission denied (publickey)`.

## Upstream

`Dockerfile` is vendored from tModLoader 1.4.5 so upstream changes arrive as a diff. Refresh:

```sh
curl -sf -o Dockerfile \
  https://raw.githubusercontent.com/tModLoader/tModLoader/1.4.5/patches/tModLoader/Terraria/release_extras/DedicatedServerUtils/Dockerfile
```

`bin/tml-entrypoint.sh` and `bin/tcon` mount over upstream's entrypoint to provide the FIFO
console. To revert: remove `entrypoint:` and the two `./bin/...` mounts, add `stdin_open: true`,
then use `docker attach` (detach Ctrl-P Ctrl-Q; Ctrl-C stops the server).
