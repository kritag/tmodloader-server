#!/bin/bash
# Entrypoint wrapper: feed the server's stdin from a named pipe instead of a TTY.
#
# Upstream's entrypoint runs the server on the container TTY, so the only console is
# `docker attach` — where Ctrl-C travels in-band to the container's line discipline and
# stops the server. Reading stdin from a FIFO removes the interactive session entirely:
# commands are written to the pipe (see `tcon`), output is read with `docker logs`, and
# there is nothing an errant Ctrl-C can reach.
#
# Technique from https://serverless.industries/2025/03/23/terraria-docker-v2.en.html
set -uo pipefail

FIFO=/tmp/tml-console
MANAGE=/home/tml/manage-tModLoaderServer.sh

rm -f "$FIFO"
mkfifo -m 600 "$FIFO"

# `tail -f` holds the pipe open. Without it the server would see EOF on stdin as soon as
# the first writer closed it, and shut down.
tail -f "$FIFO" | "$MANAGE" start --folder /tModLoader &
pid=$!

# SIGHUP: flush the world without stopping. Lets a backup ask for a save.
on_save() { echo "save" > "$FIFO"; }

# SIGTERM/SIGINT: warn players, then exit cleanly so the world is written. Docker sends
# SIGTERM on `stop`; stop_grace_period must be long enough for the write to finish.
on_stop() {
  echo "say Server is shutting down." > "$FIFO"
  sleep 2
  echo "exit" > "$FIFO"
}

trap on_save HUP
trap on_stop INT TERM

# `wait` returns early when a trap fires, so loop until the server actually exits.
while kill -0 "$pid" 2>/dev/null; do
  wait "$pid" && break
done
