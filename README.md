# tmodloader-server

A modded Terraria (tModLoader) dedicated server in Docker, built from
tModLoader's own dedicated-server image, with a real server console and nightly
encrypted backups.

Config lives in git; worlds and mods live outside it. Nothing host-specific is
committed — paths, ports, versions and ownership all come from `.env`.

## Quick start

Full explanations follow; this is the whole deployment in order. `<config>` is
the repo checkout (e.g. `/opt/terraria`), `<data>` is the world directory (e.g.
`/srv/terraria`), `<admin>` is your own account.

```sh
# 1. Service account — no home; <data> is a data directory, not a home directory.
sudo useradd --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin terraria
sudo mkdir -p <data> && sudo chown terraria:terraria <data>
id terraria

# 2. Config directory, owned by you — not by the service account.
sudo mkdir -p <config> && sudo chown <admin>:<admin> <config>
git clone <repo-url> <config>
cd <config>
cp .env.example .env
$EDITOR .env                    # TMLVERSION, TML_UID, TML_GID, DATA_DIR, TML_PORT

# 3. Server settings. Lives in <data>, not the repo — it holds the password.
sudo cp serverconfig.example.txt <data>/serverconfig.txt
sudo chown terraria:terraria <data>/serverconfig.txt
sudo chmod 600 <data>/serverconfig.txt
sudo $EDITOR <data>/serverconfig.txt          # set password=

# 4. Build and run. TML_UID/TML_GID are build args — get them right before this.
sudo docker compose build
sudo docker compose up -d
sudo docker compose logs -f                   # world generation takes a few minutes

# 5. Console. Ctrl-C is safe — you are never attached to the server's terminal.
sudo docker exec terraria tcon playing
sudo docker compose logs -f
```

Backups are a separate sequence — see [`backup/README.md`](backup/README.md).

## Why the upstream image

tModLoader ships a `Dockerfile` and management script in its own repository.
Compared with the third-party prebuilt images:

- `docker attach` gives a **real interactive console**, not one-way command
  injection
- the server runs as a **non-root user** inside the container
- mods are `install.txt` + `enabled.json` — plain text you can commit, so the
  mod list is version-controlled rather than living in environment variables

The cost is building the image yourself rather than pulling a tagged one.
`TMLVERSION` pins the release, so builds stay reproducible.

The `Dockerfile` here is vendored from upstream rather than fetched at build
time, so upstream changes show up as a reviewable diff instead of arriving
silently. Refresh it with:

```sh
curl -sf -o Dockerfile \
  https://raw.githubusercontent.com/tModLoader/tModLoader/1.4.5/patches/tModLoader/Terraria/release_extras/DedicatedServerUtils/Dockerfile
```

then re-apply the comment header at the top and rebuild.

## Layout

| Path                           | Contents                                     | In git? | In backup?         |
| ------------------------------ | -------------------------------------------- | ------- | ------------------ |
| `<config>/docker-compose.yaml` | this repo                                    | yes     | yes                |
| `<config>/.env`                | version, paths, port, uid/gid                | **no**  | yes                |
| `<data>/serverconfig.txt`      | password, world and player settings          | **no**  | **yes**            |
| `<data>/Worlds/`               | the worlds — irreplaceable                   | no      | **yes**            |
| `<data>/Mods/`                 | `.tmod` files, `install.txt`, `enabled.json` | no      | **yes**            |
| `<data>/ModConfigs/`           | per-mod settings                             | no      | **yes**            |
| `<data>/server/`               | the tModLoader install                       | no      | no — rebuilt       |
| `<data>/steamapps/`            | Workshop cache                               | no      | no — re-downloaded |

Keep the config directory and the data directory **separate**, and do not put
the repo in the service account's home. A home directory accumulates `.ssh`,
shell history and caches that a `git add -A` would sweep into a commit, and
`git clean -fdx` run there deletes ignored files — which is the world.

## The service account

The container runs as a fixed uid/gid, so the host needs an account for the
world files to belong to. Create it before the first build — the ids are baked
in at build time.

```sh
sudo useradd --no-create-home --home-dir /nonexistent \
             --shell /usr/sbin/nologin terraria
sudo mkdir -p <data>
sudo chown terraria:terraria <data>
id terraria
```

Put the resulting uid and gid in `.env` as `TML_UID` / `TML_GID`.

**The account gets no home directory, and `<data>` is not one.** A `nologin`
account that exists only to own files does not need a home. Making the data
directory into one copies `/etc/skel` dotfiles in beside your worlds, which the
backup then sweeps up — the same class of problem as rooting a git repo in a
home directory.

**Let it take a normal uid (1000+), not a system one.** `useradd --system`
allocates below 1000, which hides the account from the usual
`awk -F: '$3 >= 1000'` audit of human accounts — an easy way to end up with a
login you forget exists on a host with a port open to the internet.

**`nologin` is deliberate.** This account exists to own files, nothing more. It
does not need a shell, and it should not be in the `docker` group: membership
there is root-equivalent, since `docker run -v /:/host` yields a root shell.
Adding a game server's service account to it hands that reach to the account
most exposed to the internet.

Manage the stack as an admin instead:

```sh
sudo docker compose -f <config>/docker-compose.yaml --project-directory <config> ps
```

### Who owns what

```
<config>   an admin account — git repo, compose file, .env
<data>     terraria          — worlds, mods, mod configs
```

Split this way you never log in as `terraria`. Manage the repo as yourself and
reach Docker with `sudo`:

```sh
sudo chown -R <you>:<you> <config>
cd <config> && git pull          # as yourself
sudo docker compose up -d        # sudo only for Docker
```

If you would rather follow a per-user-stack convention — `su - terraria`, repo
and data both owned by it — give the account `--shell /bin/bash`, add it to
`docker`, and let it own `<config>` too. That is more convenient and it is a
second root-equivalent account. For a service with an unauthenticated port open
to the internet, the split above is the safer default; for something behind auth
it matters less.

The config directory is kept out of both: a repo rooted in a home or data
directory sweeps up stray files on `git add -A`, and `git clean -fdx` there
deletes ignored files — which is the world.

## Setup

```sh
git clone <this repo> <config>
cd <config>
cp .env.example .env && $EDITOR .env
```

Set `TML_UID`/`TML_GID` to the account that should own the world files. They are
**build args, not runtime env** — an upstream limitation — so changing them
later needs a rebuild, not a restart. Getting them wrong leaves files owned by
uid 1000 whoever runs the stack.

```sh
sudo chown terraria:terraria <data>
sudo cp serverconfig.example.txt <data>/serverconfig.txt
sudo chown terraria:terraria <data>/serverconfig.txt
sudo chmod 600 <data>/serverconfig.txt
sudo $EDITOR <data>/serverconfig.txt                  # set the password
docker compose build
docker compose up -d
docker compose logs -f
```

First start generates a world, which takes a few minutes for a large one.

## The server console

### What is in `bin/`

Two of these run *inside* the container and are never invoked directly; the
third is optional sugar for the host.

| Script              | Runs             | How it gets there                             | You invoke it?              |
| ------------------- | ---------------- | --------------------------------------------- | --------------------------- |
| `tml-entrypoint.sh` | in the container | mounted read-only, set as `entrypoint:`       | no — Docker runs it         |
| `tcon`              | in the container | mounted read-only onto the container's `PATH` | via `docker exec`           |
| `terraria-cmd`      | on the host      | you install it, optional                      | yes — one command at a time |
| `terraria-console`  | on the host      | you install it, optional                      | yes — interactive session   |

Nothing needs installing for the console to work — the compose file mounts the
first two, so they are in place as soon as the stack is up.

### Interactive console

```sh
sudo install -m 755 bin/terraria-console /usr/local/bin/
terraria-console
```

Type commands, watch output, leave with **Ctrl-C or Ctrl-D — the server keeps
running.** That works because this is a client writing into the container's
stdin pipe, not a terminal attached to the server process, so the signal never
reaches the server.

`exit` is intercepted: it is a real Terraria command that shuts the server down,
and typing it to leave the console would be an unpleasant surprise. Use `!exit`
when you genuinely mean to stop the server.

Server output streams into the same window, so it interleaves with your prompt.
Pass `-q` to suppress it and keep `docker compose logs -f` in a second terminal
if you prefer them apart.

### Sending commands

The server's stdin is a named pipe, not a TTY. Send commands with `tcon`:

```sh
sudo docker exec terraria tcon save
sudo docker exec terraria tcon "say Restarting in 5 minutes"
sudo docker exec terraria tcon playing
```

`tcon` lives on the container's `PATH`, which is why it is `tcon` and not a
path.

Optionally install the host wrapper to shorten that:

```sh
sudo install -m 755 bin/terraria-cmd /usr/local/bin/
terraria-cmd save
terraria-cmd "say Restarting in 5 minutes"
```

Watch the output separately:

```sh
sudo docker compose logs -f
journalctl CONTAINER_NAME=terraria -f
```

**Ctrl-C is safe here.** It stops your log viewer and nothing else, because you
are not attached to the server's terminal — that is the entire point of this
arrangement.

Upstream's default is `tty: true` plus `docker attach`, where Ctrl-C travels
in-band to the container's line discipline and stops the server; with
`restart: unless-stopped` it stays down, because a deliberate stop is not a
failure. Feeding stdin from a FIFO removes the interactive session altogether,
and makes commands scriptable as a bonus.

Signals are wired up too:

| Signal    | Effect                                                                         |
| --------- | ------------------------------------------------------------------------------ |
| `SIGHUP`  | flush the world to disk without stopping — `docker kill --signal=HUP terraria` |
| `SIGTERM` | announce in chat, then `exit` cleanly so the world is written                  |

Useful console commands: `save`, `playing`, `kick <player>`, `ban <player>`,
`say <msg>`, `exit`.

### Reverting to upstream's attach console

If the wrapper ever breaks against a new tModLoader release, fall back by
removing the `entrypoint:` line and the two `./bin/...` mounts from
`docker-compose.yaml`, and restoring:

```yaml
    tty: true
    stdin_open: true
```

Then the console is `sudo docker attach terraria`, detaching with **Ctrl-P
Ctrl-Q** — and Ctrl-C stops the server.

## Updating tModLoader

`TMLVERSION` is a **build argument, not a runtime variable**. Editing `.env` and
running `docker compose up -d` changes nothing — the version is compiled into
the image. The same applies to `TML_UID` and `TML_GID`.

```sh
cd <config>
$EDITOR .env                       # set TMLVERSION
sudo docker compose build
sudo docker compose up -d
sudo docker compose logs --tail 20 # confirm the version in the startup banner
```

If the build appears to succeed but the version does not change, Docker reused a
cached layer:

```sh
sudo docker compose build --no-cache
```

**Take a backup first.** A world saved by a newer tModLoader will not open on an
older one, so an upgrade is effectively one-way — if the new version misbehaves,
rolling the tag back leaves you with a world the older build refuses to load.
Mods may also need updating to match; a mod built against an older release can
fail to load or break the world it is in.

```sh
sudo /usr/local/sbin/terraria-backup.sh
```

## Mods

Two files in `<data>/Mods/` control everything, and they hold different things:

| File | Contains | Purpose |
|---|---|---|
| `install.txt` | numeric Steam Workshop IDs, one per line | what steamcmd downloads |
| `enabled.json` | mod *internal names* | what tModLoader turns on |

The container runs the management script's mod install on **every start**, so listed mods are
downloaded and updated automatically — there is no install command to run by hand. Downloads
go to `<data>/steamapps/workshop`, which is why that directory does not exist until you add
an `install.txt`.

A mod's internal name is not shown on its Workshop page, so writing `enabled.json` by hand is
guesswork. Export a mod pack from the game client instead — it generates both files correctly.

### From the game client

1. In tModLoader, enable the mods you want
2. **Workshop → Mod Packs → Save Enabled as New Mod Pack**
3. Open the pack folder — on Linux, `~/.local/share/Terraria/tModLoader/ModPacks/<name>/`
4. Copy `install.txt` and `enabled.json` to `<data>/Mods/` on the server, owned by the
   service account:

```sh
sudo install -o terraria -g terraria -m 644 install.txt enabled.json <data>/Mods/
sudo docker compose restart
sudo docker compose logs -f
```

Expect `Installing workshop mods` and `Installed N mods`, then each mod loading. The first
start after a change is slow: steamcmd downloads, then every mod is JIT-compiled.

Mods that are not on the Workshop go in as `.tmod` files directly in `<data>/Mods/`, and
still need their internal name listed in `enabled.json`.

Both files are small, contain no secrets, and are worth committing here if you want the mod
list under version control — copy them into the repo alongside this config.

### Before you change the mod list

Take a backup. Removing a mod from a world that already contains its content will break that
world, and enabling mods on an existing world is not reliably reversible either.

```sh
sudo /usr/local/sbin/terraria-backup.sh
```

## Backups

See [`backup/README.md`](backup/README.md). Nightly restic snapshot to an
off-host repository, encrypted client-side, with a dead-man's-switch alert.

## Security

The published port is open to the internet. Terraria has no account system, so
`password=` in `<data>/serverconfig.txt` is the only access control — a blank
one means anyone who finds the port can join, build, and destroy. `secure=1` and
a sensible `maxplayers` are worth setting too.

`serverconfig.txt` lives in the data directory rather than this repo precisely
because it holds that password. It is covered by the backup.

If the player group is small and stable, restricting the port to known source
addresses at the firewall is stronger than any in-game setting. Note that Docker
publishes ports via its own iptables rules and bypasses `firewalld`/`ufw` —
rules must go in the `DOCKER-USER` chain or they will silently do nothing.
