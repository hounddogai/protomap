#!/usr/bin/env bash
#
# Interactive uninstall for ProtoMap Server: removes the installation and its data, and keeps the CLI. It puts back the
# CLI login that a trial installation replaced. It uninstalls an installation in ~/.protomap/server, and runs the same
# from any folder.

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

# This script's folder in a clone of the repository, found through any symbolic links to the script, so that the script
# runs the same from any folder and by any path.
script="${BASH_SOURCE[0]:-}"
[ -f "$script" ] || fail "Run this script from a clone of the repository:" \
    "  git clone https://github.com/hounddogai/protomap.git" "  protomap/server/scripts/uninstall.sh"
while [ -L "$script" ]; do
    link="$(readlink "$script")"
    case "$link" in
        /*) script="$link" ;;
        *) script="$(dirname "$script")/${link}" ;;
    esac
done
scripts="$(shorten "$(cd "$(dirname "$script")" && pwd -P)")"
# This user's installations, each in a folder named after its Docker Compose project, with its compose.yaml, its .env,
# and the backups this script makes. No clone holds them, so the scripts of any clone find them.
installations="${HOME}/.protomap/server"

usage() {
    say "Usage: $0 [--name=NAME]" "" \
        "Uninstalls ProtoMap Server and deletes its data, after offering to back it up." "" \
        "  --name=NAME  The installation to uninstall, by its Docker Compose project name. Needed only when" \
        "               ~/.protomap/server holds several"
}

# Leaves in installation the folder of the installation named $1, or else of this user's only one, or nothing when
# there is none. Stops when several are installed and none is named. Keep it in step with upgrade.sh.
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
# even after its tag moves to a newer image. Keep it in step with upgrade.sh.
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
        fail "Cannot list the containers of ProtoMap Server." \
            "Fix the error above, then run ${scripts}/uninstall.sh${name_option} again."
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
                    "Run ${scripts}/uninstall.sh${name_option} again, and answer y if that installation was moved."
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

title "Uninstalling ProtoMap Server..."
command -v docker > /dev/null 2>&1 ||
    fail "Docker is required but was not found." "Install Docker first: https://docs.docker.com/get-docker/"
docker compose version > /dev/null 2>&1 ||
    fail "Docker Compose v2 is required but was not found." "Update Docker, or install Docker Compose."
find_installation "$name"
if [ -z "$installation" ]; then
    missing="No ProtoMap Server installation found in $(shorten "$installations")."
    [ -z "$name" ] || missing="No ProtoMap Server installation named \"${name}\" found in $(shorten "$installations")."
    others="$(other_installations)" || others=""
    [ -z "$others" ] || fail "$missing" "Docker has ProtoMap Server containers that were installed elsewhere:" \
        "$others" "To uninstall one, run this script as the user who installed it."
    say "" "$missing" "Nothing to uninstall."
    exit 0
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
files="${shown}/.env"
login=""
if [ -e "$cli_login" ] && grep -Fq "\"url\":\"${url}\"" "$cli_login"; then
    login=1
    files="${shown}/.env and CLI login"
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
    backed_up="${shown}/.env, CLI login, and database"
elif [ -n "$has_database" ]; then
    backed_up="${shown}/.env and database"
fi
say "" "Uninstalling will:" "  - Stop and remove containers."
[ -z "$bundled" ] || say "  - Delete bundled database: every organization, account, and scan."
say "  - Remove ${files}."
if [ -n "$is_login_restored" ]; then
    say "  - Log the ProtoMap CLI back in to ${previous_url:-the server it was logged in to before}."
fi
say "  - Keep the ProtoMap CLI and the Docker images."
[ -n "$bundled" ] ||
    say "" "The external PostgreSQL database keeps its data." "To install again, use a new or empty database."
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
            "Start ProtoMap Server with: docker compose --file ${shown}/compose.yaml up --detach --wait" \
            "Then run ${scripts}/uninstall.sh${name_option} again." \
            "To uninstall without a backup instead, run it again and answer n to the backup question."
    fi
    backups+=("  ${shown}/${dump}")
fi
removing="Removing containers"
[ -z "$bundled" ] || removing="Removing containers and data"
step "$removing" docker compose down --volumes --remove-orphans ||
    fail "Cannot remove containers." "Fix the error above, then run ${scripts}/uninstall.sh${name_option} again."
if [ -n "$back_up" ]; then
    mv .env ".env.backup.${stamp}"
    backups+=("  ${shown}/.env.backup.${stamp}")
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
# The installation's copy of the clone's definition of the services goes too, and its folder when no backup is in it.
rm -f compose.yaml
cd "$HOME"
rmdir "$installation" "$installations" 2> /dev/null || true
if [ -n "$is_login_restored" ]; then
    mv "$previous_login" "$restored_login"
    say "Logged the ProtoMap CLI back in to ${previous_url:-the server it was logged in to before}."
elif [ -n "$previous_login" ]; then
    say "The ProtoMap CLI is now logged in to another server. Its earlier login was not restored." \
        "It is saved in:" "  $(shorten "$previous_login")"
fi

say "" "ProtoMap Server is uninstalled." "To reinstall, run ${scripts}/install.sh${name_option}."
