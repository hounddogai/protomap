#!/usr/bin/env bash
#
# Interactive uninstall for ProtoMap self-hosted: removes the installation and its data, and keeps the CLI.

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

# The login that install.sh writes for trial installations, as protomap login would.
cli_login="${PROTOMAP_DATA_DIR:-${HOME}/.protomap}/login.json"

say() { printf '%s\n' "$*"; }
heading() { printf '\n%s%s%s\n' "$color_heading" "$*" "$color_reset"; }
fail() {
    printf '%sERROR:%s %s\n' "$color_error" "$color_reset" "$*" >&2
    exit 1
}

heading "CHECK REQUIREMENTS"
say "Checking Docker and Docker Compose..."
command -v docker > /dev/null 2>&1 ||
    fail "Docker is required but was not found. Install it first: https://docs.docker.com/get-docker/"
docker compose version > /dev/null 2>&1 ||
    fail "Docker Compose v2 is required but was not found. Update Docker or install the Compose plugin."
if ! { [ -e .env ] || [ -L .env ]; }; then
    say "No installation was found. Nothing to uninstall."
    exit 0
fi

heading "UNINSTALL PROTOMAP"
say "Uninstalling will:"
say "- Stop and remove the containers"
say "- Delete the bundled PostgreSQL's data: every organization, account, and scan"
say "- Move .env and the CLI's login to backups"
say "- Keep the CLI, the Docker images, and this folder"
if ! grep -Eq '^COMPOSE_PROFILES=.*postgres' .env; then
    say ""
    say "Your own PostgreSQL keeps its data. To install again, use a new or empty database."
fi
say ""
read -r -p "${color_prompt}Uninstall ProtoMap? [y/n, default: n]:${color_reset} " || true
case "${REPLY:-n}" in
    y | Y | yes | YES) ;;
    *)
        say "Uninstall cancelled. Nothing was changed."
        exit 0
        ;;
esac

heading "REMOVE THE INSTALLATION"
say "Stopping the containers and deleting their data..."
docker compose down --volumes --remove-orphans
# Backups of .env, and of the CLI's login when it is for this installation, keep the secrets of the removed
# installation, such as the key its stored API keys are encrypted with.
stamp="$(date +%Y%m%d-%H%M%S)"
url="http://localhost:$(sed -n 's/^PROTOMAP_PORT=//p' .env | tail -n 1)"
if [ -e "$cli_login" ] && grep -Fq "\"url\":\"${url}\"" "$cli_login"; then
    mv "$cli_login" "${cli_login}.backup.${stamp}"
    say "Moved the CLI's login to ${cli_login}.backup.${stamp}."
fi
mv .env ".env.backup.${stamp}"
say "Moved .env to $(pwd)/.env.backup.${stamp}."

heading "UNINSTALL COMPLETE"
say "ProtoMap self-hosted is uninstalled. To install it again, run ./scripts/install.sh."
