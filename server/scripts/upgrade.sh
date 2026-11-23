#!/usr/bin/env bash
#
# Interactive upgrade for ProtoMap Server: keeps the configuration and data, migrates the database to the release
# PROTOMAP_VERSION names, the latest by default, and installs the latest ProtoMap CLI. It moves an
# installation in ~/.protomap/server to the compose.yaml of the clone it is in, and runs the same from any folder.

set -euo pipefail

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

# $1 with the home folder written as ~, which reads shorter.
# The ~ is printed as is, for the reader.
# shellcheck disable=SC2088
shorten() {
    case "$1" in
        "${HOME}"/*) printf '~/%s' "${1#"${HOME}/"}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# This script's folder in a clone of the repository, found through any symbolic links to the script, so that the script
# runs the same from any folder and by any path. The clone's server folder has the compose.yaml it upgrades to.
script="${BASH_SOURCE[0]:-}"
[ -f "$script" ] || fail "Run this script from a clone of the repository:" \
    "  git clone https://github.com/hounddogai/protomap.git" "  protomap/server/scripts/upgrade.sh"
while [ -L "$script" ]; do
    link="$(readlink "$script")"
    case "$link" in
        /*) script="$link" ;;
        *) script="$(dirname "$script")/${link}" ;;
    esac
done
script_folder="$(cd "$(dirname "$script")" && pwd -P)"
release_compose="$(dirname "$script_folder")/compose.yaml"
scripts="$(shorten "$script_folder")"
# This user's installations, each in a folder named after its Docker Compose project, with its compose.yaml, its .env,
# and the backups uninstall.sh makes. No clone holds them, so the scripts of any clone find them.
installations="${HOME}/.protomap/server"

usage() {
    say "Usage: $0 [--name=NAME]" "" \
        "Upgrades ProtoMap Server to the latest release, or the one PROTOMAP_VERSION in its .env names," \
        "keeping its configuration and data, and installs the latest ProtoMap CLI." "" \
        "  --name=NAME  The installation to upgrade, by its Docker Compose project name. Needed only when" \
        "               ~/.protomap/server holds several"
}

# Leaves in installation the folder of the installation named $1, or else of this user's only one, or nothing when
# there is none. Stops when several are installed and none is named. Keep it in step with uninstall.sh.
find_installation() {
    # Bash 3.2 matches ranges such as a-z by the locale's collation, which puts capitals among them.
    local env names="" LC_ALL=C
    installation=""
    if [ -n "$1" ]; then
        case "$1" in
            [!a-z0-9]* | *[!a-z0-9_-]*) fail "No installation can be named \"$1\"." ;;
        esac
        if [ -e "${installations}/$1/.env" ] || [ -L "${installations}/$1/.env" ]; then
            installation="${installations}/$1"
        fi
        return 0
    fi
    for env in "${installations}"/*/.env; do
        [ -e "$env" ] || [ -L "$env" ] || continue
        [ -z "$installation" ] || names="${names}, "
        installation="$(dirname "$env")"
        names="${names}$(basename "$installation")"
    done
    case "$names" in
        *,*) fail "$(shorten "$installations") holds several installations: ${names}." \
            "Choose one with --name=NAME." ;;
    esac
}

# Prints each ProtoMap Server that Docker has from outside this user's installations, such as another user's, as its
# Docker Compose project and the folder it was installed from. The image a container was created from keeps its name
# even after its tag moves to a newer image. Keep it in step with uninstall.sh.
other_installations() {
    local containers image project folder
    local format='{{ .Config.Image }} {{ index .Config.Labels "com.docker.compose.project" }} '
    format+='{{ index .Config.Labels "com.docker.compose.project.working_dir" }}'
    containers="$(docker ps --all --quiet --filter label=com.docker.compose.service=server)" || return 0
    [ -n "$containers" ] || return 0
    # Each container ID is a word of its own.
    # shellcheck disable=SC2086
    docker inspect --format "$format" $containers |
        while read -r image project folder; do
            case "$image" in hounddogai/protomap | hounddogai/protomap[:@]*) ;; *) continue ;; esac
            case "$folder" in "${installations}"/*) continue ;; esac
            printf '  "%s", from %s\n' "$project" "$folder"
        done | sort -u
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

# Prints the release of ProtoMap Server that the clone's compose.yaml runs, from its image's label. Run after the image
# is pulled.
server_release() {
    local images image
    images="$(docker compose --file "$release_compose" --project-directory "$installation" config --images)"
    image="$(grep -m 1 'hounddogai/protomap' <<< "$images")" ||
        fail "${release_compose} does not run hounddogai/protomap."
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

# Installs the latest ProtoMap CLI, which then updates itself, since the server expects the latest CLI. It replaces the
# CLI found on PATH, or else installs to ~/.local/bin, which the CLI's installer puts on the PATH in the profile of the
# user's shell, and says where it went. Keep it in step with install.sh.
install_cli() {
    local existing directory
    existing="$(command -v protomap || true)"
    directory="${existing:+$(dirname "$existing")}"
    directory="${directory:-${HOME}/.local/bin}"
    # The folders the CLI's installer creates are for everyone to read, whatever the caller's umask.
    (
        umask 022
        curl -fsSL https://protomap.ai/install.sh | PROTOMAP_INSTALL_DIR="$directory" PROTOMAP_INSTALL_BRIEF=1 sh
    ) || fail "Cannot install the ProtoMap CLI. Install it with:" "  curl -fsSL https://protomap.ai/install.sh | sh"
    "${directory}/protomap" --version > /dev/null 2>&1 ||
        fail "The ProtoMap CLI was installed, but it does not run:" "  ${directory}/protomap"
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
        fail "Cannot list the containers of ProtoMap Server." \
            "Fix the error above, then run ${scripts}/upgrade.sh${name_option} again."
    [ -n "$containers" ] || return 0
    # Each container ID is a word of its own.
    # shellcheck disable=SC2086
    folders="$(docker inspect --format "$WORKING_DIR_LABEL" $containers | sort -u)"
    while IFS= read -r working_dir <&3; do
        recorded="$(cd "$working_dir" 2> /dev/null && pwd -P)" || recorded=""
        if [ -n "$recorded" ] && [ "$recorded" != "$(pwd -P)" ]; then
            fail "The Docker Compose project \"${COMPOSE_PROJECT_NAME}\" belongs to the installation in" \
                "${working_dir}, not the one in ${shown}. Nothing was changed."
        fi
        [ -z "$recorded" ] || continue
        say "" "The Docker Compose project \"${COMPOSE_PROJECT_NAME}\" was installed from ${working_dir}," \
            "and that folder no longer exists."
        REPLY=""
        read -r -p "${color_prompt}Was that installation moved to ${shown}? [y/N]:${color_reset} " || true
        case "${REPLY:-n}" in
            y | Y | yes | YES) ;;
            *)
                fail "Nothing was changed." \
                    "Run ${scripts}/upgrade.sh${name_option} again, and answer y if that installation was moved."
                ;;
        esac
    done 3<<< "$folders"
}

# Moves the server and the worker aside and migrates the database with the pulled release.
migrate_database() {
    docker compose stop proxy server worker || return
    docker compose run --rm --no-TTY server migrate
}

name=""
for option in "$@"; do
    case "$option" in
        --name=*) name="${option#--name=}" ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) fail "Unknown option: ${option}" "$(usage)" ;;
    esac
done

title "Upgrading ProtoMap Server..."
command -v docker > /dev/null 2>&1 ||
    fail "Docker is required but was not found." "Install Docker first: https://docs.docker.com/get-docker/"
docker compose version > /dev/null 2>&1 ||
    fail "Docker Compose v2 is required but was not found." "Update Docker, or install Docker Compose."
command -v curl > /dev/null 2>&1 || fail "curl is required to install the ProtoMap CLI."
[ -f "$release_compose" ] || fail "${release_compose} is missing. Clone the repository again."
find_installation "$name"
if [ -z "$installation" ]; then
    missing="No ProtoMap Server installation found in $(shorten "$installations")."
    [ -z "$name" ] || missing="No ProtoMap Server installation named \"${name}\" found in $(shorten "$installations")."
    others="$(other_installations)" || others=""
    [ -z "$others" ] || fail "$missing" "Docker has ProtoMap Server containers that were installed elsewhere:" \
        "$others" "To upgrade one, run this script as the user who installed it."
    fail "$missing" "To install ProtoMap Server, run ${scripts}/install.sh${name:+ --name=${name}}."
fi
name="$(basename "$installation")"
name_option=""
[ "$name" = protomap ] || name_option=" --name=${name}"
shown="$(shorten "$installation")"
cd "$installation"
# This installation's Docker Compose project, which install.sh writes to .env, and its definition of the services.
# Docker Compose would take those that the shell sets first, which may name another installation.
project="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env | tail -n 1 | tr -d "\"'")"
export COMPOSE_PROJECT_NAME="${project:-${name}}"
export COMPOSE_FILE="${installation}/compose.yaml"
check_project_folder

say "" "ProtoMap Server is unavailable during database migration." "Back up your database first if needed."
# Docker Compose reads PROTOMAP_VERSION from the environment before .env, but the next 'docker compose up' without it
# would run the release .env names again, and migrate the database to it.
pinned="$(sed -n 's/^PROTOMAP_VERSION=//p' .env | tail -n 1 | tr -d "\"'")"
if [ -n "${PROTOMAP_VERSION:-}" ] && [ "$PROTOMAP_VERSION" != "${pinned:-latest}" ]; then
    say "" "PROTOMAP_VERSION=${PROTOMAP_VERSION} is set in the shell, but not in ${shown}/.env." \
        "A later 'docker compose up' would run ${pinned:-the latest release} instead." \
        "To stay on ${PROTOMAP_VERSION}, cancel, set PROTOMAP_VERSION=${PROTOMAP_VERSION} in ${shown}/.env," \
        "and run ${scripts}/upgrade.sh${name_option} again."
fi
say ""
confirm "Upgrade ProtoMap Server?" y || {
    say "" "Upgrade cancelled. Nothing was changed."
    exit 0
}

say ""
# The images of the clone's definition of the services, which becomes the installation's once its release is known to
# be no older than the running one.
step "Pulling images" docker compose --file "$release_compose" --project-directory "$installation" pull --quiet ||
    fail "Cannot pull images." "Fix the error above, then run ${scripts}/upgrade.sh${name_option} again."
from="$(running_release)"
release="$(server_release)"
# An older release may not read what a later one wrote, such as its database schema.
if [ -n "$from" ] && is_older_release "$release" "$from"; then
    fail "ProtoMap Server ${release} is older than the running version (${from})." "Nothing was changed." \
        "Set PROTOMAP_VERSION in ${shown}/.env to ${from} or later." \
        "To go back to an earlier version, restore a database backup made while that version" \
        "was running, then run:" \
        "  docker compose --file ${shown}/compose.yaml down" "  ${scripts}/upgrade.sh${name_option}"
fi
cp "$release_compose" compose.yaml
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
        fail "ProtoMap Server did not start." \
            "Fix the error above, then run ${scripts}/upgrade.sh${name_option} again."
    fi
    say "ProtoMap Server ${release} is already running at ${url}."
    install_cli
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
    # ProtoMap may change a migration in place, so a release whose migrations differ cannot use the database.
    if [ "$status" -eq 3 ]; then
        fail "ProtoMap Server ${release} cannot use this database's schema." ${running[@]+"${running[@]}"} \
            "To run ${release}, back up any data to keep, then start over with:" \
            "  ${scripts}/uninstall.sh${name_option}" "  ${scripts}/install.sh${name_option}" \
            "Starting over deletes every organization, account, and scan."
    fi
    fail "Database migration failed." ${running[@]+"${running[@]}"} \
        "Fix the error above, then run ${scripts}/upgrade.sh${name_option} again."
fi

if ! step "Starting ProtoMap Server ${release}" \
    docker compose up --detach --wait --force-recreate --remove-orphans \
    --scale "server=${server_scale}" --scale "worker=${worker_scale}"; then
    show_server_log
    fail "ProtoMap Server did not start." \
        "Fix the error above, then run ${scripts}/upgrade.sh${name_option} again."
fi
say "ProtoMap Server ${release} is now running at ${url}."
install_cli
# Another release may read scans of another format, or analyze code anew: the platform marks each repository that it
# needs scanned again, and an older CLI on another computer may be refused until it updates.
say "" "ProtoMap Server is upgraded. Next:" "" \
    "  1. Rescan each repository that ProtoMap marks \"Needs a new scan\". Your organization sees" \
    "     the new scans once every marked repository is rescanned or removed." \
    "  2. On other computers, update the ProtoMap CLI to the latest version:" \
    "     protomap update"
