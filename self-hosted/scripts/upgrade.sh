#!/usr/bin/env bash
#
# Interactive upgrade for ProtoMap self-hosted: keeps the configuration and data, migrates the database to the release
# PROTOMAP_VERSION names, the latest by default, and upgrades the ProtoMap CLI to the same release.

set -euo pipefail

# Run from the folder with compose.yaml and .env, the parent of this script's folder.
cd "$(dirname "$0")/.."

color_heading=""
color_error=""
color_prompt=""
color_reset=""
if { [ -t 1 ] || [ -t 2 ]; } && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    color_heading=$'\033[1;36m'
    color_error=$'\033[0;31m'
    color_prompt=$'\033[1;35m'
    color_reset=$'\033[0m'
fi

say() { printf '%s\n' "$*"; }
heading() { printf '\n%s%s%s\n' "$color_heading" "$*" "$color_reset"; }
fail() {
    printf '%sERROR:%s %s\n' "$color_error" "$color_reset" "$*" >&2
    exit 1
}

# Asks the yes or no question $1, with $2, y or n, as the answer for no input, and succeeds for yes.
confirm() {
    say ""
    REPLY=""
    read -r -p "${color_prompt}$1 [y/n, default: $2]:${color_reset} " REPLY || true
    case "${REPLY:-$2}" in
        y | Y | yes | YES) return 0 ;;
        *) return 1 ;;
    esac
}

# Shows the services' states and the server's last log lines, which say why it did not start, such as a database it
# cannot reach.
show_server_log() {
    docker compose ps --all || true
    heading "SERVER LOG"
    docker compose logs --no-log-prefix --tail 15 server || true
}

# Prints the release of ProtoMap that compose.yaml runs, from its image's label. Run after the image is pulled.
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
# PATH, or else installs to ~/.local/bin, and checks that the installed CLI runs. Keep it in step with install.sh.
install_cli() {
    heading "INSTALL THE PROTOMAP CLI"
    local existing directory profile cli cli_version
    existing="$(command -v protomap || true)"
    directory="${existing:+$(dirname "$existing")}"
    directory="${directory:-${HOME}/.local/bin}"
    # The folders the CLI's installer creates are for everyone to read, whatever the caller's umask.
    (
        umask 022
        curl -fsSL https://install.protomap.ai | PROTOMAP_INSTALL_DIR="$directory" sh -s -- "$1" > /dev/null
    ) ||
        fail "Cannot install ProtoMap CLI $1. Install it with: curl -fsSL https://install.protomap.ai | sh -s -- $1"
    cli="${directory}/protomap"
    cli_version="$("$cli" --version)" || fail "The ProtoMap CLI was installed at ${cli} but does not run."
    say "Installed ${cli_version} at ${cli}."
    case ":${PATH}:" in
        *":${directory}:"*) ;;
        *)
            # The profile of the user's shell, as the CLI's installer picks it: zsh and fish do not read ~/.profile,
            # and bash reads ~/.bashrc in Linux terminals and ~/.bash_profile in macOS's.
            case "${SHELL:-}" in
                */zsh) profile=.zshrc ;;
                */bash) if [ "$(uname -s)" = Darwin ]; then profile=.bash_profile; else profile=.bashrc; fi ;;
                */fish) profile="" ;;
                *) profile=.profile ;;
            esac
            if [ -n "$profile" ]; then
                say "${directory} is not on your PATH. Add it to your shell's profile, such as with:"
                say "  echo 'export PATH=\"${directory}:\$PATH\"' >> ~/${profile}"
            else
                say "${directory} is not on your PATH. Add it in fish with:"
                say "  fish_add_path '${directory}'"
            fi
            ;;
    esac
}

heading "CHECK REQUIREMENTS"
say "Checking Docker, Docker Compose, and curl..."
command -v docker > /dev/null 2>&1 ||
    fail "Docker is required but was not found. Install it first: https://docs.docker.com/get-docker/"
docker compose version > /dev/null 2>&1 ||
    fail "Docker Compose v2 is required but was not found. Update Docker or install the Compose plugin."
command -v curl > /dev/null 2>&1 || fail "curl is required to install the ProtoMap CLI."
[ -e .env ] || [ -L .env ] || fail "No installation was found. Run ./scripts/install.sh."

heading "UPGRADE PROTOMAP"
say "Upgrading keeps your configuration and data. ProtoMap is unavailable while the database migrates, so back up"
say "your database first."
# Docker Compose reads PROTOMAP_VERSION from the environment before .env, but the next 'docker compose up' without it
# would run the release .env names again, and migrate the database to it.
pinned="$(sed -n 's/^PROTOMAP_VERSION=//p' .env | tail -n 1 | tr -d "\"'")"
if [ -n "${PROTOMAP_VERSION:-}" ] && [ "$PROTOMAP_VERSION" != "${pinned:-latest}" ]; then
    say ""
    say "PROTOMAP_VERSION=${PROTOMAP_VERSION} is not in .env, so a later 'docker compose up' would run" \
        "${pinned:-the latest release} instead. To keep ${PROTOMAP_VERSION}, cancel, set PROTOMAP_VERSION in .env," \
        "and run ./scripts/upgrade.sh again."
fi
confirm "Upgrade ProtoMap?" y || {
    say "Upgrade cancelled. Nothing was changed."
    exit 0
}

heading "PULL THE RELEASE"
say "Pulling the images..."
docker compose pull --quiet ||
    fail "Cannot pull the images. Fix the reported error and run ./scripts/upgrade.sh again."
from="$(running_release)"
release="$(server_release)"
say "Upgrading from ${from:-a stopped installation} to ProtoMap ${release}."
# An older release may not read what a later one wrote, such as its database schema.
if [ -n "$from" ] && is_older_release "$release" "$from"; then
    fail "ProtoMap ${release} is older than ProtoMap ${from}, which this installation runs, so nothing was changed." \
        "Set PROTOMAP_VERSION in .env to ${from} or a later release. To go back to an earlier release, restore the" \
        "database backup made before upgrading from it, then run 'docker compose down' and ./scripts/upgrade.sh" \
        "again."
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
            "run ${release}, back up what you need, then start over with ./scripts/uninstall.sh and" \
            "./scripts/install.sh, which delete every organization, account, and scan."
    fi
    fail "The database migration failed${from:+, and ProtoMap ${from} is running again}. Fix the reported error and" \
        "run ./scripts/upgrade.sh again."
fi

heading "START PROTOMAP"
say "Starting ProtoMap ${release}..."
server_scale=$((server_scale > 0 ? server_scale : 1))
worker_scale=$((worker_scale > 0 ? worker_scale : 1))
if ! docker compose up --detach --wait --force-recreate --remove-orphans \
    --scale "server=${server_scale}" --scale "worker=${worker_scale}"; then
    show_server_log
    fail "ProtoMap did not start. Fix the error above, and run ./scripts/upgrade.sh again."
fi

install_cli "$release"

heading "UPGRADE COMPLETE"
if [ -n "$from" ] && [ "$from" != "$release" ]; then
    say "ProtoMap ${release} is running, upgraded from ${from}."
else
    say "ProtoMap ${release} is running."
fi
