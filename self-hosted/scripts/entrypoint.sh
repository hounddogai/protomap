#!/bin/sh
# The container role is the first argument: "server" (the API and the platform UI, the image default), "worker"
# (background jobs and the job queue dashboard), "migrate" (migrates the database and exits, which upgrade.sh runs
# before it replaces the servers), or any other command to run as it is.
set -e

role="${1:-server}"
case "$role" in
server)
    exec /usr/local/bin/protomap-server
    ;;
worker)
    exec /usr/local/bin/protomap-worker
    ;;
migrate)
    exec /usr/local/bin/protomap-server migrate
    ;;
*)
    exec "$@"
    ;;
esac
