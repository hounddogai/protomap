#!/usr/bin/env bash
#
# Interactive upgrade for ProtoMap self-hosted: keeps the configuration and data, migrates the database to the release
# PROTOMAP_VERSION names, the latest by default, and upgrades the ProtoMap CLI to the same release.

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

require_docker
is_installed || fail "No installation was found. Run ./install.sh."

heading "UPGRADE PROTOMAP"
say "Upgrading keeps your configuration and data. ProtoMap is unavailable while the database migrates, so back up"
say "your database first."
# Docker Compose reads PROTOMAP_VERSION from the environment before .env, but the next 'docker compose up' without it
# would run the release .env names again, and migrate the database to it.
pinned="$(read_setting PROTOMAP_VERSION | tr -d "\"'")"
if [ -n "${PROTOMAP_VERSION:-}" ] && [ "$PROTOMAP_VERSION" != "${pinned:-latest}" ]; then
    say ""
    say "PROTOMAP_VERSION=${PROTOMAP_VERSION} is not in .env, so a later 'docker compose up' would run" \
        "${pinned:-the latest release} instead. To keep ${PROTOMAP_VERSION}, cancel, set PROTOMAP_VERSION in .env," \
        "and run ./upgrade.sh again."
fi
confirm "Upgrade ProtoMap?" y || {
    say "Upgrade cancelled. Nothing was changed."
    exit 0
}

heading "PULL THE RELEASE"
say "Pulling the images..."
docker compose pull --quiet || fail "Cannot pull the images. Fix the reported error and run ./upgrade.sh again."
from="$(running_release)"
release="$(server_release)"
say "Upgrading from ${from:-a stopped installation} to ProtoMap ${release}."
# An older release may not read what a later one wrote, such as its database schema.
if [ -n "$from" ] && is_older_release "$release" "$from"; then
    fail "ProtoMap ${release} is older than ProtoMap ${from}, which this installation runs, so nothing was changed." \
        "Set PROTOMAP_VERSION in .env to ${from} or a later release. To go back to an earlier release, restore the" \
        "database backup made before upgrading from it, then run 'docker compose down' and ./upgrade.sh again."
fi
services="$(docker compose ps --all --format '{{.Service}}')"
server_scale="$(grep -cx server <<< "$services" || true)"
worker_scale="$(grep -cx worker <<< "$services" || true)"

heading "MIGRATE THE DATABASE"
say "Stopping ProtoMap and migrating the database with the new release..."
docker compose stop proxy server worker
status=0
docker compose run --rm --no-TTY server migrate < /dev/null || status=$?
if [ "$status" -ne 0 ]; then
    # A failed migration changes nothing, since each runs in a transaction, so the previous release starts again.
    docker compose start > /dev/null 2>&1 || true
    # ProtoMap changes its one schema migration in place, so a release whose schema differs cannot use the database.
    if [ "$status" -eq 3 ]; then
        fail "ProtoMap ${release} cannot use this database's schema. ${from:+ProtoMap ${from} is running again. }To" \
            "run ${release}, back up what you need and start over with ./reset.sh, which deletes every organization," \
            "account, and scan."
    fi
    fail "The database migration failed${from:+, and ProtoMap ${from} is running again}. Fix the reported error and" \
        "run ./upgrade.sh again."
fi

heading "START PROTOMAP"
say "Starting ProtoMap ${release}..."
server_scale=$((server_scale > 0 ? server_scale : 1))
worker_scale=$((worker_scale > 0 ? worker_scale : 1))
if ! docker compose up --detach --wait --force-recreate --remove-orphans \
    --scale "server=${server_scale}" --scale "worker=${worker_scale}"; then
    show_server_log
    fail "ProtoMap did not start. Fix the error above, and run ./upgrade.sh again."
fi

install_cli "$release"

heading "UPGRADE COMPLETE"
if [ -n "$from" ] && [ "$from" != "$release" ]; then
    say "ProtoMap ${release} is running, upgraded from ${from}."
else
    say "ProtoMap ${release} is running."
fi
