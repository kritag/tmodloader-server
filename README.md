# tmodloader-server

A modded Terraria (tModLoader) dedicated server in Docker, built from tModLoader's own
dedicated-server image, with a real server console and nightly encrypted backups.

Config lives in git; worlds and mods live outside it. Nothing host-specific is committed —
paths, ports, versions and ownership all come from `.env`.

## Quick start

Full explanations follow; this is the whole deployment in order. `<config>` is the repo
checkout (e.g. `/opt/terraria`), `<data>` is the world directory (e.g. `/srv/terraria`),
`<admin>` is your own account.

```sh
# 1. Service account. Note the uid/gid it gets.
sudo useradd --create-home --home-dir <data> --shell /usr/sbin/nologin terraria
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

# 5. Console. Detach with Ctrl-P Ctrl-Q; Ctrl-C stops the server.
sudo docker attach terraria
```

Backups are a separate sequence — see [`backup/README.md`](backup/README.md).

## Git access on the server

Cloning a public repo over HTTPS needs no credentials, and `git pull` keeps working. That is
enough if changes are authored elsewhere and the server only consumes them, which is the
recommended flow.

To commit *from* the server, **generate a new key there** — never copy a personal private
key onto a host:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/github-terraria -N "" -C "server deploy key"
cat ~/.ssh/github-terraria.pub      # add to the repo's Deploy keys, with write access
```

```
# ~/.ssh/config
Host github-terraria
    HostName github.com
    User git
    IdentityFile ~/.ssh/github-terraria
    IdentitiesOnly yes
```

Then set the remote to `github-terraria:<owner>/<repo>.git`. The plain `git@github.com:...`
form matches no `Host` block, so ssh ignores the `IdentityFile` and fails with
`Permission denied (publickey)` even though the key is registered correctly.

A deploy key is scoped to one repository, so a compromise of this host cannot reach your
other repos — which a personal key or an account-wide token would.

## Why the upstream image

tModLoader ships a `Dockerfile` and management script in its own repository. Compared with
the third-party prebuilt images:

- `docker attach` gives a **real interactive console**, not one-way command injection
- the server runs as a **non-root user** inside the container
- mods are `install.txt` + `enabled.json` — plain text you can commit, so the mod list is
  version-controlled rather than living in environment variables

The cost is building the image yourself rather than pulling a tagged one. `TMLVERSION` pins
the release, so builds stay reproducible.

The `Dockerfile` here is vendored from upstream rather than fetched at build time, so
upstream changes show up as a reviewable diff instead of arriving silently. Refresh it with:

```sh
curl -sf -o Dockerfile \
  https://raw.githubusercontent.com/tModLoader/tModLoader/1.4.5/patches/tModLoader/Terraria/release_extras/DedicatedServerUtils/Dockerfile
```

then re-apply the comment header at the top and rebuild.

## Layout

| Path | Contents | In git? | In backup? |
|---|---|---|---|
| `<config>/docker-compose.yaml` | this repo | yes | yes |
| `<config>/.env` | version, paths, port, uid/gid | **no** | yes |
| `<data>/serverconfig.txt` | password, world and player settings | **no** | **yes** |
| `<data>/Worlds/` | the worlds — irreplaceable | no | **yes** |
| `<data>/Mods/` | `.tmod` files, `install.txt`, `enabled.json` | no | **yes** |
| `<data>/ModConfigs/` | per-mod settings | no | **yes** |
| `<data>/server/` | the tModLoader install | no | no — rebuilt |
| `<data>/steamapps/` | Workshop cache | no | no — re-downloaded |

Keep the config directory and the data directory **separate**, and do not put the repo in
the service account's home. A home directory accumulates `.ssh`, shell history and caches
that a `git add -A` would sweep into a commit, and `git clean -fdx` run there deletes
ignored files — which is the world.

## The service account

The container runs as a fixed uid/gid, so the host needs an account for the world files to
belong to. Create it before the first build — the ids are baked in at build time.

```sh
sudo useradd --create-home --home-dir /srv/terraria \
             --shell /usr/sbin/nologin terraria
id terraria
```

Put the resulting uid and gid in `.env` as `TML_UID` / `TML_GID`.

**Let it take a normal uid (1000+), not a system one.** `useradd --system` allocates below
1000, which hides the account from the usual `awk -F: '$3 >= 1000'` audit of human
accounts — an easy way to end up with a login you forget exists on a host with a port open
to the internet.

**`nologin` is deliberate.** This account exists to own files, nothing more. It does not
need a shell, and it should not be in the `docker` group: membership there is
root-equivalent, since `docker run -v /:/host` yields a root shell. Adding a game server's
service account to it hands that reach to the account most exposed to the internet.

Manage the stack as an admin instead:

```sh
sudo docker compose -f /opt/terraria/docker-compose.yaml --project-directory /opt/terraria ps
```

### Who owns what

```
<config>   an admin account — git repo, compose file, .env
<data>     terraria          — worlds, mods, mod configs
```

Split this way you never log in as `terraria`. Manage the repo as yourself and reach Docker
with `sudo`:

```sh
sudo chown -R <you>:<you> <config>
cd <config> && git pull          # as yourself
sudo docker compose up -d        # sudo only for Docker
```

If you would rather follow a per-user-stack convention — `su - terraria`, repo and data both
owned by it — give the account `--shell /bin/bash`, add it to `docker`, and let it own
`<config>` too. That is more convenient and it is a second root-equivalent account. For a
service with an unauthenticated port open to the internet, the split above is the safer
default; for something behind auth it matters less.

The home directory is the *data* directory here, which is why the config lives elsewhere:
a repo rooted in a home directory sweeps up `.ssh` and shell history on `git add -A`, and
`git clean -fdx` there deletes ignored files — which is the world.

## Setup

```sh
git clone <this repo> <config>
cd <config>
cp .env.example .env && $EDITOR .env
```

Set `TML_UID`/`TML_GID` to the account that should own the world files. They are **build
args, not runtime env** — an upstream limitation — so changing them later needs a rebuild,
not a restart. Getting them wrong leaves files owned by uid 1000 whoever runs the stack.

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

```sh
sudo docker attach terraria
```

This works even though the service account has `nologin`. `docker attach` connects to the
container's stdin/stdout, not to a host login session — you run it as any user with Docker
access. The host account's shell governs only whether you can log in *as* `terraria`, which
nothing here requires. Inside the container the server runs as its own `tml` user;
`TML_UID`/`TML_GID` exist solely so files written to the bind mount get the right ownership
on the host.

**Detach with `Ctrl-P` then `Ctrl-Q`.** `Ctrl-C` stops the server — and with
`restart: unless-stopped` it will not come back on its own, because a deliberate stop is
not a failure. If that happens: `docker compose start`.

Useful console commands: `save`, `playing`, `kick <player>`, `ban <player>`, `say <msg>`,
`exit` (saves and shuts down).

Read-only alternative that cannot accidentally stop anything:

```sh
docker compose logs -f
journalctl CONTAINER_NAME=terraria -f
```

## Mods

Mods are chosen in the game client, not on the server:

1. In tModLoader, enable the mods you want
2. **Workshop → Mod Packs → Save Enabled as New Mod Pack**
3. Open the mod pack folder; copy `install.txt` and `enabled.json` into `<data>/Mods/`
4. `docker compose restart`

`install.txt` lists Workshop IDs to download; `enabled.json` lists what to turn on. Local
`.tmod` files can be dropped into `<data>/Mods/` directly.

Both files are small and worth committing to git alongside this config if you want the mod
list under version control — they contain no secrets.

Removing a mod from a world that already has its content will break that world. Take a
backup run before changing the mod list, not after.

## Backups

See [`backup/README.md`](backup/README.md). Nightly restic snapshot to an off-host
repository, encrypted client-side, with a dead-man's-switch alert.

## Security

The published port is open to the internet. Terraria has no account system, so `password=`
in `<data>/serverconfig.txt` is the only access control — a blank one means anyone who finds
the port can join, build, and destroy. `secure=1` and a sensible `maxplayers` are worth
setting too.

`serverconfig.txt` lives in the data directory rather than this repo precisely because it
holds that password. It is covered by the backup.

If the player group is small and stable, restricting the port to known source addresses at
the firewall is stronger than any in-game setting. Note that Docker publishes ports via its
own iptables rules and bypasses `firewalld`/`ufw` — rules must go in the `DOCKER-USER`
chain or they will silently do nothing.
