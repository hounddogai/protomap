#!/usr/bin/env bash
#
# Interactive upgrade for ProtoMap Server: keeps the configuration and data, migrates the database to the release
# PROTOMAP_VERSION names, the latest by default, and upgrades the ProtoMap CLI to the same release.

set -euo pipefail

# This script's folder, and the folder above it with compose.yaml and .env, as the command that ran the script names
# them, such as ./server/scripts and ./server from the root of the clone, so the commands and files the
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

# Installs release $1 of the ProtoMap CLI, the server's, so the two speak the same API. Installing a given release
# turns the CLI's automatic updates off, so it stays at the server's release until an upgrade installs the next. It
# replaces the CLI found on PATH, or else installs to ~/.local/bin, which the CLI's installer puts on the PATH in the
# profile of the user's shell, and says where it went. Only the CLI install.sh pinned is replaced: one install.sh left
# as it was, because it stayed logged in to another server (PROTOMAP_CLI_KEPT in .env), and one that updates itself
# keep their release and update settings. Keep it in step with install.sh.
install_cli() {
    local existing directory reason=""
    if command -v protomap > /dev/null 2>&1; then
        if [ "$(sed -n 's/^PROTOMAP_CLI_KEPT=//p' .env | tail -n 1)" = 1 ]; then
            reason="install.sh left it as it was, logged in to another server"
        elif ! grep -Eq '"automatic": *false' "${HOME}/.protomap/settings.json" 2> /dev/null; then
            reason="it updates itself"
        fi
    fi
    if [ -n "$reason" ]; then
        say "Left ProtoMap CLI as it is: ${reason}." "To install the CLI of this server's release instead, run:" \
            "  curl -fsSL https://protomap.ai/install.sh | sh -s -- --version $1"
        return
    fi
    existing="$(command -v protomap || true)"
    directory="${existing:+$(dirname "$existing")}"
    directory="${directory:-${HOME}/.local/bin}"
    # The folders the CLI's installer creates are for everyone to read, whatever the caller's umask.
    (
        umask 022
        curl -fsSL https://protomap.ai/install.sh |
            PROTOMAP_INSTALL_DIR="$directory" PROTOMAP_INSTALL_BRIEF=1 sh -s -- --version "$1"
    ) || fail "Cannot install ProtoMap CLI $1. Install it with:" \
        "  curl -fsSL https://protomap.ai/install.sh | sh -s -- --version $1"
    "${directory}/protomap" --version > /dev/null 2>&1 ||
        fail "ProtoMap CLI was installed, but it does not run:" "  ${directory}/protomap"
}

# The folder of the compose.yaml that created a container, as the shell that ran Docker Compose named it.
WORKING_DIR_LABEL='{{ index .Config.Labels "com.docker.compose.project.working_dir" }}'

# Stops when the containers of this installation's Docker Compose project were created from another folder, which is
# another installation's, so acting on them would change or delete its data. Folders compare by their real paths, so
# a symbolic link to this folder is this folder. A folder that no longer exists is this installation's, moved or
# renamed, only when the user says so. Keep it in step with uninstall.sh.
check_project_folder() {
    local containers folders working_dir recorded
    containers="$(docker compose ps --all --quiet)" ||
        fail "Cannot list the containers of ProtoMap Server." "Fix that error, and run ${scripts}/upgrade.sh again."
    [ -n "$containers" ] || return 0
    # Each container ID is a word of its own.
    # shellcheck disable=SC2086
    folders="$(docker inspect --format "$WORKING_DIR_LABEL" $containers | sort -u)"
    while IFS= read -r working_dir <&3; do
        recorded="$(cd "$working_dir" 2> /dev/null && pwd -P)" || recorded=""
        if [ -n "$recorded" ] && [ "$recorded" != "$(pwd -P)" ]; then
            fail "The Docker Compose project ${COMPOSE_PROJECT_NAME} is the installation in ${working_dir}," \
                "not this one. Nothing was changed. Run the scripts in that installation's folder."
        fi
        [ -z "$recorded" ] || continue
        say "" "ProtoMap Server ${COMPOSE_PROJECT_NAME} was installed from ${working_dir}, which no longer exists."
        REPLY=""
        read -r -p "${color_prompt}Is this that installation, moved here? [y/N]:${color_reset} " || true
        case "${REPLY:-n}" in
            y | Y | yes | YES) ;;
            *)
                fail "Nothing was changed." \
                    "Run ${scripts}/upgrade.sh again, and answer y if this is that installation."
                ;;
        esac
    done 3<<< "$folders"
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
# This installation's Docker Compose project, which install.sh writes to .env. Docker Compose would take one that the
# shell sets first, which may name another installation.
project="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env | tail -n 1 | tr -d "\"'")"
export COMPOSE_PROJECT_NAME="${project:-protomap}"
check_project_folder

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
server_scale=$((server_scale > 0 ? server_scale : 1))
worker_scale=$((worker_scale > 0 ? worker_scale : 1))
port="$(sed -n 's/^PROTOMAP_PORT=//p' .env | tail -n 1 | tr -d "\"'")"
url="http://localhost:${port:-3300}"

# The release that runs already needs no migration, and so no downtime: only the services that are not running start.
if [ "$from" = "$release" ]; then
    if ! step "Starting any stopped services of ProtoMap Server ${release}" \
        docker compose up --detach --wait --remove-orphans \
        --scale "server=${server_scale}" --scale "worker=${worker_scale}"; then
        show_server_log
        fail "ProtoMap Server did not start." "Fix that error, and run ${scripts}/upgrade.sh again."
    fi
    say "ProtoMap Server ${release}, the release that ran already, is running at ${url}."
    install_cli "$release"
    say "" "ProtoMap Server is up to date."
    exit 0
fi
if [ -n "$from" ]; then
    say "Upgrading ProtoMap Server ${from} to ${release}."
else
    say "Upgrading to ProtoMap Server ${release}."
fi

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

if ! step "Starting ProtoMap Server ${release}" \
    docker compose up --detach --wait --force-recreate --remove-orphans \
    --scale "server=${server_scale}" --scale "worker=${worker_scale}"; then
    show_server_log
    fail "ProtoMap Server did not start." "Fix that error, and run ${scripts}/upgrade.sh again."
fi
say "ProtoMap Server ${release} is now running at ${url}."
install_cli "$release"
# Another release may read scans of another format, or analyze code anew: the platform marks each repository that it
# needs scanned again, and a CLI of the old release on another computer may be refused.
say "" "ProtoMap Server is upgraded. Next:" "" \
    "  1. Scan again each repository that the platform marks \"Needs a new scan\". The shared graph shows" \
    "     the new scans once every such repository is scanned again or removed." \
    "  2. On other computers, install ProtoMap CLI ${release}, the server's release:" \
    "     curl -fsSL https://protomap.ai/install.sh | sh -s -- --version ${release}" \
    "     A CLI that its install script installed updates itself when the server asks it to."
