#!/usr/bin/env bash
#
# Interactive uninstall for ProtoMap Server: removes the installation and its data, and keeps the CLI. It puts back the
# CLI login that a trial installation replaced.

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

# The login that install.sh writes for trial installations, as protomap login would.
cli_login="${PROTOMAP_DATA_DIR:-${HOME}/.protomap}/login.json"

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

# The folder of the compose.yaml that created a container, as the shell that ran Docker Compose named it.
WORKING_DIR_LABEL='{{ index .Config.Labels "com.docker.compose.project.working_dir" }}'

# Stops when the containers of this installation's Docker Compose project were created from another folder, which is
# another installation's, so acting on them would change or delete its data. Folders compare by their real paths, so
# a symbolic link to this folder is this folder. A folder that no longer exists is this installation's, moved or
# renamed, only when the user says so. Keep it in step with upgrade.sh.
check_project_folder() {
    local containers folders working_dir recorded
    containers="$(docker compose ps --all --quiet)" ||
        fail "Cannot list the containers of ProtoMap Server." "Fix that error, and run ${scripts}/uninstall.sh again."
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
                    "Run ${scripts}/uninstall.sh again, and answer y if this is that installation."
                ;;
        esac
    done 3<<< "$folders"
}

# Writes the bundled database's dump to the file $1, which only this user may read. The dump drops what it holds before
# it creates it, so it restores into the database of a fresh installation, which its server has migrated already.
dump_database() {
    (
        umask 077
        # The container's shell expands its own variables.
        # shellcheck disable=SC2016
        docker compose exec -T postgres \
            sh -c 'pg_dump --clean --if-exists --username="$POSTGRES_USER" "$POSTGRES_DB"' > "$1"
    )
}

title "Uninstalling ProtoMap Server..."
command -v docker > /dev/null 2>&1 ||
    fail "Docker is required, and it was not found." "Install Docker first: https://docs.docker.com/get-docker/"
docker compose version > /dev/null 2>&1 ||
    fail "Docker Compose v2 is required, and it was not found." "Update Docker, or install Docker Compose."
if ! { [ -e .env ] || [ -L .env ]; }; then
    say "" "No installation found. Nothing to uninstall."
    exit 0
fi
# This installation's Docker Compose project, which install.sh writes to .env. Docker Compose would take one that the
# shell sets first, which may name another installation.
project="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env | tail -n 1 | tr -d "\"'")"
export COMPOSE_PROJECT_NAME="${project:-protomap}"
check_project_folder

bundled=""
if grep -Eq '^COMPOSE_PROFILES=.*postgres' .env; then
    bundled=1
fi
# A bundled database exists once the installation started, unlike after a failed pull, so only then is there one to
# back up.
has_database=""
volumes="$(docker volume ls --quiet --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
    --filter "label=com.docker.compose.volume=postgres-data")"
[ -z "$bundled" ] || [ -z "$volumes" ] || has_database=1
# The CLI's login goes too when it is for this installation, as a trial's is.
url="http://localhost:$(sed -n 's/^PROTOMAP_PORT=//p' .env | tail -n 1)"
files="${folder}/.env"
login=""
if [ -e "$cli_login" ] && grep -Fq "\"url\":\"${url}\"" "$cli_login"; then
    login=1
    files="${folder}/.env and CLI login"
fi
# The login this installation replaced, which goes back where it was taken from, in place of this installation's.
previous_login="$(sed -n 's/^PROTOMAP_CLI_LOGIN_BACKUP=//p' .env | tail -n 1 | tr -d "'")"
[ -e "$previous_login" ] || previous_login=""
restored_login="${previous_login%.backup.*}"
previous_url=""
[ -z "$previous_login" ] || previous_url="$(sed -n 's/.*"url":"\([^"]*\)".*/\1/p' "$previous_login")"
# It goes back unless the CLI logged in elsewhere since.
is_login_restored=""
if [ -n "$previous_login" ] && [ ! -e "$restored_login" ]; then
    is_login_restored=1
elif [ -n "$previous_login" ] && [ -n "$login" ] && [ "$restored_login" = "$cli_login" ]; then
    is_login_restored=1
fi
backed_up="$files"
if [ -n "$has_database" ] && [ -n "$login" ]; then
    backed_up="${folder}/.env, CLI login, and database"
elif [ -n "$has_database" ]; then
    backed_up="${folder}/.env and database"
fi
say "" "Uninstalling will:" "  - Stop and remove containers."
[ -z "$bundled" ] || say "  - Delete bundled database: every organization, account, and scan."
say "  - Remove ${files}."
if [ -n "$is_login_restored" ]; then
    say "  - Log ProtoMap CLI back in to ${previous_url:-the server it was logged in to before}."
fi
say "  - Keep ProtoMap CLI, Docker images, and other files in ${folder}."
[ -n "$bundled" ] || say "" "Your own PostgreSQL keeps its data." "To install again, use a new or empty database."
say ""
read -r -p "${color_prompt}Uninstall ProtoMap Server? [y/N]:${color_reset} " || true
case "${REPLY:-n}" in
    y | Y | yes | YES) ;;
    *)
        say "" "Uninstall cancelled. Nothing was changed."
        exit 0
        ;;
esac
# Backups keep the secrets of the removed installation, such as the key its stored API keys are encrypted with.
while :; do
    read -r -p "${color_prompt}Back up ${backed_up} first? [Y/n]:${color_reset} " || true
    case "${REPLY:-y}" in
        y | Y | yes | YES) back_up=1 && break ;;
        n | N | no | NO) back_up="" && break ;;
        *) say "Enter y or n." ;;
    esac
done

say ""
stamp="$(date +%Y%m%d-%H%M%S)"
backups=()
# The database goes with the containers, so its backup comes first. It holds the organization's secrets, so only this
# user may read it.
if [ -n "$back_up" ] && [ -n "$has_database" ]; then
    dump="protomap-backup.${stamp}.sql"
    if ! step "Backing up the database" dump_database "$dump"; then
        rm -f "$dump"
        fail "Cannot back up the database. Nothing was removed." \
            "Start ProtoMap Server with: docker compose --file ${folder}/compose.yaml up --detach --wait" \
            "Then run ${scripts}/uninstall.sh again, or answer n to remove it without a backup."
    fi
    backups+=("  ${folder}/${dump}")
fi
removing="Removing containers"
[ -z "$bundled" ] || removing="Removing containers and data"
step "$removing" docker compose down --volumes --remove-orphans ||
    fail "Cannot remove containers." "Fix that error, and run ${scripts}/uninstall.sh again."
if [ -n "$back_up" ]; then
    mv .env ".env.backup.${stamp}"
    backups+=("  ${folder}/.env.backup.${stamp}")
    if [ -n "$login" ]; then
        mv "$cli_login" "${cli_login}.backup.${stamp}"
        backups+=("  $(shorten "${cli_login}.backup.${stamp}")")
    fi
    say "Backed up ${backed_up}:" "${backups[@]}"
else
    rm -f .env
    [ -z "$login" ] || rm -f "$cli_login"
    say "Removed ${files}."
fi
if [ -n "$is_login_restored" ]; then
    mv "$previous_login" "$restored_login"
    say "Logged ProtoMap CLI back in to ${previous_url:-the server it was logged in to before}."
    # The installation pinned the CLI to its release, which the other server may not run.
    if grep -Eq '"automatic": *false' "${HOME}/.protomap/settings.json" 2> /dev/null; then
        say "ProtoMap CLI stays at the release this installation pinned. To let it update itself again, run:" \
            "  protomap update --auto on"
    fi
elif [ -n "$previous_login" ]; then
    say "ProtoMap CLI is logged in to another server now. Its login from before this installation is in:" \
        "  $(shorten "$previous_login")"
fi

say "" "ProtoMap Server is uninstalled." "To reinstall, run ${scripts}/install.sh."
