#!/usr/bin/env bash
#
# Interactive upgrade for ProtoMap Server: keeps the configuration and data, migrates the database to the release
# PROTOMAP_VERSION names, the latest by default, and upgrades the ProtoMap CLI to the same release.

set -euo pipefail

# This script's folder, and the folder above it with compose.yaml and .env, as the command that ran the script names
# them, such as ./self-hosted/scripts and ./self-hosted from the root of the clone, so the commands and files the
# script names work from where it ran.
scripts="$(dirname "$0")"
folder="$(dirname "$scripts")"
[ "$scripts" != . ] || folder=..
# Run from the folder with compose.yaml and .env.
cd "$folder"

color_bold=""
color_done=""
color_error=""
color_prompt=""
color_reset=""
if { [ -t 1 ] || [ -t 2 ]; } && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    color_bold=$'\033[1m'
    color_done=$'\033[0;32m'
    color_error=$'\033[0;31m'
    color_prompt=$'\033[1;35m'
    color_reset=$'\033[0m'
fi

# Prints each argument as a line.
say() { printf '%s\n' "$@"; }
title() { printf '%s%s%s\n' "$color_bold" "$1" "$color_reset"; }
# Prints each argument as a line of an error, and stops.
fail() {
    printf '%sError:%s %s\n' "$color_error" "$color_reset" "$1" >&2
    shift
    [ "$#" -eq 0 ] || printf '%s\n' "$@" >&2
    exit 1
}

# Asks the yes or no question $1, with $2, y or n, as the answer for no input, which the prompt capitalizes, and
# succeeds for yes.
confirm() {
    local choices="[y/N]"
    [ "$2" = n ] || choices="[Y/n]"
    REPLY=""
    read -r -p "${color_prompt}$1 ${choices}:${color_reset} " REPLY || true
    case "${REPLY:-$2}" in
        y | Y | yes | YES) return 0 ;;
        *) return 1 ;;
    esac
}

# Says $1, runs the command after it with its output kept aside, and says done, or failed with the output.
step() {
    local log status=0
    printf '%s... ' "$1"
    shift
    log="$(mktemp)"
    "$@" > "$log" 2>&1 < /dev/null || status=$?
    if [ "$status" -eq 0 ]; then
        say "${color_done}done${color_reset}"
    else
        say "${color_error}failed${color_reset}" ""
        cat "$log"
        say ""
    fi
    rm -f "$log"
    return "$status"
}

# Shows the services' states and the server's last log lines, which say why it did not start, such as a database it
# cannot reach.
show_server_log() {
    docker compose ps --all || true
    say "" "Last server log lines:"
    docker compose logs --no-log-prefix --tail 15 server || true
    say ""
}

# Prints the release of ProtoMap Server that compose.yaml runs, from its image's label. Run after the image is pulled.
server_release() {
    local images image
    images="$(docker compose config --images)"
    image="$(grep -m 1 'hounddogai/protomap' <<< "$images")" || fail "compose.yaml does not run hounddogai/protomap."
    docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$image"
}

# Prints the release the running server container runs, or nothing when there is none.
running_release() {
    local containers
    containers="$(docker compose ps --all --quiet server)"
    [ -n "$containers" ] || return 0
    docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "${containers%%$'\n'*}"
}

# Succeeds when release $1 is older than release $2. A release is a version such as 1.2.3, or 1.2.3-beta.1 for a
# pre-release, which is older than 1.2.3. Anything else, such as no release, is older than none, and so is one of two
# pre-releases of the same version. Only shell arithmetic compares them, since sort -V is not on every system.
is_older_release() {
    local older="$1" newer="$2" a b
    is_release "$older" && is_release "$newer" || return 1
    a="${older%%-*}." b="${newer%%-*}."
    while [ -n "$a" ]; do
        if [ "${a%%.*}" -ne "${b%%.*}" ]; then
            [ "${a%%.*}" -lt "${b%%.*}" ]
            return
        fi
        a="${a#*.}" b="${b#*.}"
    done
    [ "$older" != "${older%%-*}" ] && [ "$newer" = "${newer%%-*}" ]
}

# Succeeds when $1 is a release: three numbers separated by dots, and maybe a pre-release after a hyphen.
is_release() {
    case "${1%%-*}" in
        *[!0-9.]* | .* | *. | *..* | *.*.*.*) return 1 ;;
        *.*.*) return 0 ;;
        *) return 1 ;;
    esac
}

# Installs release $1 of the ProtoMap CLI, the server's, so the two speak the same API. It replaces the CLI found on
# PATH, or else installs to ~/.local/bin, which the CLI's installer puts on the PATH in the profile of the user's shell,
# and says where it went. Keep it in step with install.sh.
install_cli() {
    local existing directory
    existing="$(command -v protomap || true)"
    directory="${existing:+$(dirname "$existing")}"
    directory="${directory:-${HOME}/.local/bin}"
    # The folders the CLI's installer creates are for everyone to read, whatever the caller's umask.
    (
        umask 022
        curl -fsSL https://protomap.ai/install.sh |
            PROTOMAP_INSTALL_DIR="$directory" PROTOMAP_INSTALL_BRIEF=1 sh -s -- "$1"
    ) || fail "Cannot install ProtoMap CLI $1. Install it with:" \
        "  curl -fsSL https://protomap.ai/install.sh | sh -s -- $1"
    "${directory}/protomap" --version > /dev/null 2>&1 ||
        fail "ProtoMap CLI was installed, but it does not run:" "  ${directory}/protomap"
}

# Moves the server and the worker aside and migrates the database with the pulled release.
migrate_database() {
    docker compose stop proxy server worker || return
    docker compose run --rm --no-TTY server migrate
}

title "Upgrading ProtoMap Server..."
command -v docker > /dev/null 2>&1 ||
    fail "Docker is required, and it was not found." "Install Docker first: https://docs.docker.com/get-docker/"
docker compose version > /dev/null 2>&1 ||
    fail "Docker Compose v2 is required, and it was not found." "Update Docker, or install Docker Compose."
command -v curl > /dev/null 2>&1 || fail "curl is required to install ProtoMap CLI."
[ -e .env ] || [ -L .env ] ||
    fail "No installation found." "To install ProtoMap Server, run ${scripts}/install.sh."

say "" "ProtoMap Server is unavailable during database migration." "Back up your database first if needed."
# Docker Compose reads PROTOMAP_VERSION from the environment before .env, but the next 'docker compose up' without it
# would run the release .env names again, and migrate the database to it.
pinned="$(sed -n 's/^PROTOMAP_VERSION=//p' .env | tail -n 1 | tr -d "\"'")"
if [ -n "${PROTOMAP_VERSION:-}" ] && [ "$PROTOMAP_VERSION" != "${pinned:-latest}" ]; then
    say "" "PROTOMAP_VERSION=${PROTOMAP_VERSION} is set here, but not in ${folder}/.env," \
        "so a later 'docker compose up' would run ${pinned:-the latest release} instead." \
        "To keep ${PROTOMAP_VERSION}, cancel, and set PROTOMAP_VERSION in ${folder}/.env." \
        "Then run ${scripts}/upgrade.sh again."
fi
say ""
confirm "Upgrade ProtoMap Server?" y || {
    say "" "Upgrade cancelled. Nothing was changed."
    exit 0
}

say ""
step "Pulling images" docker compose pull --quiet ||
    fail "Cannot pull images." "Fix that error, and run ${scripts}/upgrade.sh again."
from="$(running_release)"
release="$(server_release)"
if [ "$from" = "$release" ]; then
    say "Reinstalling ProtoMap Server ${release}, which is already running."
elif [ -n "$from" ]; then
    say "Upgrading ProtoMap Server ${from} to ${release}."
else
    say "Upgrading to ProtoMap Server ${release}."
fi
# An older release may not read what a later one wrote, such as its database schema.
if [ -n "$from" ] && is_older_release "$release" "$from"; then
    fail "ProtoMap Server ${release} is older than ${from}, which runs now." "Nothing was changed." \
        "Set PROTOMAP_VERSION in ${folder}/.env to ${from} or later." \
        "To go back to an earlier release, restore your database backup" \
        "made before upgrading from that release, then run:" \
        "  docker compose --file ${folder}/compose.yaml down" "  ${scripts}/upgrade.sh"
fi
services="$(docker compose ps --all --format '{{.Service}}')"
server_scale="$(grep -cx server <<< "$services" || true)"
worker_scale="$(grep -cx worker <<< "$services" || true)"

status=0
step "Stopping ProtoMap Server and migrating its database" migrate_database || status=$?
if [ "$status" -ne 0 ]; then
    # A failed migration changes nothing, since each runs in a transaction, so the previous release starts again.
    docker compose start > /dev/null 2>&1 || true
    running=()
    [ -z "$from" ] || running=("ProtoMap Server ${from} is running again.")
    # ProtoMap changes its one schema migration in place, so a release whose schema differs cannot use the database.
    if [ "$status" -eq 3 ]; then
        fail "ProtoMap Server ${release} cannot use this database's schema." ${running[@]+"${running[@]}"} \
            "To run ${release}, back up what you need, then start over with:" \
            "  ${scripts}/uninstall.sh" "  ${scripts}/install.sh" \
            "Starting over deletes every organization, account, and scan."
    fi
    fail "Database migration failed." ${running[@]+"${running[@]}"} \
        "Fix that error, and run ${scripts}/upgrade.sh again."
fi

server_scale=$((server_scale > 0 ? server_scale : 1))
worker_scale=$((worker_scale > 0 ? worker_scale : 1))
if ! step "Starting ProtoMap Server ${release}" \
    docker compose up --detach --wait --force-recreate --remove-orphans \
    --scale "server=${server_scale}" --scale "worker=${worker_scale}"; then
    show_server_log
    fail "ProtoMap Server did not start." "Fix that error, and run ${scripts}/upgrade.sh again."
fi
port="$(sed -n 's/^PROTOMAP_PORT=//p' .env | tail -n 1 | tr -d "\"'")"
say "ProtoMap Server ${release} is now running at http://localhost:${port:-3300}."
install_cli "$release"

if [ "$from" = "$release" ]; then
    say "" "ProtoMap Server is up to date."
else
    say "" "ProtoMap Server is upgraded."
fi
