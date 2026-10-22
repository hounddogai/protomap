#!/usr/bin/env bash
#
# Interactive uninstall for ProtoMap Server: removes the installation and its data, and keeps the CLI.

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

title "Uninstalling ProtoMap Server..."
command -v docker > /dev/null 2>&1 ||
    fail "Docker is required, and it was not found." "Install Docker first: https://docs.docker.com/get-docker/"
docker compose version > /dev/null 2>&1 ||
    fail "Docker Compose v2 is required, and it was not found." "Update Docker, or install Docker Compose."
if ! { [ -e .env ] || [ -L .env ]; }; then
    say "" "No installation found. Nothing to uninstall."
    exit 0
fi

bundled=""
if grep -Eq '^COMPOSE_PROFILES=.*postgres' .env; then
    bundled=1
fi
# The CLI's login goes too when it is for this installation, as a trial's is.
url="http://localhost:$(sed -n 's/^PROTOMAP_PORT=//p' .env | tail -n 1)"
files="${folder}/.env"
login=""
if [ -e "$cli_login" ] && grep -Fq "\"url\":\"${url}\"" "$cli_login"; then
    login=1
    files="${folder}/.env and CLI login"
fi
say "" "Uninstalling will:" "  - Stop and remove containers."
[ -z "$bundled" ] || say "  - Delete bundled database: every organization, account, and scan."
say "  - Remove ${files}." "  - Keep ProtoMap CLI, Docker images, and other files in ${folder}."
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
    read -r -p "${color_prompt}Back up ${files} first? [Y/n]:${color_reset} " || true
    case "${REPLY:-y}" in
        y | Y | yes | YES) back_up=1 && break ;;
        n | N | no | NO) back_up="" && break ;;
        *) say "Enter y or n." ;;
    esac
done

say ""
removing="Removing containers"
[ -z "$bundled" ] || removing="Removing containers and data"
step "$removing" docker compose down --volumes --remove-orphans ||
    fail "Cannot remove containers." "Fix that error, and run ${scripts}/uninstall.sh again."
if [ -n "$back_up" ]; then
    stamp="$(date +%Y%m%d-%H%M%S)"
    mv .env ".env.backup.${stamp}"
    backups=("  ${folder}/.env.backup.${stamp}")
    if [ -n "$login" ]; then
        mv "$cli_login" "${cli_login}.backup.${stamp}"
        backups+=("  $(shorten "${cli_login}.backup.${stamp}")")
    fi
    say "Backed up ${files}:" "${backups[@]}"
else
    rm -f .env
    [ -z "$login" ] || rm -f "$cli_login"
    say "Removed ${files}."
fi

say "" "ProtoMap Server is uninstalled." "To reinstall, run ${scripts}/install.sh."
